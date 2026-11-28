#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/ubuntu}"
SSH_DIR="${HOME}/.ssh"
HOST_KEY_DIR="${SSH_DIR}/host_keys"
SSHD_CFG="${SSH_DIR}/sshd_config"
PID_FILE="/tmp/sshd-ubuntu.pid"

for _ in $(seq 1 30); do
  if [[ -d "$HOME" && -w "$HOME" ]]; then
    break
  fi
  sleep 1
done

mkdir -p "$SSH_DIR" "$HOST_KEY_DIR"
chmod 700 "$SSH_DIR" "$HOST_KEY_DIR"

if [[ ! -s "${HOST_KEY_DIR}/ssh_host_ed25519_key" ]]; then
  rm -f "${HOST_KEY_DIR}/ssh_host_ed25519_key" "${HOST_KEY_DIR}/ssh_host_ed25519_key.pub"
  ssh-keygen -q -t ed25519 -N "" -f "${HOST_KEY_DIR}/ssh_host_ed25519_key"
fi
if [[ ! -s "${HOST_KEY_DIR}/ssh_host_rsa_key" ]]; then
  rm -f "${HOST_KEY_DIR}/ssh_host_rsa_key" "${HOST_KEY_DIR}/ssh_host_rsa_key.pub"
  ssh-keygen -q -t rsa -b 4096 -N "" -f "${HOST_KEY_DIR}/ssh_host_rsa_key"
fi
chmod 600 "${HOST_KEY_DIR}"/ssh_host_*_key

touch "${SSH_DIR}/authorized_keys"
chmod 600 "${SSH_DIR}/authorized_keys"

# 支援環境變數或 Secret 檔案預先注入 SSH 公鑰（自動去重，不覆蓋使用者既有金鑰）
EXTRA_KEYS="${SSH_AUTHORIZED_KEYS:-}"
if [[ -z "${EXTRA_KEYS}" && -f /run/secrets/selkies-auth/SSH_AUTHORIZED_KEYS ]]; then
  EXTRA_KEYS="$(cat /run/secrets/selkies-auth/SSH_AUTHORIZED_KEYS)"
fi
if [[ -n "${EXTRA_KEYS}" ]]; then
  while IFS= read -r kline; do
    kline="${kline%$'\r'}"
    [[ -z "${kline}" || "${kline}" == \#* ]] && continue
    if ! grep -qxF "${kline}" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
      printf '%s\n' "${kline}" >> "${SSH_DIR}/authorized_keys"
    fi
  done <<< "${EXTRA_KEYS}"
fi

PASS_AUTH="yes"
if [[ "${SSH_DISABLE_PASSWORD_AUTH:-false}" == "true" ]]; then
  PASS_AUTH="no"
fi

cat <<EOF > "$SSHD_CFG"
Port 2222
ListenAddress 0.0.0.0
PidFile ${PID_FILE}

HostKey ${HOST_KEY_DIR}/ssh_host_ed25519_key
HostKey ${HOST_KEY_DIR}/ssh_host_rsa_key

StrictModes no
PubkeyAuthentication yes
AuthorizedKeysFile ${SSH_DIR}/authorized_keys
PasswordAuthentication ${PASS_AUTH}
KbdInteractiveAuthentication no
UsePAM yes

AllowTcpForwarding yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 30
ClientAliveCountMax 3
Subsystem sftp internal-sftp
EOF

chmod 600 "$SSHD_CFG"
exec /usr/sbin/sshd -D -e -f "$SSHD_CFG"