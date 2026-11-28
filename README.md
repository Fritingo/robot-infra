# Robot-Infra v4 — 純內網多使用者 GPU 機器人開發與模擬平台（生產強化版）

> **Ubuntu 24.04 + Selkies v2.2.1 EGL Desktop + ROS 2 Jazzy + MoveIt 2 + 預設 CycloneDDS（Podman/Docker 直通）+ 跨 Pod `ros-bridge`（Ingress `/zenoh` Basic Auth WSS）+ Rootless Podman + Rootless SSH over Ingress WebSocket + Prometheus & Grafana 全棧監控 + NVIDIA RTX PRO 6000 Blackwell (`+gfx` MIG 專屬隔離・零中斷維運) + Isaac Sim 6.2**

本專案提供一套專為**完全離線純內網（Air-Gapped）**、**單一 Ingress IP 受限環境**與**多型號 GPU 混部叢集（共存 H200 / H100 / A100 / B300，嚴格僅觸及 RTX PRO 6000 且更新絕不中斷既有服務）**設計的生產級 Kubernetes 多使用者機器人開發平台。

> 線上互動式專案架構與全參數說明頁（GitHub Pages）：**https://fritingo.github.io/robot-infra/**
> 離線環境亦可直接以瀏覽器開啟 [project-overview.html](./project-overview.html) 或 [docs/index.html](./docs/index.html)（純單檔 HTML，零外部 CDN 依賴）。

---

## v4 生產環境強化更新重點（對照 v3）

1. **零中斷更新與防止波及既有服務（Zero-Downtime & Blast-Radius Protection）**：
   - **原地增量合併 MIG ConfigMap（免改 `ClusterPolicy`）+ 線上 Pod 防斷線保護**：[deploy/gpu-operator/apply-pro6000-mig-safe.sh](./deploy/gpu-operator/apply-pro6000-mig-safe.sh) 預設直接備份並原地更新既有 ConfigMap，**完全不修改全域 `ClusterPolicy` 物件**，使 H200/H100/A100/B300 上的 `nvidia-mig-manager` **100% 零重載**；且切卡前自動檢查目標 PRO 6000 是否有執行中的使用者 Pod，防止誤切重置線上 GPU。
   - **單人獨立生命週期與映像釘選（[deploy/manage-user.sh](./deploy/manage-user.sh)）**：每位使用者 `patch.yaml` 獨立釘選映像標籤，並由 `manage-user.sh` 執行**單人獨立上線（`apply <user>`）**、**強密碼自動生成與弱密碼攔截**、以及**閒置休眠釋放 MIG 切片（`hibernate` / `wake`，100% 保留個人 PVC）**，杜絕批次 `apply` 造成全員斷線。
   - **共用 Ingress 與 `zenoh-hub` 保護**：Ingress 預設限制 `proxy-body-size: "4g"`（避免無限大上傳拖慢共用 Ingress-NGINX）；`zenoh-hub` 升級為 `RollingUpdate (maxSurge: 1, maxUnavailable: 0)` + Readiness Probe 零中斷切換。
2. **個人 Ingress `/zenoh` Basic Auth 安全鎖與 SSH 金鑰支援**：
   - 內建 [scripts/zenoh-ws-auth-proxy.py](./scripts/zenoh-ws-auth-proxy.py) 守護 `:7448`（`/zenoh`），自動複用個人 `SELKIES_BASIC_AUTH_USER` + `WEB_PASSWORD` 在 WebSocket 握手前強制驗證 Basic Auth（未授權連線直接回 `401`），免額外建立 `htpasswd` Secret；同時支援 `SSH_AUTHORIZED_KEYS` 自動注入與 Secret 檔案掛載。
3. **穩定性、防搶核與日誌防爆強化**：
   - Deployment 探針升級為免認證真實 HTTP 檢查 `/api/health`，補齊 `terminationGracePeriodSeconds: 60`、`preStop` 優雅停機與 `ephemeral-storage` 配額（`2Gi/12Gi`）。
   - 全域預設 `CMAKE_BUILD_PARALLEL_LEVEL=4` 與 `MAKEFLAGS=-j4`（防止 `colcon build` 搶滿整機核心導致同卡桌面掉幀），並為全部 `supervisord` 與 `ros-bridge` 日誌加上 `10MB` 輪替上限；內建 `/usr/local/bin/robot-metrics-exporter` 銜接 **Prometheus + 22 面板離線 Grafana Dashboard**。
4. **新增「推上生產前必確認的 6 大環境檢核清單」**（詳見第 7.5 節，亦可直接執行 `./deploy/manage-user.sh preflight` 一鍵唯讀檢查）。

### 歷代核心架構基石（自 v3 延續）
- **Pod 內預設 CycloneDDS（`rmw_cyclonedds_cpp`）鎖定 `lo`**：與內層 `mig-podman` / Docker 零設定直通，對宿主機與 K8s CNI **0 pps 廣播外洩**。
- **跨 Pod / 跨實體機 `ros-bridge`**：複用單一 Ingress 443（`wss://<user>.selkies.local/zenoh`），使用者完全免查 K8s Service。
- **RTX PRO 6000 三重硬體鎖定**：`nodeSelector` + `nodeAffinity NotIn(A100/H100/H200/B200/B300/GB200/GB300)` + `+gfx` MIG；無純 CPU 節點時基礎元件集中於 PRO 6000 節點並設 `NVIDIA_VISIBLE_DEVICES=void`（佔 **0 GPU**）。

---

## 目錄

