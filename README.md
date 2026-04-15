# Ansible role: `ovpn-gate`

Deploys a two-node **obfs4 + OpenVPN** link between two gate hosts, using [obfs4proxy-openvpn](https://github.com/HRomie/obfs4proxy-openvpn-linux/), and optionally a **plain TCP OpenVPN server** on each peer for end-user profiles.

**Diagram:** [Architecture (draw.io export)](obfs4ovpn.drawio.png)

---

## What this role installs

| Component | Purpose |
|-----------|---------|
| **obfs4 OpenVPN** | Encrypted tunnel between the two gates (server + client); PKI under `/etc/openvpn/easy-rsa/` on `ovpn_gate[0]`; keys and CA are copied to `ovpn_gate[1]` by the role. |
| **obfs4proxy-openvpn** | Wraps OpenVPN in obfs4; systemd unit `obfs4proxy-openvpn.service`. |
| **External TCP OpenVPN** (optional) | Per-host PKI in `/etc/openvpn/easy-rsa-ext-tcp/`, listener config, `generate_ovpn.sh` for `.ovpn` bundles. |

Packages (Debian/Ubuntu via `apt`): `openvpn`, `easy-rsa`, `obfs4proxy`, `whois`, `fail2ban`.

---

## Requirements

- **Target OS:** Debian/Ubuntu (role uses `apt`).
- **Ansible:** 2.10+ recommended.
- **Facts:** The client OpenVPN template uses `ansible_default_ipv4` for the obfs4 `remote` line. Ensure facts are gathered (Ansible default) or set addresses appropriately.
- **Inventory:** A group **`ovpn_gate`** with **exactly two hosts** in the intended order (see below).

---

## Inventory

Use a single group **`ovpn_gate`**. **Order defines roles** when `ovpn_gate_role_mode` is `auto` (default):

| Position | Role |
|----------|------|
| `ovpn_gate[0]` | OpenVPN **server** for obfs4 (PKI CA lives here). |
| `ovpn_gate[1]` | OpenVPN **client** for obfs4. |

Example:

```ini
[ovpn_gate]
gate_a ansible_host=192.168.1.10 ansible_user=root
gate_b ansible_host=192.168.2.10 ansible_user=deploy
```

Client-side tasks pull certificates and obfs4 material from **`ovpn_gate[0]`** automatically (no extra variable). The obfs4 `remote` line uses **`ovpn_gate[0]`**’s `ansible_default_ipv4.address`.

To override which host runs server vs client OpenVPN tasks, set **`ovpn_gate_role_mode`** to `server` or `client` (see variables below). Delegation for PKI fetch still targets **`ovpn_gate[0]`**; **`auto`** mode is recommended so the obfs4 server (and its CA under `/etc/openvpn/easy-rsa/`) stays on that first host.

---

## Playbook

```yaml
---
- name: obfs4 + OpenVPN gates
  hosts: ovpn_gate
  become: true
  roles:
    - role: ovpn-gate
```

Run from your project root with `-i` pointing at your inventory.

---

## Role variables

All defaults live in [`defaults/main.yaml`](defaults/main.yaml).

### Gate role and inventory

| Variable | Default | Description |
|----------|---------|-------------|
| `ovpn_gate_role_mode` | `auto` | `auto`: server = first host in `ovpn_gate`, client = second. `server` / `client`: force behavior regardless of order. |

### Obfs4 tunnel addressing

| Variable | Default | Description |
|----------|---------|-------------|
| `ovpn_obfs4_pool_network` | `172.27.0.0` | Base network; gateway/client IPs are derived (+1 / +2). |
| `ovpn_obfs4_pool_netmask` | `255.255.255.0` | Tunnel netmask. |
| `ovpn_obfs4_dev` | `tap_obfs4` | OpenVPN device name for the obfs4 link. |
| `ovpn_obfs4_peer_source_ip` | `""` | If empty, set automatically to the **peer** host’s `ansible_host` (first ↔ second in `ovpn_gate`). If set, used as-is for `iptables` INPUT allow in the systemd unit. |

### Routing / NAT (`vpn-obfs-up.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `ovpn_up_enable_client_policy_routing` | `true` | Policy routing on client. |
| `ovpn_up_client_route_table` | `27` | Route table index. |
| `ovpn_up_masquerade_obfs4` | `true` | MASQUERADE for obfs4 interface traffic. |
| `ovpn_up_masquerade_default_route` | `true` | MASQUERADE for default route path. |
| `ovpn_up_masquerade_obfs4_comment` | *(see defaults)* | iptables comment fragments. |
| `ovpn_up_masquerade_obfs4_forward_comment` | *(see defaults)* | iptables FORWARD comment fragment. |
| `ovpn_up_masquerade_default_comment_prefix` | *(see defaults)* | iptables comment prefix. |

### External TCP OpenVPN (per host)

| Variable | Default | Description |
|----------|---------|-------------|
| `ovpn_external_enable` | `true` | Install ext-tcp PKI, server unit, `generate_ovpn.sh`. Set `false` to skip. |
| `ovpn_external_tcp_port` | `1443` | Listening port. |
| `ovpn_external_bind_address` | `0.0.0.0` | Bind address. |
| `ovpn_external_dev` | `tun_ext` | TUN device name. |
| `ovpn_external_server_conf_path` | `/etc/openvpn/server-external-tcp.conf` | Server config path. |
| `ovpn_external_gate_pool_network` | `172.28.0.0` | VPN pool for ext-tcp (independent from obfs4 pool). |
| `ovpn_external_gate_pool_netmask` | `255.255.255.0` | Netmask for ext-tcp pool. |
| `ovpn_external_ext_tcp_cn_suffix` | `-ext-tcp` | CN suffix for server cert naming. |
| `ovpn_generate_ovpn_default_remote` | `""` | If set, writes `/etc/openvpn/ovpn-external-remote` so `generate_ovpn.sh` can omit remote arguments. |

---

## Facts set by the role

| Fact | Meaning |
|------|---------|
| `ovpn_gate_is_server` | This host runs obfs4 OpenVPN server tasks. |
| `ovpn_gate_is_client` | This host runs obfs4 OpenVPN client tasks. |
| `ovpn_gate_manage_obfs4_service` | Install/enable `obfs4proxy-openvpn` on this host. |
| `ovpn_obfs4_gateway_ip` / `ovpn_obfs4_client_ip` | Tunnel IPs from `ovpn_obfs4_pool_network`. |
| `ovpn_obfs4_peer_source_ip` | Peer IP for firewall rules (auto or overridden). |

---

## Notable paths on the target host

| Path | Role |
|------|------|
| `/etc/openvpn/easy-rsa/` | Obfs4 OpenVPN PKI (on server host). |
| `/etc/openvpn/server.conf.obfs4` / `client.conf.obfs4` | OpenVPN configs for obfs4. |
| `/etc/obfs4proxy-openvpn.conf` | obfs4proxy bridge config. |
| `/usr/local/bin/obfs4proxy-openvpn` | Wrapper script (from role `files/`). |
| `/usr/local/bin/vpn-obfs-up.sh` | `up` script for obfs4 interface routing/NAT. |
| `/etc/openvpn/easy-rsa-ext-tcp/` | External TCP VPN PKI (**per host**). |
| `/usr/local/bin/generate_ovpn.sh` | Build `.ovpn` profiles for ext-tcp users (run as root). |

---

## End-user VPN profiles (external TCP)

On each gate, after deploy:

```bash
sudo /usr/local/bin/generate_ovpn.sh CLIENTNAME
```

This uses that host’s ext-tcp PKI only. See script header in [`files/generate_ovpn.sh`](files/generate_ovpn.sh) for password handling, `OVPN_PORT`, and remote detection.

---

## Filter plugin

The role ships [`filter_plugins/ovpn_ip.py`](filter_plugins/ovpn_ip.py) with filter **`ovpn_ipv4_offset`** — used to derive tunnel IPs from `ovpn_obfs4_pool_network`.

---

## Upstream

[obfs4proxy-openvpn-linux](https://github.com/HRomie/obfs4proxy-openvpn-linux/)

The role’s IPv4 filter plugin is MIT-licensed (see `filter_plugins/ovpn_ip.py`).
