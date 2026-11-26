#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# deploy.sh: 單一或批次部署 selkies-user（每人獨立 Helm Release / Ingress / Secret）
#
# 用法：
#   ./deploy/deploy.sh dio                  # 僅部署或更新 dio
#   ./deploy/deploy.sh --all                # 批次同步 deploy/users/*.yaml 全部使用者
#   NAMESPACE=robotics ./deploy/deploy.sh dio --dry-run
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="${NAMESPACE:-robotics}"
CHART_DIR="${ROOT_DIR}/charts/selkies-user"
SHARED_VALUES="${SCRIPT_DIR}/shared-defaults.yaml"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <username|--all> [extra helm flags...]" >&2
  exit 1
fi

TARGET="$1"
shift

deploy_one() {
  local user_file="$1"
  shift
  local user_name
  user_name="$(basename "$user_file" .yaml)"
  echo "==> Deploying selkies-${user_name} into namespace ${NAMESPACE}"
  helm upgrade --install "selkies-${user_name}" "${CHART_DIR}" \
    -n "${NAMESPACE}" --create-namespace \
    -f "${SHARED_VALUES}" \
    -f "${user_file}" \
    "$@"
}

if [[ "$TARGET" == "--all" ]]; then
  for f in "${SCRIPT_DIR}"/users/*.yaml; do
    deploy_one "$f" "$@"
  done
else
  USER_FILE="${SCRIPT_DIR}/users/${TARGET}.yaml"
  if [[ ! -f "$USER_FILE" ]]; then
    echo "[ERROR] 找不到使用者設定檔：${USER_FILE}" >&2
    exit 1
  fi
  deploy_one "$USER_FILE" "$@"
fi
