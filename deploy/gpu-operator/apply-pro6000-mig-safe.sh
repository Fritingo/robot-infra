#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# apply-pro6000-mig-safe.sh (v4 Production Zero-Blast-Radius Edition)
#
# 安全套用 RTX PRO 6000 Blackwell +gfx MIG 組態（絕不影響叢集內 H200/H100/A100/B300 與線上用戶）
#
# v4 四重安全防護機制：
#   1. 逐一檢查目標節點的 nvidia.com/gpu.product 標籤，若為 H200/H100/A100/B200/B300/GB200/GB300
#      或非 PRO 6000 節點，立即中斷拒絕操作。
#   2. 預設採「原地非破壞式合併（--in-place）」：直接備份並於現行 ConfigMap 補入 rtx6000-* Profile，
#      100% 保留既有所有訓練卡 Profile，且【完全不修改全域 ClusterPolicy 物件】，避免觸發其他節點
#      nvidia-mig-manager 重載！（若仍需建立獨立 ConfigMap 可加 --separate-cm）。
#   3. 【線上工作負載防斷線保護】：變更目標 PRO 6000 節點的 nvidia.com/mig.config 前，自動檢查該節點
#      是否有正在執行的 robotics / GPU 工作負載；若有線上開發者 Pod 則立即拒絕切卡（除非明確加 --force）。
#   4. 僅對驗證通過的 RTX PRO 6000 節點貼上：
#        - robot-infra/gpu-pool=rtx-pro-6000
#        - gpu.capability/rtx-gfx=true
#        - nvidia.com/mig.config=<PROFILE>
#
# 用法：
#   ./deploy/gpu-operator/apply-pro6000-mig-safe.sh --dry-run <pro6000-node-1> [pro6000-node-2 ...]
#   ./deploy/gpu-operator/apply-pro6000-mig-safe.sh --apply   <pro6000-node-1> [pro6000-node-2 ...]
#   MIG_PROFILE=all-2g.48gb.gfx ./deploy/gpu-operator/apply-pro6000-mig-safe.sh --apply <node>
# ==============================================================================

GPU_OP_NS="${GPU_OP_NS:-gpu-operator}"
BASE_CM="${BASE_CM:-default-mig-parted-config}"
MERGED_CM="${MERGED_CM:-pro6000-merged-mig-parted-config}"
MIG_PROFILE="${MIG_PROFILE:-rtx6000-mixed-1x2g-2x1g-gfx}"
MODE="dry-run"
MERGE_MODE="in-place"
FORCE_RECONFIG="0"
NODES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     MODE="dry-run"; shift ;;
    --apply)       MODE="apply"; shift ;;
    --in-place)    MERGE_MODE="in-place"; shift ;;
    --separate-cm) MERGE_MODE="separate"; shift ;;
    --force)       FORCE_RECONFIG="1"; shift ;;
    -h|--help)     sed -n '4,26p' "$0"; exit 0 ;;
    *)             NODES+=("$1"); shift ;;
  esac
done

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "Usage: $0 [--dry-run|--apply] [--in-place|--separate-cm] [--force] <pro6000-node-name> [...]" >&2
  exit 1
fi

echo "[1/5] 檢查叢集現行 ClusterPolicy (mig.strategy & migManager) 與所有非目標 GPU 節點..."
ACTIVE_STRATEGY="$(kubectl get clusterpolicy -o jsonpath='{.items[0].spec.mig.strategy}' 2>/dev/null || echo 'unknown')"
ACTIVE_CM="$(kubectl get clusterpolicy -o jsonpath='{.items[0].spec.migManager.config.name}' 2>/dev/null || true)"
if [[ -n "$ACTIVE_CM" && -z "${BASE_CM_OVERRIDE:-}" ]]; then
  BASE_CM="$ACTIVE_CM"
fi
TARGET_CM="${BASE_CM}"
if [[ "${MERGE_MODE}" == "separate" ]]; then
  TARGET_CM="${MERGED_CM}"
fi
echo "  -> ClusterPolicy mig.strategy=${ACTIVE_STRATEGY}, active ConfigMap=${BASE_CM}, target ConfigMap=${TARGET_CM} (mode=${MERGE_MODE})"

