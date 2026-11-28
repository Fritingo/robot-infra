#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# manage-user.sh — Robot-Infra v4 生產環境使用者生命週期與上線前檢核工具
#
# 核心設計目標：
#   - 絕對避免批次重啟全體線上用戶：所有部署／升級／休眠皆以「單一使用者」為最小隔離單位。
#   - 強制攔截預設測試密碼（ChangeMe / TestPassword），自動產生 24 字元高強度隨機密碼。
#   - 支援閒置休眠（hibernate -> replicas=0）立即釋放 PRO 6000 +gfx MIG 切片並 100% 保留個人 PVC。
#   - 內建 preflight 唯讀檢查，一次核對上生產前必確認的 6 大叢集環境項目。
#
# 用法：
#   ./deploy/manage-user.sh preflight
#   ./deploy/manage-user.sh create <user> --udp-port <50003> --domain <13> [--base-domain selkies.local] [--mig 1g|2g] [--image-tag v4]
#   ./deploy/manage-user.sh apply  <user> [--dry-run] [--allow-demo-password]
#   ./deploy/manage-user.sh hibernate <user>
#   ./deploy/manage-user.sh wake      <user>
#   ./deploy/manage-user.sh status
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
USERS_DIR="${REPO_ROOT}/k8s/users"
NAMESPACE="${NAMESPACE:-robotics}"

usage() {
  sed -n '4,18p' "$0"
}

gen_password() {
  python3 -c 'import secrets, string; alphabet = string.ascii_letters + string.digits + "!@#%^&*-_=+"; print("".join(secrets.choice(alphabet) for _ in range(24)))'
}

cmd_preflight() {
  echo "=============================================================================="
  echo " Robot-Infra v4 — 生產環境上線前 6 大必確認項目（純唯讀檢查，零叢集修改）"
  echo "=============================================================================="

  echo -e "\n[1/6] GPU Operator 現況（mig.strategy / PRO 6000 Taints / Driver 版本）："
  kubectl get clusterpolicy -o custom-columns='NAME:.metadata.name,MIG_STRATEGY:.spec.mig.strategy,MIG_CM:.spec.migManager.config.name' 2>/dev/null || echo "  (無法讀取 ClusterPolicy)"
  kubectl get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NODE:.metadata.name,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,MIG_CFG:.metadata.labels.nvidia\.com/mig\.config,DRIVER:.metadata.labels.nvidia\.com/cuda\.driver\.major,TAINTS:.spec.taints[*].key' 2>/dev/null || true

  echo -e "\n[2/6] StorageClass 種類（確認具硬體 Quota 之區塊型 RWO 與選配唯讀 ROX）："
  kubectl get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode,ALLOW_EXPANSION:.allowVolumeExpansion' 2>/dev/null || true

  echo -e "\n[3/6] 共用 Ingress-NGINX 規範與 TLS Secret 現況："
  kubectl get ingressclass 2>/dev/null || true
  kubectl -n "${NAMESPACE}" get secret selkies-wildcard-tls 2>/dev/null || echo "  (提示：${NAMESPACE}/selkies-wildcard-tls 尚未建立)"

  echo -e "\n[4/6] 叢集資安門檻（PRO 6000 OS 核心 / Namespace PSA 標籤 / Gatekeeper CRD）："
  kubectl get ns "${NAMESPACE}" --show-labels 2>/dev/null || echo "  (提示：Namespace ${NAMESPACE} 尚未建立)"
  kubectl get nodes -l nvidia.com/gpu.present=true -o custom-columns='NODE:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion' 2>/dev/null || true
  kubectl get crd constrainttemplates.templates.gatekeeper.sh clusterpolicies.kyverno.io 2>/dev/null || echo "  (未偵測到 Gatekeeper/Kyverno CRD 或無讀取權限)"

  echo -e "\n[5/6] kube-prometheus-stack 選擇器標籤（serviceMonitorSelector / ruleSelector）："
  kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com 2>/dev/null || echo "  (未偵測到 Prometheus Operator CRD)"
  kubectl get prometheus -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SM_SELECTOR:.spec.serviceMonitorSelector,RULE_SELECTOR:.spec.ruleSelector' 2>/dev/null || true

  echo -e "\n[6/6] RTX PRO 6000 節點實體規格與可分配資源（CPU / Memory / MIG Allocatable）："
  kubectl get nodes -l robot-infra/gpu-pool=rtx-pro-6000 -o custom-columns='NODE:.metadata.name,CPU_ALLOC:.status.allocatable.cpu,MEM_ALLOC:.status.allocatable.memory,MIG_1G:.status.allocatable.nvidia\.com/mig-1g\.24gb\.gfx,MIG_2G:.status.allocatable.nvidia\.com/mig-2g\.48gb\.gfx' 2>/dev/null || true
}