1. [快速取得專案包與映像檔（Docker Hub）](#1-快速取得專案包與映像檔docker-hub)
2. [系統架構、傳輸模式與目錄分工](#2-系統架構傳輸模式與目錄分工)
3. [容器啟動參數與環境變數完整字典](#3-容器啟動參數與環境變數完整字典)
4. [內建工具啟動參數與使用方法（`mig-podman` / `launch-isaac-sim` / `supervisord`）](#4-內建工具啟動參數與使用方法mig-podman--launch-isaac-sim--supervisord)
5. [本機 Docker 快速測試](#5-本機-docker-快速測試)
6. [Kubernetes 基礎設施層（Helm `charts/robotics-infra`）可控參數與部署](#6-kubernetes-基礎設施層helm-chartsrobotics-infra可控參數與部署)
7. [Kubernetes 使用者層（純 `kubectl apply -k`）可控參數與新增開發者](#7-kubernetes-使用者層純-kubectl-apply--k可控參數與新增開發者)
8. [（選配）全 Helm 使用者部署（`charts/selkies-user` 與 `deploy/deploy.sh`）](#8-選配全-helm-使用者部署chartsselkies-user-與-deploydeploysh)
9. [NVIDIA GPU Operator `+gfx` MIG 切分參數](#9-nvidia-gpu-operator-gfx-mig-切分參數)
10. [容器內日常開發指南與離線映像檔同步](#10-容器內日常開發指南與離線映像檔同步)
11. [生產安全基線與 Trivy CVE 掃描修補報告](#11-生產安全基線與-trivy-cve-掃描修補報告)
12. [常見問題排解（Troubleshooting）](#12-常見問題排解troubleshooting)

---

## 1. 快速取得專案包與映像檔（Docker Hub）

本專案已於 Docker Hub 同步發布：
- **v4 主執行映像檔（★ 生產環境推薦）**：`docker.io/fritingo/robot-infra:v4`（含 `/zenoh` Basic Auth 防護、內建 `:9108` Prometheus Exporter、平行編譯防搶核、日誌輪替上限、預設 CycloneDDS + `ros-bridge` + CVE 清零）
- **v4 完整專案設定與文件壓縮包**：`docker.io/fritingo/robot-infra:v4-bundle`（基於 `busybox:1.38-musl`，內含 `/opt/bundle/robot-infra-v4-bundle.zip` 與 `SHA256SUMS`；亦完整保留既有 `v3`、`v3-bundle`、`v2` 與 `v2-bundle`）

### 從 Docker Hub 取出專案壓縮包（`v4-bundle`）
```bash
# 使用 Docker（Podman 環境將 docker 換成 podman 即可）
docker pull fritingo/robot-infra:v4-bundle
CID=$(docker create fritingo/robot-infra:v4-bundle)
docker cp "${CID}:/opt/bundle/robot-infra-v4-bundle.zip" ./robot-infra-v4-bundle.zip
docker cp "${CID}:/opt/bundle/SHA256SUMS" ./SHA256SUMS
docker rm -f "$CID" >/dev/null

# 校驗並解壓
sha256sum -c SHA256SUMS
unzip robot-infra-v4-bundle.zip -d robot-infra-v4
cd robot-infra-v4
```

---

## 2. 系統架構、傳輸模式與目錄分工

### 單一 Ingress IP + 零外網 STUN 設計
所有開發者共享同一組 Ingress-NGINX IP（TCP 443），零個人 LoadBalancer IP、零 SSH NodePort：
- **Web 桌面與信令**：`https://<user>.selkies.local/` → Ingress-NGINX → `Service:80` → `Pod:8080`（Selkies v2.2.1，Basic Auth）
- **SSH WebSocket 隧道**：`wss://<user>.selkies.local/ssh` → Ingress-NGINX → `Service:2223` → `Pod:2223`（`websocat`）→ `127.0.0.1:2222`（Rootless `sshd`）
- **跨 Pod / 跨實體機 ROS 2 橋接隧道**：`wss://<user>.selkies.local/zenoh` → Ingress-NGINX → `Service:7448` → `Pod:7448`（`websocat`）→ `127.0.0.1:7447`（`zenoh-bridge-ros2dds v1.10.2`），使用者免查 K8s Service
- **離線 RTC 防漏**：所有模式皆掛載內容為 `{"iceServers": []}` 的 `selkies-airgap-rtc-config` ConfigMap，徹底禁止 Selkies 退回連向 `stun.l.google.com` 或 `stun.cloudflare.com`。

### 三種純內網傳輸模式比較

| 模式 | 媒體通道 | 延遲表現 | 額外 IP 需求 | 適用內網拓撲 |
| --- | --- | --- | --- | --- |
| **`webrtc-udp-mux`（預設推薦）** | 瀏覽器直連 GPU 節點 `status.hostIP:<50001..50050>`（UDP + `ICE-lite`） | **最低（0 中繼跳數）** | **0** | 辦公電腦可直接 UDP 連通 GPU Worker Node |
| **`webrtc-coturn`** | 經由單一內部 Coturn 節點中繼（HMAC 動態憑證） | 低（1 跳內網中繼） | 共用 1 邊界 IP | GPU 節點在隔離私網，僅邊界節點可通辦公網 |
| **`websockets`** | 100% 走單一 Ingress TCP 443（`/api/websockets`） | 中 | **0** | 防火牆全面封鎖 UDP 之嚴格受限網路 |

### 專案目錄分工

```text
robot-infra/
├── Dockerfile                                    # 主映像建置檔（v3：CycloneDDS + ros-bridge + 完整 CVE 修補）
├── .dockerignore                                 # 排除大型壓縮檔與暫存目錄
├── README.md                                     # 本完整操作與參數參考手冊
├── project-overview.html                         # 單檔純 HTML 離線互動專案說明頁
├── docs/
│   ├── index.html                                # GitHub Pages 靜態入口頁（與 project-overview.html 同步）
│   └── .nojekyll                                 # 停用 Jekyll，直接提供純靜態 HTML
├── config/
│   ├── cyclonedds.xml                            # Pod 預設 CycloneDDS（僅綁定 lo，直通 Podman/Docker、零外洩）
│   ├── containers.conf                           # Podman 引擎參數（pasta、cgroups=disabled、keyring=false）
│   ├── storage.conf                              # Podman overlay 與 ignore_chown_errors 設定
│   └── registries.conf                           # 短名稱搜尋與內網私有 Registry 設定範本
├── scripts/
│   ├── init-perms.sh                             # 容器啟動時初始化權限與同步 PASSWD
│   ├── start-selkies.sh                          # 等待 X11/PipeWire-Pulse 後啟動 Selkies v2.2.1
│   ├── start-sshd.sh                             # 持久化 Host Keys 並啟動 Rootless sshd (:2222)
│   ├── mig-podman                                # 自動直通 MIG/WSL2 GPU/Vulkan/X11/CycloneDDS 的 Podman Wrapper
│   ├── ros-bridge                                # 跨 Pod / 跨實體機 CycloneDDS 橋接 CLI（serve / connect / hub）
│   └── launch-isaac-sim                          # 唯讀 PVC 啟動 Isaac Sim 6.2（快取全數導向個人 PVC）
├── supervisor/                                   # supervisord 服務定義（init-perms/selkies/sshd/ssh-ws/zenoh-ws/zenohd）
├── charts/
│   ├── robotics-infra/                           # ★ 基礎設施層 Helm Chart（維運管理一次，含可選 rosZenohHub）
│   │   ├── values.yaml
│   │   ├── files/podman-rootless-seccomp.json    # 封鎖 45 高危 syscall 之客製 Seccomp Profile
│   │   └── templates/
│   ├── selkies-user/                             # （選配）全 Helm 版使用者 Chart
│   └── coturn-infra/                             # （選配）獨立 Coturn Helm Chart
├── k8s/                                          # ★ 使用者層純 kubectl apply -k（免 Helm）
│   ├── base/                                     # 共用基底：pvc / deployment（PRO 6000 三重鎖定）/ service / ingress
│   ├── components/                               # 7 個可插拔 Kustomize 積木
│   │   ├── seccomp-podman-localhost/
│   │   ├── smarter-device-tun/                   # OPA Gatekeeper 無 hostPath 取代 /dev/net/tun
│   │   ├── cross-pod-ros/                        # 注入 Hub 端點供 ros-bridge hub 免查 Service
│   │   ├── monitoring/                           # 啟用 Selkies /api/metrics + :9108 Sidecar（免改映像）
│   │   ├── shared-isaac-sim/
│   │   ├── transport-websockets/
│   │   └── apparmor-unconfined/
│   └── users/                                    # dio/、alice/ 與批次 kustomization.yaml
├── monitoring/                                   # ★ Prometheus + Grafana 監控套件（生產對接 + 本機一鍵測試）
│   ├── docker-compose.yml                        # 無 K8s 測試機專用：一鍵啟動 Selkies + Exporter + Prometheus + Grafana
│   ├── exporter/robot_metrics_exporter.py        # 零依賴 :9108 Sidecar（Basic Auth 橋接、高基數清洗、SHM/Podman/ros-bridge）
│   ├── prometheus/{prometheus.yml,alerts.yml}    # 本機抓取設定與 12 條實戰告警規則
│   └── grafana/                                  # 100% 離線 Datasource 與 22 面板 Robot-Infra v4 Dashboard JSON
├── coturn/                                       # 內網自建 Coturn Dockerfile
└── deploy/
    ├── gpu-operator/
    │   ├── custom-mig-parted-config.yaml         # RTX PRO 6000 Blackwell +gfx MIG 切分
    │   └── apply-pro6000-mig-safe.sh             # 原地非破壞式合併 + 線上 Pod 防切卡腳本
    ├── manage-user.sh                            # ★ v4 生產零中斷 CLI（preflight / create / apply / hibernate / wake）
    ├── shared-defaults.yaml                      # Helm 版共用預設值
    ├── users/{dio,alice}.yaml                    # Helm 版個別使用者覆寫值
    └── deploy.sh                                 # Helm 版單人／批次部署腳本
```

---

## 3. 容器啟動參數與環境變數完整字典

### 3.1 `Dockerfile` 建置參數（`--build-arg`）

| 參數名稱 | 預設值 | 說明 |
| --- | --- | --- |
| `ROS_DISTRO` | `jazzy` | 安裝之 ROS 2 發行版（對應 Ubuntu 24.04） |
| `SELKIES_VERSION` | `2.2.1` | 從官方 GitHub Releases 下載並驗證 SHA256 之 Selkies `.deb` 版本 |
| `WEBSOCAT_VERSION` | `v1.14.1` | Ingress `/ssh` 與 `/zenoh` WebSocket 隧道橋接二進位版本 |
| `ZENOH_BRIDGE_VERSION` | `1.10.2` | 跨 Pod / 跨實體機 CycloneDDS 橋接用 `zenoh-bridge-ros2dds` 版本 |
| `YQ_VERSION` | `v4.54.3` | 升級取代基底舊版之 `/usr/bin/yq` 版本（消除 Go stdlib CVE） |
| `DEBIAN_FRONTEND` | `noninteractive` | 避免 `apt-get` 建置過程跳出互動式提示 |

建置範例：
```bash
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  --build-arg SELKIES_VERSION=2.2.1 \
  --build-arg ZENOH_BRIDGE_VERSION=1.10.2 \
  --build-arg YQ_VERSION=v4.54.3 \
  -t fritingo/robot-infra:v4 --load .
```

### 3.2 Selkies v2.2.1 串流、認證與網路環境變數（`docker run -e` / K8s `env`）

| 環境變數 | 映像檔預設值 | 可選值 / 格式 | 作用與注意事項 |
| --- | --- | --- | --- |
| `SELKIES_PORT` | `8080` | TCP 埠號 | Selkies HTTP/WebSocket 監聽埠 |
| `SELKIES_ADDR` | （未設定） | IP 位址 | 留空時 `start-selkies.sh` 會以 `--public` 監聽 `0.0.0.0`；有設值則綁定指定介面 |
| `SELKIES_MODE` | `webrtc` | `webrtc` \| `websockets` | 預設視訊傳輸模式；本機純 TCP 測試可設 `websockets` |
| `SELKIES_ENABLE_DUAL_MODE` | `true` | `true` \| `false` | 允許使用者在網頁側邊欄自由切換 WebRTC / WebSockets（UDP 被擋時自動保底） |
| `SELKIES_ENABLE_HTTPS` | `false` | `true` \| `false` | K8s 由 Ingress-NGINX 終止 TLS，容器內保持 `false` |
| `SELKIES_ENABLE_BASIC_AUTH` | `true` | `true` \| `false` | 啟用 Selkies 內建 HTTP Basic Auth 登入驗證 |
| `SELKIES_BASIC_AUTH_USER` | `ubuntu`（K8s） | 字串 | 網頁登入帳號（未設定時預設 `ubuntu`） |
| `SELKIES_BASIC_AUTH_PASSWORD` | （無） | 密鑰字串 | 網頁登入密碼（若未設定則退回讀取 `PASSWD`） |
| `PASSWD` | （無） | 密鑰字串 | `init-perms.sh` 啟動時透過 `chpasswd` 同步為 `ubuntu` 的 SSH / `sudo` 密碼 |
| `SELKIES_ENCODER` | `h264enc,h265enc,vp9enc,av1enc,h264enc-striped,jpeg` | 逗號分隔清單 | **第一項為預設編碼器**（`h264enc` 自動優先 NVENC，無 GPU 自動退回 x264）；**切勿只填單一值**，否則網頁 UI 編碼選單會被鎖死 |
| `SELKIES_FRAMERATE` | `60` | 整數（如 `30`, `60`, `120`） | 目標畫面更新率（FPS） |
| `SELKIES_VIDEO_BITRATE` | `12000` | Kbps（如 `8000`, `12000`, `20000`） | 預設視訊位元率（12000 = 12 Mbps） |
| `SELKIES_AUDIO_BITRATE` | （留空） | Kbps | **建議留空**（沿用預設 128000 且不鎖死網頁音訊選單） |
| `SELKIES_ENABLE_RESIZE` | `true` | `true` \| `false` | 允許視窗隨瀏覽器大小動態調整解析度 |
| `SELKIES_WEBRTC_PACER` | `true` | `true` \| `false` | 啟用 WebRTC 封包平滑發送，降低突發掉幀 |
| `SELKIES_WEBRTC_ICE_LITE` | `false`（K8s UDP Mux 設 `true`） | `true` \| `false` | `webrtc-udp-mux` 必設 `true`；走 `coturn` 或本機測試須設 `false` |
| `SELKIES_WEBRTC_UDP_MUX_PORT` | （未設定） | `50001`..`50999` | 啟用單埠 UDP Mux，K8s 需與 `hostPort` 一致且每位使用者全域唯一 |
| `SELKIES_WEBRTC_TCP_MUX_PORT` | （未設定） | TCP 埠號 | 選配 ICE-TCP 被動候選埠 |
| `SELKIES_WEBRTC_PUBLIC_IP` | （未設定） | IPv4（K8s 用 `status.hostIP`） | 宣告給瀏覽器直連的節點對外／內網 IP |
| `SELKIES_RTC_CONFIG_JSON` | （未設定） | 檔案路徑 | 指向 `/etc/selkies/rtc-config.json`（`{"iceServers": []}`），徹底停用外網 STUN |
| `SELKIES_TURN_HOST` / `PORT` / `PROTOCOL` / `TLS` / `SHARED_SECRET` | （未設定） | Coturn 連線參數 | 僅 `webrtc-coturn` 模式使用，搭配內部 `coturn` HMAC 認證 |

### 3.3 系統、GPU、ROS 2 與 Podman 環境變數

| 環境變數 | 預設值 | 說明 |
| --- | --- | --- |
| `TZ` | `Asia/Taipei`（K8s） | 容器系統時區 |
| `DISPLAY` | 自動偵測（通常 `:20`） | `/etc/profile.d/99-robotics-env.sh` 自動掃描 `/tmp/.X11-unix/X*`，讓 SSH 終端機也能直接開啟 RViz2 / Gazebo / Isaac Sim GUI |
| `XDG_RUNTIME_DIR` | `/tmp/runtime-ubuntu` | PipeWire / PulseAudio 與 Wayland/XDG 執行期目錄（由 `init-perms.sh` 確保 UID 1000 權限 `0700`） |
| `NVIDIA_DRIVER_CAPABILITIES` | `all`（K8s） | 注入完整圖形/渲染/編碼/運算驅動能力（`compute,utility,graphics,video,display`） |
| `ROS_DISTRO` | `jazzy` | 預設載入 `/opt/ros/jazzy/setup.bash` |
| `ROS_DOMAIN_ID` | `11`（各使用者獨立） | ROS 2 網域隔離編號（建議每人不重複，如 `dio=11`、`alice=12`） |
| `RMW_IMPLEMENTATION` | `rmw_cyclonedds_cpp` | **v3 預設** ROS 2 中介軟體（內外層 Podman/Docker 直通；需要時仍可手動改 `rmw_zenoh_cpp` 或 `rmw_fastrtps_cpp`） |
| `CYCLONEDDS_URI` | `file:///etc/ros/cyclonedds.xml` | 綁定 `lo`（`127.0.0.1`）Unicast Peer，確保 0 pps DDS multicast 外洩至宿主機或 K8s CNI |
| `ROS_BRIDGE_HUB_ENDPOINT` / `WSS_URL` | （由 `cross-pod-ros` 注入） | 啟用共用 Hub 時自動填入，使用者執行 `ros-bridge hub` 完全免查 K8s Service |
| `ROS_BRIDGE_INSECURE_TLS` | `0`（`cross-pod-ros` 設 `1`） | 設 `1` 允許內網自簽 Wildcard TLS 憑證 |
| `ZENOH_ROUTER_CHECK_ATTEMPTS` | `5` | 選用 `rmw_zenoh_cpp` 時探測本機 `zenohd`（`tcp/127.0.0.1:7447`）的重試次數 |
| `ZENOH_CONFIG_OVERRIDE` | `transport/shared_memory/enabled=true;transport/shared_memory/transport_optimization/pool_size=268435456` | 選用 `rmw_zenoh_cpp` 時啟用 256MB Zenoh Shared Memory 零複製傳輸 |
| `BUILDAH_ISOLATION` | `chroot`（K8s） | 讓非特權 Podman/Buildah `build` 在受限容器內可正常執行 `RUN` 步驟 |

### 3.4 容器內 Podman 設定檔參數（`config/`）

| 檔案路徑 | 核心參數 | 設定原因 |
| --- | --- | --- |
| [config/containers.conf](./config/containers.conf) (`/etc/containers/containers.conf`) | `default_sysctls = []`<br>`cgroups = "disabled"`<br>`keyring = false`<br>`cgroup_manager = "cgroupfs"`<br>`events_logger = "file"`<br>`default_rootless_network_cmd = "pasta"` | 避免 `/proc/sys` 唯讀造成 `ping_group_range` 失敗；關閉內層 keyring 使客製 Seccomp 可持續封鎖 `keyctl`/`add_key`；無 systemd 環境使用 `cgroupfs` 與 `pasta` 網路 |
| [config/storage.conf](./config/storage.conf) (`/etc/containers/storage.conf`) | `driver = "overlay"`<br>`ignore_chown_errors = "true"` | 搭配空白 `/etc/subuid`、`/etc/subgid` 達成 Single-UID Rootless Podman，免呼叫 `newuidmap` |
| [config/registries.conf](./config/registries.conf) (`/etc/containers/registries.conf`) | `unqualified-search-registries = ["docker.io"]`<br>`short-name-mode = "permissive"` | 允許短名稱自動解析（如 `podman pull ros:jazzy-ros-base`）；純內網可將 `registry.local` 置於陣列最前並啟用 `[[registry]]` |

---

## 4. 內建工具啟動參數與使用方法（`mig-podman` / `launch-isaac-sim` / `supervisord`）

### 4.1 `mig-podman`（無特權 MIG GPU 容器包裝器）

- **子指令行為**：
  - `mig-podman run ...` / `mig-podman create ...`：自動注入 `--security-opt label=disable`、`--cgroups=disabled`、`--network=host`（共享當前 Pod 網路，非宿主機）、`--ipc=host`（共享當前 Pod `/dev/shm`）、MIG 字元裝置（`/dev/nvidia*`、`/dev/nvidia-caps/*`、`/dev/dri/*`；本機 WSL2 自動偵測 `/dev/dxg`）、NVIDIA `.so` 與 EGL/Vulkan ICD 唯讀掛載、X11 `DISPLAY`/`XAUTHORITY` 與預設 CycloneDDS（`CYCLONEDDS_URI` 自動唯讀掛載 `/etc/ros/cyclonedds.xml`）及 ROS 2/Zenoh 變數。
  - 若使用者已自行傳入 `--network`、`--ipc` 或 `--cgroups`，腳本會自動尊重使用者設定而不覆蓋。
  - 其他子指令（`pull`、`images`、`ps`、`build`、`rm` 等）：直接透傳給原生 `/usr/bin/podman`。
- **可控環境變數**：

| 環境變數 | 預設值 | 可選值 | 作用 |
| --- | --- | --- | --- |
| `MIG_PODMAN_NO_GPU` | `0` | `0` \| `1` | 設 `1` 關閉 MIG GPU 裝置與 NVIDIA 驅動函式庫直通 |
| `MIG_PODMAN_NO_X11` | `0` | `0` \| `1` | 設 `1` 關閉 X11 Socket 與 `DISPLAY` 掛載（適合純無頭批次訓練） |
| `MIG_PODMAN_ZENOH` | `auto` | `auto` \| `1` \| `0` | `auto`（預設）透傳 `RMW_IMPLEMENTATION` / `ROS_DOMAIN_ID` / `CYCLONEDDS_URI`（並唯讀掛載設定檔）；`1` 強制切換 `rmw_zenoh_cpp`；`0` 關閉 |
| `MIG_PODMAN_DRY_RUN` | `0` | `0` \| `1` | 設 `1` 僅印出最終組裝完成的 `podman` 指令列，不實際執行 |
| `PODMAN_BIN` | `/usr/bin/podman` | 執行檔路徑 | 覆寫底層 `podman` 二進位路徑 |

- **常用指令範例**：
  ```bash
  # 1. 啟動具 MIG GPU + OpenGL/Vulkan + X11 + ROS 2 互通的開發容器
  mig-podman run --rm -it ros:jazzy-ros-base nvidia-smi

  # 2. 無頭純運算（關閉 X11 掛載）並覆寫網路為 pasta 隔離網路
  MIG_PODMAN_NO_X11=1 mig-podman run --rm --network=pasta ubuntu:24.04 uname -a

  # 3. 預覽自動注入的所有參數（除錯用）
  MIG_PODMAN_DRY_RUN=1 mig-podman run --rm ubuntu:24.04 true
  ```

### 4.2 `launch-isaac-sim`（唯讀 PVC 啟動 Isaac Sim 6.2）

- **啟動模式（CLI 位置參數，其餘參數完整透傳給 Kit 或 Python 腳本）**：

| 指令語法 | 模式說明 |
| --- | --- |
| `launch-isaac-sim [kit args...]` | 預設 **GUI 模式**：顯示於 Selkies X11 桌面，自動注入 `--portable-root`、`--/renderer/multiGpu/enabled=false`、`--/renderer/activeGpu=0`、`--/exts/omni.kit.telemetry/enabled=false` |
| `launch-isaac-sim --headless [kit args...]` | **無頭 GPU 渲染模式**：額外附加 `--no-window`，不要求 `DISPLAY` |
| `launch-isaac-sim --python <script.py> [args...]` | **Standalone Python 模式**：呼叫 `${ISAAC_SIM_RO_DIR}/python.sh` 執行自訂模擬腳本 |
| `launch-isaac-sim -h` / `--help` | 顯示內建使用說明 |

- **可控環境變數**：

| 環境變數 | 預設值 | 說明 |
| --- | --- | --- |
| `ISAAC_SIM_RO_DIR` | `/opt/isaac-sim`（次選 `/mnt/shared/isaac-sim-6.2`） | 共用唯讀 Isaac Sim 6.2 本體 PVC 路徑 |
| `ISAAC_ASSETS_RO_DIR` | `/opt/isaac-sim-assets`（次選 `/mnt/shared/isaac-sim-assets`） | 共用唯讀離線資產目錄；存在時自動注入 `ISAACSIM_ASSET_ROOT` 與 `--/persistent/isaac/asset_root/default` |
| `ISAAC_USER_ROOT` | `${HOME}/.isaac-sim-6.2` | 個人可寫 PVC 根目錄，集中存放 Kit portable root、GL/Vulkan/Mesa Shader、CUDA JIT、Warp、Python bytecode 與 XDG 快取 |
| `ISAAC_TMP_DIR` | `/tmp/isaac-sim-ubuntu` | 暫存目錄（置於容器本地 `/tmp` 避免消耗 PVC IOPS） |
| `ISAAC_ENABLE_ROS2_BRIDGE` | `0` | 設 `1` 啟動時自動附加 `--enable isaacsim.ros2.bridge` |
| `ISAAC_SKIP_PREFLIGHT` | `0` | 設 `1` 跳過啟動前的 `nvidia-smi`、`vulkaninfo`（檢查 NVIDIA `+gfx`）與 `DISPLAY` 檢核 |
| `ISAAC_DRY_RUN` | `0` | 設 `1` 印出完整環境變數與啟動命令列而不實際啟動 |
| `CUDA_CACHE_MAXSIZE` | `4294967296` (4 GiB) | CUDA JIT / PTX 磁碟快取上限 |
| `OMNI_KIT_ACCEPT_EULA` / `ACCEPT_EULA` / `PRIVACY_CONSENT` | `YES` / `Y` / `Y` | 自動同意 EULA 與隱私條款（無人值守容器必備） |

- **常用指令範例**：
  ```bash
  # 預覽啟動環境與參數（免掛載實際跑一次確認）
  ISAAC_SKIP_PREFLIGHT=1 ISAAC_DRY_RUN=1 launch-isaac-sim --headless

  # 啟動完整 GUI 並自動啟用 ROS 2 Bridge
  ISAAC_ENABLE_ROS2_BRIDGE=1 launch-isaac-sim

  # 執行 Standalone Python 模擬腳本
  launch-isaac-sim --python ~/ws/scripts/pick_place.py --num_envs 64
  ```

### 4.3 `ros-bridge`（免查 K8s Service・跨 Pod / 跨實體機 CycloneDDS 橋接工具）

預設各 Pod 內使用 CycloneDDS 僅於 `lo`（`127.0.0.1`）運作，外層容器與內層 `mig-podman` / Docker 直接互通且不跨 Pod 外洩；需要跨 Pod（即使不同 `ROS_DOMAIN_ID`）或跨實體機器人互通時，直接透過單一 Ingress `wss://<user>.selkies.local/zenoh` 或共用 Hub：

| 指令語法 | 作用與場景 |
| --- | --- |
| `ros-bridge serve [--allow REGEX] [--namespace NS] [--domain ID]` | 在本機 `127.0.0.1:7447` 啟動 `zenoh-bridge-ros2dds` Router，自動透過 `zenoh-ws` (`:7448`) 與個人 Ingress `wss://<user>.selkies.local/zenoh` 對外開放橋接 |
| `ros-bridge connect <wss://peer.selkies.local/zenoh \| tcp/ip:port> [--allow REGEX] [-n NS] [-u user:pass] [-k]` | 將本 Pod（含內層 `mig-podman`）的 CycloneDDS 橋接至另一位使用者的 Pod 或外部機器人（`-k` 允許內網自簽 Wildcard TLS） |
| `ros-bridge hub [--allow REGEX] [-n NS] [-u user:pass] [-k]` | 自動讀取 `k8s/components/cross-pod-ros` 注入的 `ROS_BRIDGE_HUB_ENDPOINT` / `ROS_BRIDGE_HUB_WSS_URL` 加入共用星狀 Hub，**使用者完全免查 K8s Service** |
| `ros-bridge status` / `logs` / `stop` | 檢視狀態、日誌或停止橋接行程 |

```bash
# 範例 1：Peer-to-Peer 跨 Pod（alice 的 DOMAIN 12 與 dio 的 DOMAIN 11 透過 Ingress 443 互通）
# 在 alice Pod 內：
ros-bridge serve --allow "/chatter|/shared/.*"
# 在 dio Pod（或外部筆電／實體機器人）內：
ros-bridge connect wss://alice.selkies.local/zenoh -k

# 範例 2：多人星狀共用 Hub（需 Helm 開啟 rosZenohHub.enabled=true 並套用 components/cross-pod-ros）
ros-bridge hub

# 提示：在 Single-UID Rootless Podman 內若需臨時 apt-get 安裝套件，請加 -o APT::Sandbox::User=root
```

### 4.4 `supervisord` 容器內背景服務清單與控制

容器 ENTRYPOINT 為 `/usr/bin/supervisord`（以 `USER ubuntu` 身分啟動），管理以下常駐／初始化服務：

| 服務名稱 | 優先序 | 監聽埠 / 動作 | 日誌位置 | 說明 |
| --- | ---: | --- | --- | --- |
| `init-perms` | `1` | oneshot（`autorestart=false`） | `/tmp/init-perms.log` | 修正 `/run/sshd`、`/tmp/.X11-unix`、`/home/ubuntu`、`runtime-ubuntu` 權限與同步 `PASSWD` |
| `entrypoint` / `dbus` / `kasmvnc` / `pipewire*` | 基底預設 | X11 `:20`、PipeWire-Pulse | `/tmp/*.log` | 桌面顯示、EGL/DRI3 與音訊管線（皆強制 `user=ubuntu`） |
| `selkies` | `40` | TCP `:8080`（+ UDP Mux） | `stdout` / `stderr` | Selkies v2.2.1 串流伺服器（`docker logs` / `kubectl logs` 可直接查看） |
| `sshd` | `50` | TCP `:2222` | `/tmp/sshd.log` | Rootless OpenSSH（Host Keys 持久化於 `~/.ssh/host_keys`） |
| `ssh-ws` | `55` | TCP `:2223` → `127.0.0.1:2222` | `/tmp/ssh-ws.log` | `websocat --binary --exit-on-eof` 供 Ingress `/ssh` 轉發 |
| `zenoh-ws` | `56` | TCP `:7448` → `127.0.0.1:7447` | `/tmp/zenoh-ws.log` | `websocat --binary --exit-on-eof` 供 Ingress `/zenoh` 轉發給 `ros-bridge serve` |
| `zenohd` | `60` | 預設 `STOPPED`（`autostart=false`） | `/tmp/zenohd.log` | 選用舊版 `rmw_zenoh_cpp` 時才需手動 `supervisorctl start zenohd` |

容器內檢視或單獨重啟服務：
```bash
supervisorctl status
supervisorctl restart selkies
supervisorctl tail -f sshd stderr
```

---

## 5. 本機 Docker 快速測試

### Linux / macOS（Bash）
```bash
docker rm -f test-selkies-v4 2>/dev/null || true
docker run -d --name test-selkies-v4 \
  --gpus all --shm-size=4g \
  --cap-drop=ALL \
  --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN \
  --cap-add=FOWNER --cap-add=DAC_OVERRIDE --cap-add=AUDIT_WRITE \
  --security-opt seccomp="$(pwd)/charts/robotics-infra/files/podman-rootless-seccomp.json" \
  --device /dev/net/tun:/dev/net/tun \
  -v selkies-podman-storage:/home/ubuntu/.local/share/containers \
  -p 8080:8080 -p 2222:2222 -p 2223:2223 -p 7448:7448 \
  -e TZ=Asia/Taipei \
  -e PASSWD="TestPassword123!" \
  -e SELKIES_ENABLE_BASIC_AUTH="true" \
  -e SELKIES_BASIC_AUTH_USER="dio" \
  -e SELKIES_BASIC_AUTH_PASSWORD="TestPassword123!" \
  -e SELKIES_MODE="websockets" \
  -e ROS_DOMAIN_ID="11" \
  fritingo/robot-infra:v4
```

### Windows（PowerShell）
```powershell
docker rm -f test-selkies-v4 2>$null
$seccomp = (Resolve-Path "charts\robotics-infra\files\podman-rootless-seccomp.json").Path
docker run -d --name test-selkies-v4 `
  --gpus all --shm-size=4g `
  --cap-drop=ALL `
  --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN `
  --cap-add=FOWNER --cap-add=DAC_OVERRIDE --cap-add=AUDIT_WRITE `
  --security-opt "seccomp=$seccomp" `
  --device /dev/net/tun:/dev/net/tun `
  -v selkies-podman-storage:/home/ubuntu/.local/share/containers `
  -p 8080:8080 -p 2222:2222 -p 2223:2223 -p 7448:7448 `
  -e TZ=Asia/Taipei `
  -e PASSWD="TestPassword123!" `
  -e SELKIES_ENABLE_BASIC_AUTH="true" `
  -e SELKIES_BASIC_AUTH_USER="dio" `
  -e SELKIES_BASIC_AUTH_PASSWORD="TestPassword123!" `
  -e SELKIES_MODE="websockets" `
  -e ROS_DOMAIN_ID="11" `
  fritingo/robot-infra:v4
```

啟動約 15 秒後驗證：
- **瀏覽器桌面**：`http://localhost:8080`（帳號 `dio` / 密碼 `TestPassword123!`）
- **本機 SSH**：`ssh -p 2222 ubuntu@localhost`
- **WebSocket SSH**：`ssh -o ProxyCommand="websocat --binary ws://localhost:2223" ubuntu@localhost`
- **跨容器 ROS 2 橋接（v4 預設啟用 Basic Auth 保護）**：容器內執行 `ros-bridge serve --allow "/chatter"`，另一台主機執行 `ros-bridge connect ws://localhost:7448 -u dio:TestPassword123!`

---

## 6. Kubernetes 基礎設施層（Helm `charts/robotics-infra`）可控參數與部署

維運團隊只需以 Helm 部署並維護一次 `charts/robotics-infra`，所有開發者 Pod 自動共用其產出的 ConfigMap、NetworkPolicy 與 LimitRange。

### 6.1 `charts/robotics-infra/values.yaml` 完整可控參數

| 參數路徑 | 預設值 | 說明 |
| --- | --- | --- |
| `airGapRtcConfig.enabled` | `true` | 建立空 `iceServers: []` 的共用 RTC ConfigMap（純內網必開） |
| `airGapRtcConfig.name` | `"selkies-airgap-rtc-config"` | ConfigMap 名稱（須與 `k8s/base/deployment.yaml` 掛載名一致） |
| `networkPolicy.enabled` | `true` | 啟用生產租戶隔離 NetworkPolicy（需 Calico / Cilium 等支援 NetworkPolicy 之 CNI） |
| `networkPolicy.ingressNamespaceSelector` | `kubernetes.io/metadata.name: ingress-nginx` | 放行 Ingress-NGINX 存取容器 TCP `8080`、`2223`（`/ssh`）與 `7448`（`/zenoh`） |
| `networkPolicy.allowEgressToIngress` | `true` | 放行使用者 Pod Egress 連至 Ingress Controller Pod（解決 Calico/Cilium DNAT 後阻斷 `ros-bridge connect wss://...` 之盲區） |
| `networkPolicy.allowMonitoringScrape` / `monitoringMetricsPort` | `true` / `9108` | 放行生產既有 `monitoring` Namespace 的 Prometheus 抓取內部 Sidecar `:9108/metrics`（絕不經 Ingress 外露） |
| `monitoring.exporterConfigMap.enabled` | `true` | 建立共用 `selkies-metrics-exporter` ConfigMap 供 `k8s/components/monitoring` 與 `zenoh-hub` 掛載（免重建映像） |
| `monitoring.serviceMonitor.enabled` / `prometheusRule.enabled` / `grafanaDashboard.enabled` | `false` | 生產叢集已有 `kube-prometheus-stack` 時全設 `true`，自動建立 `ServiceMonitor`、12 條 `PrometheusRule` 告警與 `grafana_dashboard: "1"` 離線儀表板 ConfigMap |
| `networkPolicy.allowWebrtcUdpMux` | `true` | 是否放行辦公網段直連 WebRTC UDP Mux 埠段 |
| `networkPolicy.webrtcUdpPortStart` / `End` | `50000` / `51000` | 放行的 UDP 埠段範圍 |
| `networkPolicy.clientCidrs` | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | 允許直連 WebRTC UDP Mux 的內網辦公 CIDR 清單 |
| `networkPolicy.podCidr` | `"10.244.0.0/16"` | 叢集 Pod CIDR（用於 Egress `except`，阻斷跨使用者 Pod 橫向互連） |
| `networkPolicy.allowedEgressCidrs` | 內網 RFC1918 網段 | 允許容器主動連線的內網服務（私有 Harbor、Git、PyPI 鏡像等） |
| `networkPolicy.blockedEgressCidrs` | `["169.254.169.254/32"]` | 永遠封鎖雲端／本機 Metadata IP |
| `rosZenohHub.enabled` | `false` | 啟用叢集共用跨 Pod 星狀 Zenoh Hub（搭配 `k8s/components/cross-pod-ros` 供 `ros-bridge hub` 免查 Service） |
| `rosZenohHub.placement` | `"pro6000"` | 無純 CPU 節點時集中排程於 PRO 6000 節點（`NVIDIA_VISIBLE_DEVICES=void`，佔 **0 GPU**）；日後有 CPU 節點可切換 `"cpu-only"` |
| `rosZenohHub.ingress.enabled` / `authSecretName` | `false` / `""` | 選配對外 `wss://ros-hub.selkies.local/zenoh`；開啟時強烈建議設定 `authSecretName`（Basic Auth）或 `whitelistSourceRange` |
| `limitRange.enabled` | `true` | 啟用 Namespace 單容器資源防呆上下限 |
| `limitRange.maxCpu` / `maxMemory` | `"32"` / `"128Gi"` | 單容器允許申請的最大 CPU / 記憶體 |
| `limitRange.defaultRequestCpu` / `Memory` | `"2"` / `"8Gi"` | 未指定 requests 時的預設值 |
| `limitRange.defaultLimitCpu` / `Memory` | `"8"` / `"32Gi"` | 未指定 limits 時的預設值 |
| `coturn.enabled` | `false` | 是否啟用叢集共用內部 Coturn（隔離私網無法用 UDP Mux 時改 `true`） |
| `coturn.placement` | `"pro6000"` | 集中於 PRO 6000 節點（佔 0 GPU）或切換 `"edge"`（獨立邊界節點） |
| `coturn.image.repository` / `tag` | `registry.local/robotics/coturn` / `4.6.2-alpine-patched` | 內網私有 Coturn 映像檔（可用 `coturn/Dockerfile` 自建） |
| `coturn.nodeSelector` | `kubernetes.io/hostname: "edge-node-01"` | 固定將 Coturn 排程至具備內網對外 IP 的邊界節點 |
| `coturn.externalIp` | `"192.168.10.50"` | 邊界節點 IP（宣告為 TURN 中繼位址） |
| `coturn.realm` | `"selkies.local"` | TURN Realm 名稱 |
| `coturn.listeningPort` | `3478` | TURN 監聽埠 |
| `coturn.minPort` / `maxPort` | `50000` / `51000` | TURN 媒體中繼 UDP 埠段 |
| `coturn.podCidr` | `"10.244.0.0-10.244.255.255"` | 僅允許中繼至叢集內部 Pod 網段，防止被當成開放跳板 |
| `coturn.noTcpRelay` | `false` | 是否停用 TCP Relay |
| `coturn.existingSecretName` / `sharedSecret` | `""` / 範例字串 | 生產建議預建 Secret 並填 `existingSecretName`，勿提交明碼 |

### 6.2 部署指令
```bash
# 1. 建立 Namespace 與共用 Wildcard TLS Secret
kubectl create namespace robotics
kubectl -n robotics create secret tls selkies-wildcard-tls \
  --cert=wildcard.selkies.local.crt --key=wildcard.selkies.local.key

# 2. 分發客製 Seccomp Profile 至每台 GPU Worker Node
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
sudo cp charts/robotics-infra/files/podman-rootless-seccomp.json \
  /var/lib/kubelet/seccomp/profiles/podman-rootless.json

# 3. 以 Helm 部署基礎設施層
helm upgrade --install robotics-infra ./charts/robotics-infra \
  -n robotics --create-namespace

# 4. 檢查資源
kubectl -n robotics get configmap,networkpolicy,limitrange
```

> **若叢集 OPA Gatekeeper 禁止 `robotics` Namespace 使用 `hostPath` 掛載 `/dev/net/tun`**：請在 OPA 豁免的 `kube-system` 部署 `smarter-device-manager`（`devicematch: ^net/tun$`），並將 `k8s/base/deployment.yaml` 中的 `hostPath: /dev/net/tun` 移除，改於 `resources.requests/limits` 申請 `smarter-devices/net_tun: 1`。

---

## 7. Kubernetes 使用者層（純 `kubectl apply -k`）可控參數與新增開發者

日常新增、調整或刪除開發者完全不需 Helm，直接以 `kubectl apply -k` 操作 `k8s/users/`。

### 7.1 `k8s/base/` 預設基線參數
- **Deployment (`k8s/base/deployment.yaml`)**：`strategy.type: Recreate`（避免 RWO PVC / MIG / UDP hostPort 衝突）、`image: registry.local/robotics/robot-infra:v4`、`/api/health` HTTP 探針、`terminationGracePeriodSeconds: 60` + `preStop` 優雅停機、`nodeSelector`（`robot-infra/gpu-pool: rtx-pro-6000` + `gpu.capability/rtx-gfx: "true"`）+ `nodeAffinity`（強制 `NotIn` 排除 A100/H100/H200/B200/B300/GB200/GB300）、預設 MIG `nvidia.com/mig-1g.24gb.gfx: 1`、`requests: 4C/16Gi/2Gi-ephemeral`、`limits: 8C/32Gi/12Gi-ephemeral`、`/dev/shm: 8Gi`。
- **PVC (`k8s/base/pvc.yaml`)**：`selkies-pvc`（`100Gi`、`local-path` → `/home/ubuntu`）、`selkies-podman-pvc`（`80Gi`、`local-path` → `/home/ubuntu/.local/share/containers`）。
- **Service (`k8s/base/service.yaml`)**：純 `ClusterIP`（`80→8080`、`2223→2223`、`2222→2222`、`7448→7448`），零 NodePort。
- **Ingress (`k8s/base/ingress.yaml`)**：`ingressClassName: nginx`、`proxy-body-size: 4g`（防拖慢共用 Ingress）、`proxy-read/send-timeout: 3600`、`proxy-buffering: off`、`/ssh` (Exact → 2223)、`/zenoh` (Exact → 7448，容器內建 Basic Auth 保護) 與 `/` (Prefix → 80)。

### 7.2 每個使用者目錄可控檔案（`k8s/users/<user>/`）

| 檔案 | 可控參數與修改重點 |
| --- | --- |
| `auth.env` | `WEB_PASSWORD`（Selkies Basic Auth 密碼）、`LINUX_PASSWORD`（SSH / `sudo` 密碼）— 建議透過 CI/Vault 動態產生，切勿提交真實密碼 |
| `patch.yaml` | `SELKIES_BASIC_AUTH_USER`（登入帳號）、`SELKIES_WEBRTC_UDP_MUX_PORT`（唯一埠號）、`ROS_DOMAIN_ID`（唯一網域）、CPU/RAM 與 MIG 規格（例如覆寫為 `nvidia.com/mig-2g.48gb.gfx: 1` 並將原 `1g` 設 `null`）、個人與 Podman PVC 容量 |
| `kustomization.yaml` | `namePrefix: <user>-`、`labels.pairs.app.kubernetes.io/user: <user>`、`components` 積木清單、Ingress `tls[0].hosts[0]` 與 `rules[0].host`、以及當 UDP 埠不為 `50001` 時用 JSON Patch 覆寫 `/spec/template/spec/containers/0/ports/3/containerPort` 與 `hostPort`（可參考 [k8s/users/alice/kustomization.yaml](./k8s/users/alice/kustomization.yaml)） |

### 7.3 七個可插拔 Kustomize Components（`k8s/components/`）

於 `k8s/users/<user>/kustomization.yaml` 的 `components:` 取消註解即可啟用：

| Component 路徑 | 實際套用的 Patch 變更 | 適用時機 |
| --- | --- | --- |
| `../../components/seccomp-podman-localhost` | 將 `seccompProfile` 由 `Unconfined` 切換為 `type: Localhost`、`localhostProfile: profiles/podman-rootless.json` | **Linux 生產環境強烈建議必開**（前提：已將 JSON 放到 PRO 6000 節點 `/var/lib/kubelet/seccomp/profiles/`） |
| `../../components/smarter-device-tun` | 移除 `hostPath: /dev/net/tun` 並改於 `resources` 申請 `smarter-devices/net_tun: 1` | **OPA Gatekeeper 禁止 `hostPath` 的 Linux K8s 叢集必開**（`smarter-device-manager` 僅鎖定 PRO 6000 節點） |
| `../../components/cross-pod-ros` | 注入 `ROS_BRIDGE_HUB_ENDPOINT`、`ROS_BRIDGE_HUB_WSS_URL`、`ROS_BRIDGE_INSECURE_TLS=1` | 搭配 `robotics-infra` 之 `rosZenohHub.enabled=true`，使用者輸入 `ros-bridge hub` 免查 K8s Service |
| `../../components/monitoring` | 開啟 `SELKIES_ENABLE_METRICS_HTTP=true` 並掛載 `:9108` Read-Only Sidecar（複用同映像、0 GPU、清洗高基數 `webrtc_statistics_info`） | 納入生產 `kube-prometheus-stack`（Prometheus + Grafana）監控 FPS、RTT 延遲、記憶體、`/dev/shm`、PVC 與服務健康 |
| `../../components/shared-isaac-sim` | 唯讀掛載 `isaac-sim-6-2-shared-ro-pvc` → `/opt/isaac-sim` 與 `isaac-sim-6-2-assets-ro-pvc` → `/opt/isaac-sim-assets` | 需要執行 Isaac Sim 6.2 的開發者 |
| `../../components/transport-websockets` | 移除 `ports[3]`（UDP `hostPort`），並將 `SELKIES_MODE=websockets`、`SELKIES_ENABLE_DUAL_MODE=false`、`SELKIES_WEBRTC_ICE_LITE=false` | 防火牆全面封鎖 UDP，改走純 TCP 443 |
| `../../components/apparmor-unconfined` | 設定 `securityContext.appArmorProfile.type: Unconfined`（K8s 1.30+ GA；K8s 1.28/1.29 改用 Annotation） | Ubuntu 24.04 Linux 宿主機開啟 `kernel.apparmor_restrict_unprivileged_userns=1` 時必開 |

---

## 7.5 推上生產環境前必確認的 6 個環境問題（與維運核對清單）

在正式部署至生產 **Linux Server Kubernetes** 前，建議先執行一鍵唯讀檢核腳本 `./deploy/manage-user.sh preflight`（或逐條跑下方唯讀指令），與維運團隊確認以下 **6 個關鍵環境問題**：

1. **GPU Operator 現況**：現行 `ClusterPolicy` 的 `mig.strategy` 是 `mixed` 還是 `single`？PRO 6000 節點是否有設 Taint（例如 `nvidia.com/gpu=present:NoSchedule`，有的話需在 YAML 補 `tolerations`）？驅動是否為 R570+？
   ```bash
   kubectl get clusterpolicy -o custom-columns='NAME:.metadata.name,MIG_STRATEGY:.spec.mig.strategy,MIG_CM:.spec.migManager.config.name'
   kubectl get nodes -l nvidia.com/gpu.present=true \
     -o custom-columns='NODE:.metadata.name,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,MIG_CFG:.metadata.labels.nvidia\.com/mig\.config,DRIVER:.metadata.labels.nvidia\.com/cuda\.driver\.major,TAINTS:.spec.taints[*].key'
   ```
   - 若回傳 `mixed`（或 H200/H100/A100/B300 皆為整卡 `all-disabled`）：直接執行 `./deploy/gpu-operator/apply-pro6000-mig-safe.sh --dry-run <pro6000-node>` → `--apply`（v4 預設**原地更新既有 ConfigMap 免改 `ClusterPolicy`**，且自動檢查節點無執行中桌面 Pod 才切卡）。
   - **若已有 H200/H100/A100/B300 在 `single` 策略下啟用 MIG**：切勿改全叢集 `mig.strategy`！請讓 PRO 6000 改套均切 Profile（如 `MIG_PROFILE=all-2g.48gb.gfx`），並將使用者 Pod 資源改申請 `nvidia.com/gpu: 1`。

2. **StorageClass 種類**：叢集目前提供哪一個區塊型 StorageClass（如 `ceph-rbd`、`longhorn`、`topolvm` 或 `local-path`）？有無獨立 NFS / CephFS 供唯讀掛載 Isaac Sim 6.2？
   ```bash
   kubectl get storageclass
   ```
   - 依實際叢集修改 `k8s/base/pvc.yaml` 的 `storageClassName`；**生產強烈建議選用支援硬體容量上限（Hard Quota）的區塊型儲存**（避免標準 `local-path` 單人寫爆整顆節點 NVMe 引發 `DiskPressure`），且**嚴禁對 `selkies-podman-pvc` 使用 NFS**（僅 `shared-isaac-sim` `ROX` 適合 NFS/CephFS）。

3. **共用 Ingress-NGINX 規範**：公司現有的 Ingress Controller 名稱是否為 `nginx`？是否允許 WebSocket 長連線與 Basic Auth（v4 容器內已原生內建 `/zenoh` Basic Auth 代理，零額外 Ingress annotation 依賴；若開啟共用 `rosZenohHub.ingress` 則會用到 `auth-type: basic`）？Wildcard DNS（`*.selkies.local` 或正式內網域名）與 TLS 憑證是否已備妥？
   ```bash
   kubectl get ingressclass
   kubectl -n robotics get secret selkies-wildcard-tls
   ```

4. **叢集資安門檻（PSA / OPA / AppArmor）**：
   - PRO 6000 節點作業系統是否為 Ubuntu 24.04（決定是否必開 `components/apparmor-unconfined`）？並將 `podman-rootless-seccomp.json` 複製至 PRO 6000 節點 `/var/lib/kubelet/seccomp/profiles/podman-rootless.json` 後啟用 `components/seccomp-podman-localhost`。
   - 叢集 OPA / Kyverno 是否允許 `robotics` Namespace 使用 UDP `hostPort`（`50001..50050`）與 `/dev/net/tun` `hostPath`（禁止的話改開 `components/transport-websockets` 與 `components/smarter-device-tun`）？
   ```bash
   # 在 PRO 6000 節點唯讀確認核心參數：
   sysctl user.max_user_namespaces kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true
   # 檢查 Namespace PSA 標籤與 Gatekeeper/Kyverno 規則：
   kubectl get ns robotics --show-labels
   kubectl get crd constrainttemplates.templates.gatekeeper.sh clusterpolicies.kyverno.io 2>/dev/null || true
   ```

5. **`kube-prometheus-stack` 選擇器標籤**：生產 Prometheus 的 `serviceMonitorSelector` 與 `ruleSelector` 需要帶什麼特定 Label（常見如 `release: kube-prometheus-stack`）才能自動收錄我們的 `ServiceMonitor` 與 `PrometheusRule`？
   ```bash
   kubectl get prometheus -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SM_SELECTOR:.spec.serviceMonitorSelector,RULE_SELECTOR:.spec.ruleSelector'
   ```

6. **單台 PRO 6000 伺服器實體規格**：預計一張 96GB PRO 6000 切給幾位使用者同時在線？節點 CPU 核心數、實體 RAM 與 `kubelet` 的 `podPidsLimit`（建議 `>= 4096`）為何？
   - **全叢集網路開銷**：CycloneDDS 鎖定 `lo`（**0 pps CNI 廣播**）；`webrtc-udp-mux` 單人約 `8–15 Mbps` 直出（單卡 3–4 人僅佔 10GbE `< 0.6%`）；同節點 `zenoh-hub` 跨 Pod 流量 100% 走節點內虛擬網橋（`< 0.2 ms`）。
   - **單張 RTX PRO 6000 (96GB) 建議最低規格（支援 3～4 人 + `zenoh-hub`）**：**CPU ≥ 32 vCPU**（重度 Isaac Sim 建議 48–64 vCPU；v4 已預設 `CMAKE_BUILD_PARALLEL_LEVEL=4` 防編譯搶核）、**RAM ≥ 128 GiB**（多開模擬建議 192–256 GiB，含 `/dev/shm`）、**實體 `ext4/xfs` NVMe SSD ≥ 1–1.5 TB**、`podPidsLimit ≥ 4096`。

### 7.4 新增／更新／休眠使用者操作指令（推薦使用 `deploy/manage-user.sh` 零中斷維運）
```bash
chmod +x deploy/manage-user.sh

# 0. 上線前唯讀檢查上述 6 大環境問題
./deploy/manage-user.sh preflight

# 1. 安全開通新使用者（自動檢查埠衝突、自動生成 24 字元強密碼、獨立釘選 v4 映像）
./deploy/manage-user.sh create bob --udp-port 50003 --domain 13 --mig 1g

# 2. 預演並「單獨」部署 bob（自動攔截弱密碼，且 100% 不會重啟其他在線開發者！）
./deploy/manage-user.sh apply bob --dry-run
./deploy/manage-user.sh apply bob

# 3. 閒置休眠（立即釋放 PRO 6000 MIG 切片，100% 保留 /home/ubuntu 與 Podman PVC）與喚醒
./deploy/manage-user.sh hibernate bob
./deploy/manage-user.sh wake bob
./deploy/manage-user.sh status
```

---

## 8. （選配）全 Helm 使用者部署（`charts/selkies-user` 與 `deploy/deploy.sh`）

若維運團隊希望連同每位使用者皆由獨立 Helm Release 管理，專案亦保留完整的 `charts/selkies-user/` 與 `deploy/deploy.sh`。

### 8.1 `deploy/deploy.sh` 啟動參數與用法
```bash
chmod +x deploy/deploy.sh
./deploy/deploy.sh dio                           # 單獨部署或更新 dio（Release: selkies-dio）
./deploy/deploy.sh --all                         # 批次同步 deploy/users/*.yaml 全員
NAMESPACE=robotics ./deploy/deploy.sh dio --dry-run  # 預演並指定 Namespace
```

### 8.2 `charts/selkies-user/values.yaml` 關鍵可控參數群組

| 參數群組 | 主要可控鍵值與預設值 |
| --- | --- |
| `user.*` | `name`, `enabled`, `timezone` (`Asia/Taipei`), `rosDomainId` (`11`), `auth.{existingSecretName, webUsername, webPassword, linuxPassword}`, `extraEnv` |
| `image.*` | `repository` (`registry.local/robotics/robot-infra`), `tag` (`v3`), `pullPolicy` (`IfNotPresent`), `pullSecrets` |
| `selkies.*` | `webPort` (`8080`), `encoder`, `framerate` (`60`), `videoBitrate` (`12000`), `audioBitrate` (`""`), `enableResize`, `enableBasicAuth`, `enableHttps`, `webrtcPacer` |
| `transport.*` | `mode` (`webrtc-udp-mux` \| `webrtc-coturn` \| `websockets`), `enableDualMode` (`true`), `airGappedNoExternalStun` (`true`), `udpMuxPort` (`50001`), `tcpMuxPort` (`0`), `publicIpOverride`, `coturn.*` |
| `ssh.*` & `rosBridge.*` | `ssh.{enabled, mode, sshdPort, wsBridgePort, ingressPath}`、`rosBridge.{enabled, wsBridgePort: 7448, ingressPath: "/zenoh", hubEndpoint, hubWssUrl, insecureTls}` |
| `ingress.*` | `enabled`, `className` (`nginx`), `routingMode` (`subdomain` \| `subfolder` — `subfolder` 免 Wildcard DNS!), `baseDomain`, `host`, `tls.{enabled, secretName}`, `extraAnnotations` |
| `gpu.*` & `resources.*` | `gpu.{enabled, pro6000Only: true, resourceName, count, nodeSelector}`, `resources.{requests, limits}`, `shmSizeLimit` (`8Gi`) |
| `storage.*` & `podman.*` | `personalPvc.{enabled, storageClassName, size, mountPath, keepOnDelete}`, `sharedIsaacPvc.*`, `sharedIsaacAssetsPvc.*`, `podman.{enabled, mountTun, storage.*, env}` |
| `podSecurityContext` / `containerSecurityContext` | `runAsUser/Group/fsGroup: 1000`, `seccompProfile`, `privileged: false`, `capabilities` |

---

## 9. NVIDIA GPU Operator `+gfx` MIG 切分參數

[deploy/gpu-operator/custom-mig-parted-config.yaml](./deploy/gpu-operator/custom-mig-parted-config.yaml) 提供 RTX PRO 6000 Blackwell (96GB) 的四組 MIG 切分組態：

| Profile 名稱 | 切分配置 | 特色與適用情境 |
| --- | --- | --- |
| `all-disabled` | 關閉 MIG | 必留設定，避免未啟用 MIG 的叢集節點報錯 |
| `all-1g.24gb.gfx` | `4 × 1g.24gb+gfx` | 高密度 4 人共用單卡（ROS 2 + MoveIt 2 + 輕量渲染） |
| `all-2g.48gb.gfx` | `2 × 2g.48gb+gfx` | 2 人重度模擬（Isaac Sim 6.2 / 大型 USD 場景） |
| `rtx6000-mixed-1x2g-2x1g-gfx` | `1 × 2g.48gb+gfx` + `2 × 1g.24gb+gfx` | ★ 主力混切：兼顧 1 位重度模擬與 2 位常規開發 |

套用指令（**多 GPU 混部叢集含 H200 / H100 / A100 / B300 時，請務必使用安全合併腳本，切勿直接覆寫全叢集 `default-mig-parted-config`**）：
```bash
chmod +x deploy/gpu-operator/apply-pro6000-mig-safe.sh
# 1. 先預演（強制檢核目標節點為 RTX PRO 6000；若誤填 H200/H100/A100/B300 會直接中止）
./deploy/gpu-operator/apply-pro6000-mig-safe.sh --dry-run <pro6000-node-1>

# 2. 確認無誤後正式非破壞式合併並僅標記 PRO 6000 節點
./deploy/gpu-operator/apply-pro6000-mig-safe.sh --apply <pro6000-node-1>
kubectl describe node <pro6000-node-1> | grep -A 10 Allocatable
```

---

## 10. 容器內日常開發指南與離線映像檔同步

### 10.1 經由 Ingress WebSocket 連線 SSH（零 NodePort、支援 VS Code Remote-SSH）
開發者本機安裝 `websocat` 後，於 `~/.ssh/config` 加入：
```sshconfig
Host dio-robot
  HostName dio.selkies.local
  User ubuntu
  ProxyCommand websocat --binary wss://%h/ssh
  ServerAliveInterval 30
```
接著執行 `ssh dio-robot` 或以 VS Code Remote-SSH 選擇 `dio-robot` 即可連線（支援密碼或將公鑰放入 `~/.ssh/authorized_keys`）。

### 10.2 ROS 2 Jazzy、Python 與 `sudo`
- 終端機自動載入 ROS 2 Jazzy + 預設 **`rmw_cyclonedds_cpp`**（`/etc/ros/cyclonedds.xml` 鎖定 `lo`，與內層 `mig-podman`/Docker 直接互通且零跨 Pod 外洩）：直接執行 `ros2 topic list`、`colcon build`；跨 Pod 或跨實體機互通請用 `ros-bridge serve` / `connect` / `hub`。
- Python 3.12 已預裝 `python3-venv`、`python3-full`、`pipx` 與 `/etc/pip.conf`（`break-system-packages = true`）：支援 `python3 -m venv ~/venvs/dev` 與直接 `pip3 install`。
- `sudo` 為安全更新後的真實 setuid-root `sudo`。

### 10.3 離線內網映像檔同步
- **方式 A（中繼機推送至內網 Harbor）**：
  ```bash
  docker pull fritingo/robot-infra:v4
  docker tag fritingo/robot-infra:v4 harbor.company.com/robotics/robot-infra:v4
  docker push harbor.company.com/robotics/robot-infra:v4
  ```
- **方式 B（離線 `docker save` / `load` / `ctr`）**：
  ```bash
  # 匯出
  docker save fritingo/robot-infra:v4 -o robot-infra-v4.tar
  sha256sum robot-infra-v4.tar > robot-infra-v4.tar.sha256

  # 內網校驗並匯入（依節點 Runtime 三擇一）
  sha256sum -c robot-infra-v4.tar.sha256
  docker load -i robot-infra-v4.tar
  podman load -i robot-infra-v4.tar
  sudo ctr -n k8s.io images import robot-infra-v4.tar
  ```

---

## 10.5 Prometheus + Grafana 監控系統（生產對接既有棧 & 本機一鍵測試）

本專案提供 **零重建主映像、零外洩使用者密碼、嚴格隔離 RTX PRO 6000 / `robotics` Namespace（不混入 H200/H100/A100/B300）** 的全棧監控設計：

- **可觀測指標（6 大層級、22 個 Grafana 面板、12 條 Prometheus 告警）**：
  1. **串流體驗 QoE**：Selkies v2.2.1 原生 `fps`、`fps_hist`、`latency`（RTT ms）、`webrtc_pacer_pace_bps`、`webrtc_pacer_queue_bytes`、`webrtc_bridge_dropped_frames`、`webrtc_pacer_events`，並由 `:9108` Sidecar 清洗高基數 `webrtc_statistics_info` 為安全數值指標（`selkies_webrtc_rtt_ms` / `jitter_ms` / `packets_lost` / `frames_dropped`），徹底防範 TSDB 爆量。
  2. **RTX PRO 6000 MIG GPU**：直接復用既有 GPU Operator `dcgm-exporter`（強制過濾 `exported_namespace="robotics"`），追蹤每張 MIG 切片 VRAM、算力、NVENC 編碼負載、溫度與 XID 錯誤。
  3. **計算、記憶體與 PVC**：容器 Memory Working Set vs Limit、`/dev/shm` 即時使用率（防 Isaac Sim / ROS 2 SHM 撐爆）、CPU CFS Throttling（抓 `colcon build` 搶核掉幀）、`/home/ubuntu` 與 Podman PVC 剩餘容量。
  4. **服務健康與 ROS 2 橋接**：`selkies` / `sshd` / `ssh_ws` / `zenoh_ws` / `zenoh_bridge` 埠監聽狀態、活躍 TCP 連線數、`ros-bridge` 活動狀態與 Podman 容器數。

### 方式 A：生產 Linux K8s（對接既有 `kube-prometheus-stack`，零額外 Server）
```bash
# 1. 啟用 ServiceMonitor、12 條 PrometheusRule 與 Grafana Dashboard ConfigMap
#    （若叢集 Prometheus 依 release label 篩選，請加上 --set monitoring.serviceMonitor.additionalLabels.release=kube-prometheus-stack）
helm upgrade --install robotics-infra ./charts/robotics-infra -n robotics \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.prometheusRule.enabled=true \
  --set monitoring.grafanaDashboard.enabled=true

# 2. 在使用者 k8s/users/<user>/kustomization.yaml 啟用 ../../components/monitoring 後套用
kubectl apply -k k8s/users/dio
```

### 方式 B：本機測試電腦（無 K8s，一鍵啟動 Selkies v4 + Exporter + Prometheus + Grafana）
```bash
docker compose -f monitoring/docker-compose.yml up -d
# 瀏覽器開啟：
#   Selkies 桌面：http://localhost:8080  (dio / TestPassword123!)
#   Grafana 儀表板：http://localhost:3000 (admin / robot-infra-admin，已自動預載 Robot-Infra v4 Dashboard)
#   Prometheus UI：http://localhost:9090
#   Exporter 原始指標：http://localhost:9108/metrics
# 測試完畢清理：
docker compose -f monitoring/docker-compose.yml down -v
```

---

## 11. 生產安全基線與 Trivy CVE 掃描修補報告

### 11.1 安全隔離基線
- 非 Root：`USER ubuntu`（`runAsUser/runAsGroup/fsGroup: 1000`）
- 零特權與零宿主命名空間共享：`privileged: false`、`hostNetwork/PID/IPC: false`
- 最小 Capabilities 白名單：`drop: ["ALL"]`，僅保留 `SETUID`、`SETGID`、`CHOWN`、`FOWNER`、`DAC_OVERRIDE`、`AUDIT_WRITE`
- 客製 Seccomp Profile：[podman-rootless-seccomp.json](./charts/robotics-infra/files/podman-rootless-seccomp.json) 封鎖 45 項高危 syscall（`bpf`、`io_uring_*`、`ptrace`、`kexec_load`、`keyctl`/`add_key`/`request_key`、`init_module` 等）
- 租戶隔離 `NetworkPolicy`（禁止跨使用者 Pod 互連、封鎖 `169.254.169.254/32`）與 `LimitRange`

### 11.2 Trivy CVE 修補成果（`fritingo/robot-infra:v4`）

| 嚴重等級 | 修補前總計（可修補） | 修補後總計（可修補） | 修補說明 |
| --- | ---: | ---: | --- |
| **CRITICAL** | 83（71） | **12（0）** | 可修補 CRITICAL **100% 清零**（餘 12 項為 `linux-libc-dev` 上游尚未修補） |
| **HIGH** | 1,270（1,104） | **168（2\*）** | 實質可修補 HIGH **100% 清零**（\*2 項為 Firefox Mozilla PPA `161.0` 與 Ubuntu Snap stub `1:1snap1` 之 epoch 誤報） |
| **MEDIUM** | 5,641（2,537） | **3,127（23\*）** | 降幅 99%+（僅 1 項 `yq v4.54.3` 的 `CVE-2026-97054` 待上游升 Go 1.27.4 + 22 項 Firefox 誤報） |
| **LOW** | 2,520（1,875） | **646（1\*）** | 實質可修補 LOW 清零（1 項為 Firefox 誤報） |
| **Python / `ipp-usb`** | 44 / 77 | **0 / 0** | `pillow 13.0.0`、`msgpack 1.2.4` 與移除 `ipp-usb` 後全數清零 |

- **已修補並推送之 Docker Hub Digest**：`docker.io/fritingo/robot-infra:v4@sha256:34bb889bbe09e67b39d28fff8b3cac67b4d59bd107d4ff4659ca5dd200776958`
- **本機覆驗指令**：
  ```bash
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy:latest image --ignore-unfixed --severity CRITICAL,HIGH fritingo/robot-infra:v4
  ```

---

## 12. 常見問題排解（Troubleshooting）

- **WebRTC 黑畫面或持續轉圈**：確認防火牆放行客戶端直連節點 UDP `50000-51000`；可先在網頁側邊欄切至 **WebSockets** 保底，並確認 `selkies-airgap-rtc-config` 存在。
- **Podman 報 `cannot clone: Operation not permitted` 或 `create keyring: Operation not permitted`**：確認節點已放置 `/var/lib/kubelet/seccomp/profiles/podman-rootless.json`（Ubuntu 24.04 若受 AppArmor 限制請一併啟用 `components/apparmor-unconfined`），且 `config/containers.conf` 維持 `keyring = false` 與 `default_sysctls = []`。
- **Podman 報 `fuse: device not found`**：確認 `/home/ubuntu/.local/share/containers` 已獨立掛載實體 ext4/xfs PVC（`selkies-podman-pvc`）或本機 Docker Volume。
- **`launch-isaac-sim` 報找不到 NVIDIA Vulkan 裝置**：確認 Pod 申請的是 RTX PRO 6000 **`+gfx` MIG Profile** 且注入了 `NVIDIA_DRIVER_CAPABILITIES=all`。