OTHER_MIG_NODES="$(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.nvidia\.com/gpu\.product}{"|"}{.metadata.labels.nvidia\.com/mig\.config}{"\n"}{end}' 2>/dev/null || true)"
if [[ -n "$OTHER_MIG_NODES" ]]; then
  echo "  -> 叢集所有 GPU 節點快照："
  while IFS='|' read -r n prod cfg; do
    [[ -z "$n" ]] && continue
    echo "     - ${n}: product=${prod:-N/A}, mig.config=${cfg:-none}"
    if [[ "$ACTIVE_STRATEGY" == "single" && -n "$cfg" && "$cfg" != "all-disabled" ]] && echo "$prod" | grep -qiE 'H200|H100|A100|B200|B300|GB200|GB300'; then
      echo "  [WARN] 節點 ${n} (${prod}) 目前在 mig.strategy=single 下啟用 MIG (${cfg})！" >&2
      echo "         切勿將 ClusterPolicy.spec.mig.strategy 改為 mixed，否則會改變該訓練卡節點資源名稱！" >&2
      echo "         PRO 6000 請改用均切 Profile（如 MIG_PROFILE=all-2g.48gb.gfx）並於 Pod 申請 nvidia.com/gpu: 1。" >&2
      if [[ "${MIG_PROFILE}" == *mixed* ]]; then
        echo "[ABORT] 偵測到叢集為 mig.strategy=single 且目標 Profile 為混切 (${MIG_PROFILE})，已自動中止保護訓練卡！" >&2
        exit 1
      fi
    fi
  done <<< "$OTHER_MIG_NODES"
fi

echo "[2/5] 驗證目標節點 GPU 型號（硬性阻擋 H200 / H100 / A100 / B200 / B300 / GB200 / GB300）..."
for node in "${NODES[@]}"; do
  PRODUCT="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || true)"
  if [[ -z "$PRODUCT" ]]; then
    echo "[ABORT] 節點 ${node} 找不到 nvidia.com/gpu.product 標籤，請先確認 GPU Feature Discovery 狀態。" >&2
    exit 1
  fi
  if echo "$PRODUCT" | grep -qiE 'H200|H100|A100|B200|B300|GB200|GB300'; then
    echo "[ABORT] 偵測到非目標訓練卡節點 ${node} (${PRODUCT})！拒絕套用任何 MIG 或標籤變更。" >&2
    exit 1
  fi
  if ! echo "$PRODUCT" | grep -qiE 'PRO.*6000|RTX.*6000'; then
    echo "[ABORT] 節點 ${node} 的 GPU 型號為 '${PRODUCT}'，不符合 RTX PRO 6000 檢核條件，已中止。" >&2
    exit 1
  fi
  echo "  [OK] ${node} -> ${PRODUCT} (確認為 RTX PRO 6000)"
done

echo "[3/5] 檢查目標 PRO 6000 節點是否有執行中的線上開發者 Pod（防止切 MIG 造成服務中斷）..."
for node in "${NODES[@]}"; do
  CUR_CFG="$(kubectl get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config}' 2>/dev/null || true)"
  if [[ "${CUR_CFG}" != "${MIG_PROFILE}" ]]; then
    ACTIVE_PODS="$(kubectl get pods -A --field-selector "spec.nodeName=${node},status.phase=Running" \
      -l "app.kubernetes.io/component=selkies" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null || true)"
    if [[ -n "${ACTIVE_PODS// /}" && "${FORCE_RECONFIG}" != "1" ]]; then
      echo "[ABORT] 節點 ${node} 目前有線上執行中的桌面 Pod：[ ${ACTIVE_PODS}]" >&2
      echo "        切換 MIG Profile (${CUR_CFG:-none} -> ${MIG_PROFILE}) 會重置該卡 GPU！" >&2
      echo "        請先以 './deploy/manage-user.sh hibernate <user>' 休眠該節點用戶，或確認維護視窗後加 --force。" >&2
      exit 1
    fi
  fi
  echo "  [OK] ${node} 線上工作負載安全檢查通過（current=${CUR_CFG:-none} -> target=${MIG_PROFILE}）"
done

echo "[4/5] 非破壞式合併既有 ${GPU_OP_NS}/${BASE_CM} 與 PRO 6000 +gfx Profile..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

