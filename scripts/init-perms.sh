#!/usr/bin/env bash
set -euo pipefail

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo-root >/dev/null 2>&1; then
    sudo-root "$@"
  else
    "$@"
  fi
}

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-ubuntu}"

if [[ ! -d /run/sshd ]]; then
  run_root mkdir -p /run/sshd || true
  run_root chmod 0755 /run/sshd || true
fi

if [[ ! -d /tmp/.X11-unix ]]; then
  run_root mkdir -p /tmp/.X11-unix || true
fi
run_root chmod 1777 /tmp/.X11-unix 2>/dev/null || chmod 1777 /tmp/.X11-unix 2>/dev/null || true

if [[ ! -d /home/ubuntu ]]; then
  run_root mkdir -p /home/ubuntu || true
fi
if [[ "$(stat -c '%u' /home/ubuntu 2>/dev/null || echo 0)" != "1000" ]]; then
  run_root chown ubuntu:ubuntu /home/ubuntu || true
fi

PODMAN_DIR="/home/ubuntu/.local/share/containers"
if [[ -d "${PODMAN_DIR}" && "$(stat -c '%u' "${PODMAN_DIR}" 2>/dev/null || echo 0)" != "1000" ]]; then
  run_root chown ubuntu:ubuntu "${PODMAN_DIR}" || true
fi

mkdir -p "${RUNTIME_DIR}" "${RUNTIME_DIR}/pulse" 2>/dev/null \
  || run_root mkdir -p "${RUNTIME_DIR}" "${RUNTIME_DIR}/pulse" || true
if [[ "$(stat -c '%u' "${RUNTIME_DIR}" 2>/dev/null || echo 0)" != "1000" ]]; then
  run_root chown -R ubuntu:ubuntu "${RUNTIME_DIR}" || true
fi
chmod 700 "${RUNTIME_DIR}" 2>/dev/null || run_root chmod 700 "${RUNTIME_DIR}" || true

if [[ -n "${PASSWD:-}" ]]; then
  for _ in $(seq 1 5); do
    if printf 'ubuntu:%s\n' "${PASSWD}" | run_root chpasswd 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
fi