cmd_create() {
  if [[ $# -lt 1 ]]; then
    echo "[ERROR] 請指定使用者名稱，例如：$0 create bob --udp-port 50003 --domain 13" >&2
    exit 1
  fi
  local user="$1"; shift
  if [[ ! "$user" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "[ERROR] 使用者名稱必須為小寫英數（DNS label 相容）：${user}" >&2
    exit 1
  fi

  local udp_port="" domain="" base_domain="selkies.local" mig="1g" img_tag="v4"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --udp-port)    udp_port="$2"; shift 2 ;;
      --domain)      domain="$2"; shift 2 ;;
      --base-domain) base_domain="$2"; shift 2 ;;
      --mig)         mig="$2"; shift 2 ;;
      --image-tag)   img_tag="$2"; shift 2 ;;
      *) echo "[ERROR] 未知參數: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$udp_port" || -z "$domain" ]]; then
    echo "[ERROR] 必須指定唯一的 --udp-port (如 50003) 與 --domain (如 13)" >&2
    exit 1
  fi

  local target_dir="${USERS_DIR}/${user}"
  if [[ -e "$target_dir" ]]; then
    echo "[ERROR] 使用者目錄已存在：${target_dir}" >&2
    exit 1
  fi

  # 檢查既有使用者是否已佔用相同 UDP 埠
  if grep -rn "value: \"${udp_port}\"" "${USERS_DIR}"/*/patch.yaml 2>/dev/null | grep -q .; then
    echo "[ERROR] UDP Mux 埠 ${udp_port} 已被其他使用者佔用，請選擇唯一埠號！" >&2
    exit 1
  fi

  mkdir -p "$target_dir"
  local web_pw linux_pw
  web_pw="$(gen_password)"
  linux_pw="$(gen_password)"

  cat <<EOF > "${target_dir}/auth.env"
# 自動產生之高強度隨機密鑰（切勿提交真實密碼至公開 Git）
WEB_PASSWORD=${web_pw}
LINUX_PASSWORD=${linux_pw}
EOF
  chmod 600 "${target_dir}/auth.env"

  local mig_block=""
  if [[ "$mig" == "2g" ]]; then
    mig_block='          resources:
            requests:
              cpu: "4"
              memory: "16Gi"
              nvidia.com/mig-1g.24gb.gfx: null
              nvidia.com/mig-2g.48gb.gfx: 1
            limits:
              cpu: "12"
              memory: "48Gi"
              nvidia.com/mig-1g.24gb.gfx: null
              nvidia.com/mig-2g.48gb.gfx: 1'
  fi

  cat <<EOF > "${target_dir}/patch.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: selkies
spec:
  template:
    spec:
      containers:
        - name: selkies-desktop
          image: registry.local/robotics/robot-infra:${img_tag}
          env:
            - name: SELKIES_BASIC_AUTH_USER
              value: "${user}"
            - name: SELKIES_WEBRTC_UDP_MUX_PORT
              value: "${udp_port}"
            - name: ROS_DOMAIN_ID
              value: "${domain}"
${mig_block}
EOF

  cat <<EOF > "${target_dir}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${NAMESPACE}
namePrefix: ${user}-

resources:
  - ../../base

components: []
  # - ../../components/seccomp-podman-localhost
  # - ../../components/smarter-device-tun
  # - ../../components/cross-pod-ros
  # - ../../components/monitoring
  # - ../../components/shared-isaac-sim
  # - ../../components/apparmor-unconfined
  # - ../../components/transport-websockets

labels:
  - includeSelectors: true
    pairs:
      app.kubernetes.io/user: ${user}

secretGenerator:
  - name: selkies-auth
    envs:
      - auth.env
    options:
      disableNameSuffixHash: true

patches:
  - path: patch.yaml
  # 注意：若啟用 components/transport-websockets，請一併註解下方 ports/3 UDP patch
  - target:
      kind: Deployment
      name: selkies
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/ports/3/containerPort
        value: ${udp_port}
      - op: replace
        path: /spec/template/spec/containers/0/ports/3/hostPort
        value: ${udp_port}
  - target:
      kind: Ingress
      name: selkies-ingress
    patch: |-
      - op: replace
        path: /spec/tls/0/hosts/0
        value: ${user}.${base_domain}
      - op: replace
        path: /spec/rules/0/host
        value: ${user}.${base_domain}
EOF

  echo "[OK] 已建立使用者設定：${target_dir}"
  echo "  - 網頁與 /zenoh 帳號：${user}"
  echo "  - 隨機強密碼已寫入 ：${target_dir}/auth.env (chmod 600)"
  echo "  - 預演渲染：./deploy/manage-user.sh apply ${user} --dry-run"
  echo "  - 單獨上線：./deploy/manage-user.sh apply ${user}  (零影響其他線上用戶)"
}

cmd_apply() {
  if [[ $# -lt 1 ]]; then
    echo "[ERROR] 請指定單一使用者名稱（生產環境禁止全體無差別重啟）：$0 apply <user>" >&2
    exit 1
  fi
  local user="$1"; shift
  local dry_run="0" allow_demo="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)             dry_run="1"; shift ;;
      --allow-demo-password) allow_demo="1"; shift ;;
      *) echo "[ERROR] 未知參數: $1" >&2; exit 1 ;;
    esac
  done

  local target_dir="${USERS_DIR}/${user}"
  if [[ ! -d "$target_dir" ]]; then
    echo "[ERROR] 找不到使用者目錄：${target_dir}" >&2
    exit 1
  fi

  if [[ "$allow_demo" != "1" ]] && grep -qiE 'ChangeMe|TestPassword|123456|password=' "${target_dir}/auth.env"; then
    echo "[ABORT] 偵測到 ${target_dir}/auth.env 仍含範例弱密碼！" >&2
    echo "        請先修改為高強度隨機密碼後再部署至生產叢集（測試環境若需略過請加 --allow-demo-password）。" >&2
    exit 1
  fi

  if [[ "$dry_run" == "1" ]]; then
    kubectl kustomize "$target_dir"
  else
    echo "[INFO] 正在單獨套用使用者 '${user}'（僅影響 ${user}-* 資源，其他線上開發者 100% 零中斷）..."
    kubectl apply -k "$target_dir"
  fi
}

cmd_hibernate() {
  local user="${1:?請指定要休眠的使用者名稱}"
  echo "[INFO] 正在休眠 '${user}'（縮容至 0 副本：立即釋放 RTX PRO 6000 MIG 切片，100% 保留個人與 Podman PVC）..."
  kubectl -n "${NAMESPACE}" scale "deployment/${user}-selkies" --replicas=0
}

cmd_wake() {
  local user="${1:?請指定要喚醒的使用者名稱}"
  echo "[INFO] 正在喚醒 '${user}'（恢復至 1 副本）..."
  kubectl -n "${NAMESPACE}" scale "deployment/${user}-selkies" --replicas=1
}

cmd_status() {
  echo "=== Deployments (${NAMESPACE}) ==="
  kubectl -n "${NAMESPACE}" get deploy -l app.kubernetes.io/component=selkies -o wide 2>/dev/null || true
  echo -e "\n=== Pods (${NAMESPACE}) ==="
  kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=selkies -o wide 2>/dev/null || true
  echo -e "\n=== PVCs (${NAMESPACE}) ==="
  kubectl -n "${NAMESPACE}" get pvc 2>/dev/null || true
}

SUB="${1:-help}"
shift || true
case "$SUB" in
  preflight) cmd_preflight "$@" ;;
  create)    cmd_create "$@" ;;
  apply)     cmd_apply "$@" ;;
  hibernate) cmd_hibernate "$@" ;;
  wake)      cmd_wake "$@" ;;
  status)    cmd_status "$@" ;;
  -h|--help|help) usage ;;
  *) echo "[ERROR] 未知子指令: ${SUB}" >&2; usage >&2; exit 1 ;;
esac
