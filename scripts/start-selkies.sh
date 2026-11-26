#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DISPLAY:-}" ]]; then
  for _ in $(seq 1 60); do
    for sock in /tmp/.X11-unix/X*; do
      if [[ -S "$sock" ]]; then
        export DISPLAY=":${sock##*X}"
        break 2
      fi
    done
    sleep 0.5
  done
fi

export DISPLAY="${DISPLAY:-:20}"
X_NUM="${DISPLAY#*:}"
for _ in $(seq 1 60); do
  if [[ -S "/tmp/.X11-unix/X${X_NUM}" ]]; then
    break
  fi
  sleep 0.5
done

# 等待 PipeWire-Pulse socket 就緒（最多 5 秒，避免初始音訊重連雜訊）
PULSE_SOCK="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR:-/tmp/runtime-ubuntu}/pulse}/native"
for _ in $(seq 1 10); do
  if [[ -S "${PULSE_SOCK}" ]]; then
    break
  fi
  sleep 0.5
done

# 直接監聽 0.0.0.0:8080，自動讀取 SELKIES_ENABLE_BASIC_AUTH / SELKIES_BASIC_AUTH_* / PASSWD
if [[ -n "${SELKIES_ADDR:-}" ]]; then
  exec env -u LD_PRELOAD /usr/bin/selkies --port="${SELKIES_PORT:-8080}"
else
  exec env -u LD_PRELOAD /usr/bin/selkies --public --port="${SELKIES_PORT:-8080}"
fi
