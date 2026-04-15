#!/usr/bin/env bash
# Build a single-file .ovpn profile for the external TCP OpenVPN server.
# Uses this host's ext-tcp PKI only (/etc/openvpn/easy-rsa-ext-tcp), not obfs4 PKI. Run as root.
#
# Usage:
#   generate_ovpn.sh CLIENTNAME
#
# CLIENTNAME is the VPN username: must be unique (not already present in /etc/openvpn/ext-tcp-users).
# Prompts for password; appends CLIENTNAME:sha256crypt_hash to /etc/openvpn/ext-tcp-users for
# auth-user-pass-verify.sh. Requires mkpasswd (e.g. whois package on Debian/Ubuntu).
#
# Remote: this host's public IPv4 (https://api.ipify.org via curl), else src from "ip -4 route get 1.1.1.1".
# Port: env OVPN_PORT, else first "port" line in /etc/openvpn/server-external-tcp.conf, else 1443.

set -euo pipefail

usage() {
  echo "Usage: $0 CLIENTNAME" >&2
  exit 1
}

# Prints a validated IPv4 address or returns non-zero.
detect_external_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 10 -4 https://api.ipify.org 2>/dev/null | tr -d '\r\n[:space:]')" || true
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')" || true
  fi
  [[ -n "$ip" ]] || return 1
  if [[ ! "$ip" =~ ^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$ ]]; then
    return 1
  fi
  printf '%s\n' "$ip"
}

[[ "${1:-}" ]] || usage
CLIENTNAME="$1"

EXT_TCP_USERS="/etc/openvpn/ext-tcp-users"

if [[ -f "$EXT_TCP_USERS" ]] && awk -F: -v u="$CLIENTNAME" '$1 == u { found = 1 } END { if (found) exit 0; exit 1 }' "$EXT_TCP_USERS"; then
  echo "$0: username '$CLIENTNAME' already exists in $EXT_TCP_USERS" >&2
  exit 1
fi

command -v mkpasswd >/dev/null 2>&1 || {
  echo "$0: mkpasswd not found (install e.g. whois on Debian/Ubuntu)" >&2
  exit 1
}

read -r -s -p "Password for $CLIENTNAME: " pass1
echo >&2
read -r -s -p "Confirm password: " pass2
echo >&2
[[ -n "$pass1" ]] || { echo "$0: password is empty" >&2; exit 1; }
[[ "$pass1" == "$pass2" ]] || { echo "$0: passwords do not match" >&2; exit 1; }

hash="$(printf '%s\n' "$pass1" | mkpasswd -m sha256crypt -s)"
unset pass1 pass2
[[ -n "$hash" ]] || { echo "$0: mkpasswd produced empty hash" >&2; exit 1; }

mkdir -p "$(dirname "$EXT_TCP_USERS")"
tmp="$(mktemp "${EXT_TCP_USERS}.tmp.XXXXXX")"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT
if [[ -f "$EXT_TCP_USERS" ]]; then
  cat "$EXT_TCP_USERS" >"$tmp"
fi
printf '%s:%s\n' "$CLIENTNAME" "$hash" >>"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$EXT_TCP_USERS"
trap - EXIT
chmod 644 "$EXT_TCP_USERS"
chown root:root "$EXT_TCP_USERS"

EASYRSA_DIR="${EASYRSA_DIR:-/etc/openvpn/easy-rsa-ext-tcp}"
PKI="$EASYRSA_DIR/pki"
EXT_CONF="${OVPN_EXT_CONF:-/etc/openvpn/server-external-tcp.conf}"

REMOTE="$(detect_external_ipv4)" || {
  echo "$0: could not determine external IPv4 (curl to api.ipify.org and ip route fallback failed or returned non-IPv4)" >&2
  exit 1
}

PORT="${OVPN_PORT:-}"
if [[ -z "$PORT" && -f "$EXT_CONF" ]]; then
  PORT="$(awk '/^[[:space:]]*port[[:space:]]+/{print $2; exit}' "$EXT_CONF" || true)"
fi
PORT="${PORT:-1443}"

[[ -d "$PKI" ]] || { echo "$0: PKI not found at $PKI" >&2; exit 1; }
[[ -f "$PKI/ca.crt" && -f "$PKI/ta.key" ]] || { echo "$0: missing ca.crt or ta.key under $PKI" >&2; exit 1; }

export EASYRSA_BATCH=1
cd "$EASYRSA_DIR"

if [[ ! -f "$PKI/private/${CLIENTNAME}.key" ]]; then
  ./easyrsa gen-req "$CLIENTNAME" nopass
fi
if [[ ! -f "$PKI/issued/${CLIENTNAME}.crt" ]]; then
  ./easyrsa sign-req client "$CLIENTNAME"
fi

OUT="${CLIENTNAME}.ovpn"
umask 077
{
  cat <<EOF
client
dev tun
proto tcp
remote $REMOTE $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
# Use username $CLIENTNAME and the password you set on the server (auth-user-pass-verify).
auth-user-pass
remote-cert-tls server
# cipher AES-256-CBC
verb 3
<ca>
EOF
  cat "$PKI/ca.crt"
  cat <<'EOF'
</ca>
<cert>
EOF
  # One PEM block (first cert in file)
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$PKI/issued/${CLIENTNAME}.crt"
  cat <<'EOF'
</cert>
<key>
EOF
  cat "$PKI/private/${CLIENTNAME}.key"
  cat <<'EOF'
</key>
key-direction 1
<tls-auth>
EOF
  cat "$PKI/ta.key"
  cat <<'EOF'
</tls-auth>
EOF
} >"$OUT"

chmod 600 "$OUT"
echo "Wrote $(pwd)/$OUT"
