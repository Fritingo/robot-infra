# syntax=docker/dockerfile:1.7
# 沿用原本可正常啟動 EGL/DRI3/KDE 與 supervisord 的 Ubuntu 24.04 基底
FROM ghcr.io/selkies-project/nvidia-egl-desktop:24.04

ARG ROS_DISTRO=jazzy
ARG SELKIES_VERSION=2.2.1
ARG WEBSOCAT_VERSION=v1.14.1
ARG DEBIAN_FRONTEND=noninteractive

USER root

# ==============================================================================
# 1. 系統工具、OpenSSH、Vulkan/OpenGL 診斷工具與 Rootless Podman
# ==============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg2 \
    lsb-release \
    locales \
    software-properties-common \
    git \
    tmux \
    vim \
    iproute2 \
    openssh-server \
    vulkan-tools \
    mesa-utils \
    podman \
    passt \
    slirp4netns \
    uidmap \
    fuse-overlayfs \
    containernetworking-plugins \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    ROS_DISTRO=${ROS_DISTRO}

# ==============================================================================
# 2. 安裝 ROS 2 Jazzy Desktop + MoveIt 2 + rmw_zenoh_cpp + ros2_control
# ==============================================================================
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
      -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME}") main" \
      > /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      ros-${ROS_DISTRO}-desktop \
      ros-${ROS_DISTRO}-moveit \
      ros-${ROS_DISTRO}-rmw-zenoh-cpp \
      ros-${ROS_DISTRO}-vision-msgs \
      ros-${ROS_DISTRO}-ros2-control \
      ros-${ROS_DISTRO}-ros2-controllers \
      python3-colcon-common-extensions \
      python3-rosdep \
      python3-vcstool \
    && (rosdep init || true) \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# 3. 升級安裝官方 Selkies v2.2.1 Ubuntu 24.04 .deb（支援 UDP Mux 與 WebSockets）
#    安裝至 /opt/selkies 與 /usr/bin/selkies，不干擾原映像的 X11/EGL/Audio 管線
# ==============================================================================
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    PKG="selkies-${SELKIES_VERSION}-ubuntu24.04-${ARCH}.deb"; \
    BASE_URL="https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}"; \
    mkdir -p /tmp/selkies-pkg; \
    cd /tmp/selkies-pkg; \
    curl -fsSLO "${BASE_URL}/${PKG}"; \
    curl -fsSLO "${BASE_URL}/SHA256SUMS"; \
    sha256sum --check --ignore-missing SHA256SUMS; \
    apt-get update; \
    apt-get purge -y selkies-js-interposer || true; apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-overwrite" "./${PKG}"; \
    rm -rf /tmp/selkies-pkg /var/lib/apt/lists/*

# ==============================================================================
# 4. 安裝 websocat（支援 Ingress /ssh WebSocket 隧道）
# ==============================================================================
RUN ARCH="$(uname -m)" \
    && case "${ARCH}" in \
         x86_64)  WS_ARCH="x86_64-unknown-linux-musl" ;; \
         aarch64) WS_ARCH="aarch64-unknown-linux-musl" ;; \
         *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/vi/websocat/releases/download/${WEBSOCAT_VERSION}/websocat.${WS_ARCH}" \
       -o /usr/local/bin/websocat \
    && chmod 0755 /usr/local/bin/websocat

# ==============================================================================
# 5. 安全漏洞修補（CVE Remediation）+ 無特權 Rootless Podman + Python venv/pip + real sudo + pactl
#    - 升級全部 Ubuntu 24.04 套件（含 linux-libc-dev、apt、sudo、util-linux、python3-* 等）
#    - 移除容器內未使用的 ipp-usb（Go stdlib 77 CVEs）、nginx/apache2-utils（9 HIGH CVEs）
#    - 升級 /usr/bin/yq 至最新版並升級 /usr/local Python 的 pillow>=13.0.0、msgpack>=1.2.4
# ==============================================================================
ARG YQ_VERSION=v4.54.3
RUN set -eux; \
    (apt-get update -o Acquire::Retries=2 -o Acquire::http::Timeout=15 || true); \
    apt-get purge -y ipp-usb nginx nginx-common nginx-core apache2-utils || true; \
    apt-get upgrade -y --no-install-recommends \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold"; \
    apt-get install -y --no-install-recommends \
      pulseaudio-utils \
      python3-venv \
      python3-full \
      pipx; \
    rm -rf /var/lib/apt/lists/*; \
    printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf; \
    chmod 0644 /etc/pip.conf; \
    pip3 install --no-cache-dir --upgrade "pillow>=13.0.0" "msgpack>=1.2.4"; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" -o /usr/bin/yq; \
    chmod 0755 /usr/bin/yq; \
    if [ -f /usr/bin/sudo ] && [ ! -L /usr/bin/sudo ]; then \
      chmod 4755 /usr/bin/sudo; \
      ln -snf /usr/bin/sudo /usr/bin/sudo-root; \
    elif [ -x /usr/bin/sudo-root ]; then \
      ln -snf /usr/bin/sudo-root /usr/bin/sudo; \
    fi

