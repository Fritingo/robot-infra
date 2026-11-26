#!/usr/bin/env bash
set -euo pipefail

mkdir -p /run/sshd /tmp/.X11-unix /tmp/runtime-ubuntu /tmp/runtime-ubuntu/pulse
chmod 0755 /run/sshd
chmod 1777 /tmp/.X11-unix
chown -R ubuntu:ubuntu /tmp/runtime-ubuntu
chmod 700 /tmp/runtime-ubuntu

if [[ -n "${PASSWD:-}" ]]; then
  echo "ubuntu:${PASSWD}" | chpasswd
fi

mkdir -p /home/ubuntu
if [[ "$(stat -c '%u' /home/ubuntu)" != "1000" ]]; then
  chown ubuntu:ubuntu /home/ubuntu || true
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf