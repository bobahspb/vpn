#!/usr/bin/env bash

# copy this script to /usr/local/bin/auth-user-pass-verify.sh with mode 0755
# add these strings to openvpn config:
#  auth-user-pass-verify /usr/local/bin/auth-user-pass-verify.sh via-env
#  script-security 3
#
# input envs:
#  username
#  password
#
# format of password file /etc/openvpn/server-users:
#  username1:hash_of_password1
#  username2:hash_of_password2
#
# ! this script works only with sha256crypt now !
#
# how to get hash of your password:
#  echo "${password}" | mkpasswd -m sha256crypt -s

USERFILE="/etc/openvpn/ext-tcp-users"
METHOD="sha256crypt"

HASH_FILE=$( awk -F: '{if ($1=="'"${username}"'") print $2}' "${USERFILE}" )
if [ -z "${HASH_FILE}" ]
then
  echo "ERROR: no user $username"
  exit 1
fi

SALT=$( echo "${HASH_FILE}" | awk -F\$ '{print $3}' )
HASH_INPUT=$( echo "${password}" | mkpasswd -m "${METHOD}" -s -S "${SALT}" )

if [ "${DEBUG}x" = "yesx" ]
then
  echo "username: $username"
  echo "password: $password"
  echo "salt: ${SALT}"
  echo "hash file: ${HASH_FILE}"
  echo "hash input: ${HASH_INPUT}"
  env
fi

if [ "${HASH_FILE}" = "${HASH_INPUT}" ]
then
  exit 0
fi

echo "ERROR: wrong password"
exit 1