kubectl -n "${GPU_OP_NS}" get configmap "${BASE_CM}" -o jsonpath='{.data.config\.yaml}' > "${TMP_DIR}/existing.yaml"
if [[ ! -s "${TMP_DIR}/existing.yaml" ]]; then
  echo "[ABORT] 無法讀取 ${GPU_OP_NS}/${BASE_CM}，請確認 BASE_CM 環境變數對應現行 ClusterPolicy。" >&2
  exit 1
fi

cat <<'EOF' > "${TMP_DIR}/pro6000-addon.yaml"
mig-configs:
  all-1g.24gb.gfx:
    - devices: all
      mig-enabled: true
      mig-devices:
        "1g.24gb+gfx": 4
  all-2g.48gb.gfx:
    - devices: all
      mig-enabled: true
      mig-devices:
        "2g.48gb+gfx": 2
  rtx6000-mixed-1x2g-2x1g-gfx:
    - devices: all
      mig-enabled: true
      mig-devices:
        "2g.48gb+gfx": 1
        "1g.24gb+gfx": 2
EOF

if ! command -v yq >/dev/null 2>&1; then
  echo "[ABORT] 需要安裝 mikefarah/yq 執行安全 YAML 合併（不覆蓋任何既有 H200/H100/A100/B300 Profile）。" >&2
  exit 1
fi

yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
  "${TMP_DIR}/existing.yaml" "${TMP_DIR}/pro6000-addon.yaml" > "${TMP_DIR}/merged.yaml"

echo "  -> 合併後保留之 mig-configs 鍵值總數：$(yq '.mig-configs | keys | length' "${TMP_DIR}/merged.yaml")"

if [[ -n "$OTHER_MIG_NODES" ]]; then
  while IFS='|' read -r n prod cfg; do
    [[ -z "$n" || -z "$cfg" ]] && continue
    if ! yq -e ".mig-configs[\"${cfg}\"]" "${TMP_DIR}/merged.yaml" >/dev/null 2>&1; then
      echo "[ABORT] 既有節點 ${n} (${prod}) 使用的 mig.config='${cfg}' 不存在於合併後的 ConfigMap！已中止以避免影響既有訓練卡。" >&2
      exit 1
    fi
  done <<< "$OTHER_MIG_NODES"
  echo "  [OK] 已驗證全叢集既有 GPU 節點的 mig.config 均 100% 保留於合併版 ConfigMap。"
fi

if [[ "${MODE}" == "dry-run" ]]; then
  echo "[5/5] DRY-RUN 完成（未對叢集做任何修改）。若確認無誤請加 --apply 執行："
  echo "  - 將原地備份並更新 ConfigMap: ${GPU_OP_NS}/${TARGET_CM}（保留全部既有 Profile，免改 ClusterPolicy）"
  echo "  - 僅針對節點 [ ${NODES[*]} ] 貼上標籤："
  echo "      robot-infra/gpu-pool=rtx-pro-6000"
  echo "      gpu.capability/rtx-gfx=true"
  echo "      nvidia.com/mig.config=${MIG_PROFILE}"
  exit 0
fi

BACKUP_FILE="/tmp/${BASE_CM}-backup-$(date +%Y%m%d-%H%M%S).yaml"
cp "${TMP_DIR}/existing.yaml" "${BACKUP_FILE}"
echo "[5/5] 已備份原設定至 ${BACKUP_FILE}，正在套用 ConfigMap (${GPU_OP_NS}/${TARGET_CM}) 並標記 PRO 6000 節點..."

kubectl -n "${GPU_OP_NS}" create configmap "${TARGET_CM}" \
  --from-file=config.yaml="${TMP_DIR}/merged.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

for node in "${NODES[@]}"; do
  kubectl label node "$node" \
    robot-infra/gpu-pool=rtx-pro-6000 \
    gpu.capability/rtx-gfx=true \
    nvidia.com/mig.config="${MIG_PROFILE}" \
    --overwrite
done

if [[ "${MERGE_MODE}" == "separate" ]]; then
  echo "提示：你選用了 --separate-cm，請手動確認 ClusterPolicy.spec.migManager.config.name 是否指向 ${TARGET_CM}。"
else
  echo "完成！已在不變動 ClusterPolicy 的前提下原地更新 ${GPU_OP_NS}/${TARGET_CM}，其他 H200/H100/A100/B300 節點 100% 零重載。"
fi