COPY config/containers.conf /etc/containers/containers.conf
COPY config/storage.conf /etc/containers/storage.conf
COPY config/registries.conf /etc/containers/registries.conf

# Single-UID Rootless Podman：清空 /etc/subuid 與 /etc/subgid，搭配 storage.conf 的 ignore_chown_errors="true"
# 避免在非特權 K8s/Docker 容器內呼叫 newuidmap 寫入多段 uid_map 時觸發 Operation not permitted
RUN : > /etc/subuid && : > /etc/subgid && chmod 0644 /etc/subuid /etc/subgid

# ==============================================================================
# 5.5 v3 網路與 ROS 2 互通升級：預設 CycloneDDS (lo 直通 Podman/Docker) + zenoh-bridge-ros2dds (跨 Pod Ingress WSS)
# ==============================================================================
ARG ZENOH_BRIDGE_VERSION=1.10.2
RUN set -eux; \
    (apt-get update -o Acquire::Retries=2 -o Acquire::http::Timeout=15 || true); \
    apt-get install -y --no-install-recommends \
      ros-${ROS_DISTRO}-rmw-cyclonedds-cpp \
      unzip; \
    rm -rf /var/lib/apt/lists/*; \
    ARCH="$(uname -m)"; \
    case "${ARCH}" in \
      x86_64)  ZB_ARCH="x86_64-unknown-linux-gnu" ;; \
      aarch64) ZB_ARCH="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac; \
    mkdir -p /tmp/zenoh-bridge /etc/ros; \
    curl -fsSL "https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds/releases/download/${ZENOH_BRIDGE_VERSION}/zenoh-plugin-ros2dds-${ZENOH_BRIDGE_VERSION}-${ZB_ARCH}-standalone.zip" \
      -o /tmp/zenoh-bridge/bridge.zip; \
    unzip -q /tmp/zenoh-bridge/bridge.zip zenoh-bridge-ros2dds -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/zenoh-bridge-ros2dds; \
    rm -rf /tmp/zenoh-bridge

COPY config/cyclonedds.xml /etc/ros/cyclonedds.xml
RUN chmod 0644 /etc/ros/cyclonedds.xml

# ==============================================================================
# 6. 全域 Shell 環境初始化（寫在 /etc，掛載空白個人 PVC 依然自動載入）
#    - v3 預設改用 CycloneDDS (lo + 127.0.0.1)，直接與內層 Podman/Docker 零設定互通且不洩漏 multicast 至宿主機/CNI
#    - 跨 Pod / 跨實體機請使用 ros-bridge serve / connect / hub（經由 Ingress /zenoh）
# ==============================================================================
RUN cat <<'EOF' > /etc/profile.d/99-robotics-env.sh
export PATH="${HOME}/.local/bin:${PATH}"
export ROS_DISTRO="jazzy"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export CYCLONEDDS_URI="${CYCLONEDDS_URI:-file:///etc/ros/cyclonedds.xml}"
export ZENOH_ROUTER_CHECK_ATTEMPTS="${ZENOH_ROUTER_CHECK_ATTEMPTS:-5}"
export ZENOH_CONFIG_OVERRIDE="${ZENOH_CONFIG_OVERRIDE:-transport/shared_memory/enabled=true;transport/shared_memory/transport_optimization/pool_size=268435456}"
# v4 生產防搶核預設：限制 colcon / CMake / Make 預設平行編譯數為 4（避免單人吃滿整台節點核心導致同卡桌面掉幀；仍可手動覆寫）
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
export MAKEFLAGS="${MAKEFLAGS:--j4}"

if [ -n "${BASH_VERSION:-}" ] && [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
fi

# 自動偵測原映像啟動的 X11 Socket（通常為 :20 或 :0），讓 SSH 終端機也能直接開 GUI
if [ -z "${DISPLAY:-}" ]; then
  for sock in /tmp/.X11-unix/X*; do
    if [ -S "$sock" ]; then
      export DISPLAY=":${sock##*X}"
      break
    fi
  done
fi
EOF
RUN chmod 0644 /etc/profile.d/99-robotics-env.sh \
    && echo 'source /etc/profile.d/99-robotics-env.sh' >> /etc/bash.bashrc

# ==============================================================================
# 7. 安裝腳本與 supervisord 服務（保留原映像 ENTRYPOINT，僅替換 selkies 行程）
# ==============================================================================
COPY scripts/init-perms.sh /usr/local/bin/init-perms.sh
COPY scripts/start-selkies.sh /usr/local/bin/start-selkies.sh
COPY scripts/start-sshd.sh /usr/local/bin/start-sshd.sh
COPY scripts/mig-podman /usr/local/bin/mig-podman
COPY scripts/launch-isaac-sim /usr/local/bin/launch-isaac-sim
COPY scripts/ros-bridge /usr/local/bin/ros-bridge
COPY scripts/zenoh-ws-auth-proxy.py /usr/local/bin/zenoh-ws-auth-proxy.py
COPY monitoring/exporter/robot_metrics_exporter.py /usr/local/bin/robot-metrics-exporter
RUN mkdir -p /run/sshd \
    && chmod 0755 \
    /run/sshd \
    /usr/local/bin/init-perms.sh \
    /usr/local/bin/start-selkies.sh \
    /usr/local/bin/start-sshd.sh \
    /usr/local/bin/mig-podman \
    /usr/local/bin/launch-isaac-sim \
    /usr/local/bin/ros-bridge \
    /usr/local/bin/zenoh-ws-auth-proxy.py \
    /usr/local/bin/robot-metrics-exporter

# 移除舊版 selkies-gstreamer / nginx 設定，將基礎桌面服務改以 ubuntu 執行、加上日誌輪替上限，並修正非 Root sshd 的 PAM 限制
RUN <<'EOF'
python3 - <<'PY'
import glob, re

targets = ["/etc/supervisord.conf", "/etc/supervisor/supervisord.conf"] + glob.glob("/etc/supervisor/conf.d/*.conf")
for p in targets:
    try:
        txt = open(p).read()
    except FileNotFoundError:
        continue
    new_txt = txt
    for prog in ("selkies-gstreamer", "nginx"):
        new_txt = re.sub(rf"(?ms)^\[program:{prog}\].*?(?=^\[|\Z)", "", new_txt)
    if p == "/etc/supervisord.conf":
        for prog in ("entrypoint", "dbus", "pipewire", "wireplumber", "pipewire-pulse", "kasmvnc"):
            def _patch_block(m):
                blk = m.group(1).rstrip("\n")
                if not re.search(r"(?m)^user\s*=", blk):
                    blk += "\nuser=ubuntu"
                if not re.search(r"(?m)^stdout_logfile_maxbytes\s*=", blk):
                    blk += "\nstdout_logfile_maxbytes=10MB\nstdout_logfile_backups=2"
                if not re.search(r"(?m)^stderr_logfile_maxbytes\s*=", blk):
                    blk += "\nstderr_logfile_maxbytes=10MB\nstderr_logfile_backups=2"
                return blk + "\n\n"
            new_txt = re.sub(
                rf"(?ms)(^\[program:{prog}\]\n(?:(?!^\[).)*?)(?=^\[|\Z)",
                _patch_block,
                new_txt,
            )
    if new_txt != txt:
        open(p, "w").write(new_txt)
PY
chmod 0644 /etc/supervisord.conf 2>/dev/null || true
rm -f /etc/ssh/sshd_config.d/*.conf || true
sed -i 's/^session\s\+required\s\+pam_loginuid.so/#session required pam_loginuid.so/' /etc/pam.d/sshd
EOF

COPY supervisor/init-perms.conf /etc/supervisor/conf.d/init-perms.conf
COPY supervisor/selkies.conf /etc/supervisor/conf.d/selkies.conf
COPY supervisor/sshd.conf /etc/supervisor/conf.d/sshd.conf
COPY supervisor/ssh-ws.conf /etc/supervisor/conf.d/ssh-ws.conf
COPY supervisor/zenoh-ws.conf /etc/supervisor/conf.d/zenoh-ws.conf
COPY supervisor/zenohd.conf /etc/supervisor/conf.d/zenohd.conf

# ==============================================================================
# 8. Selkies v2.2.1 與 ROS 2 CycloneDDS 預設環境變數及非 Root 執行身分
# ==============================================================================
ENV SELKIES_PORT=8080 \
    SELKIES_MODE=webrtc \
    SELKIES_ENABLE_DUAL_MODE=true \
    SELKIES_ENABLE_HTTPS=false \
    SELKIES_ENABLE_BASIC_AUTH=true \
    SELKIES_ENCODER=h264enc,h265enc,vp9enc,av1enc,h264enc-striped,jpeg \
    SELKIES_FRAMERATE=60 \
    SELKIES_VIDEO_BITRATE=12000 \
    SELKIES_ENABLE_RESIZE=true \
    SELKIES_WEBRTC_ICE_LITE=false \
    SELKIES_WEBRTC_PACER=true \
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    CYCLONEDDS_URI=file:///etc/ros/cyclonedds.xml

USER ubuntu

EXPOSE 8080 2222 2223 7448
