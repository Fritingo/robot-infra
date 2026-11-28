#!/usr/bin/env python3
"""
Robot-Infra v3 Lightweight Read-Only Prometheus Metrics Exporter (:9108/metrics)

Design goals:
- Zero third-party Python dependencies (pure Python 3 stdlib) -> reuses robot-infra:v3
  image directly with zero extra air-gapped images or CVEs.
- Bridges Selkies v2.2.1 authenticated loopback endpoint (127.0.0.1:8080/api/metrics)
  so Prometheus NEVER needs access to per-user Basic Auth password Secrets.
- Strips Selkies' high-cardinality `webrtc_statistics_info` Info metric (preventing
  Prometheus TSDB cardinality explosion) while extracting clean numeric WebRTC gauges
  (RTT, jitter, packets lost, frames dropped, client FPS, bytes received).
- Exposes Robot-Infra specific metrics unavailable in cAdvisor/DCGM:
  * Core service port liveness & active TCP connections (selkies/sshd/ssh_ws/zenoh_ws/zenoh_bridge)
  * /dev/shm, /home/ubuntu, and Podman storage usage via read-only statvfs
  * Rootless Podman container count (read-only JSON inspection)
  * Optional local Docker Compose host/GPU metrics (ENABLE_LOCAL_HOST_METRICS=true; OFF in K8s)
"""

import base64
import json
import os
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Optional, Tuple

LISTEN_ADDR = os.environ.get("EXPORTER_LISTEN_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("EXPORTER_PORT", "9108"))
EXPORTER_MODE = os.environ.get("EXPORTER_MODE", "selkies").strip().lower()
ROBOT_USER = os.environ.get("ROBOT_USER", "").strip()

SELKIES_PORT = int(os.environ.get("SELKIES_PORT", "8080"))
SELKIES_SUBFOLDER = os.environ.get("SELKIES_SUBFOLDER", "").strip("/")
_PREFIX = f"/{SELKIES_SUBFOLDER}" if SELKIES_SUBFOLDER else ""
SELKIES_METRICS_URL = os.environ.get(
    "SELKIES_METRICS_URL", f"http://127.0.0.1:{SELKIES_PORT}{_PREFIX}/api/metrics"
)
SELKIES_STATUS_URL = os.environ.get(
    "SELKIES_STATUS_URL", f"http://127.0.0.1:{SELKIES_PORT}{_PREFIX}/api/status"
)
BASIC_AUTH_USER = os.environ.get("SELKIES_BASIC_AUTH_USER", "").strip()
BASIC_AUTH_PASS = os.environ.get(
    "SELKIES_BASIC_AUTH_PASSWORD", os.environ.get("PASSWD", "")
)
HTTP_TIMEOUT = float(os.environ.get("EXPORTER_HTTP_TIMEOUT", "2.5"))

ENABLE_LOCAL_HOST_METRICS = (
    os.environ.get("ENABLE_LOCAL_HOST_METRICS", "false").strip().lower()
    in ("1", "true", "yes")
)
HOME_STORAGE_PATH = os.environ.get("HOME_STORAGE_PATH", "/home/ubuntu")
PODMAN_STORAGE_PATH = os.environ.get(
    "PODMAN_STORAGE_PATH", "/home/ubuntu/.local/share/containers"
)
SHM_PATH = os.environ.get("SHM_PATH", "/dev/shm")

SELKIES_PORTS: List[Tuple[str, int]] = [
    ("selkies", SELKIES_PORT),
    ("sshd", int(os.environ.get("SSH_TCP_PORT", "2222"))),
    ("ssh_ws", int(os.environ.get("SSH_WS_PORT", "2223"))),
    ("zenoh_ws", int(os.environ.get("ZENOH_WS_PORT", "7448"))),
    ("zenoh_bridge", int(os.environ.get("ZENOH_BRIDGE_PORT", "7447"))),
]

ZENOH_HUB_PORTS: List[Tuple[str, int]] = [
    ("zenoh_tcp", int(os.environ.get("ZENOH_TCP_PORT", "7447"))),
    ("zenoh_ws", int(os.environ.get("ZENOH_WS_PORT", "7448"))),
]

_DROP_METRIC_PREFIXES = (
    "webrtc_statistics_info",
    "python_gc_",
    "python_info",
    "process_",
)

_LABEL_PAIR_RE = re.compile(r'([a-zA-Z0-9_.-]+)="((?:\\.|[^"\\])*)"')

_cached_auth_user: Optional[str] = None
_gpu_cache: Tuple[float, List[str]] = (0.0, [])


def _esc(val: str) -> str:
    return val.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _fmt_labels(extra: Optional[Dict[str, str]] = None) -> str:
    labels: Dict[str, str] = {}
    if ROBOT_USER:
        labels["user"] = ROBOT_USER
    if extra:
        labels.update(extra)
    if not labels:
        return ""
    inner = ",".join(f'{k}="{_esc(str(v))}"' for k, v in labels.items())
    return "{" + inner + "}"


def _http_get(url: str, auth_user: Optional[str] = None, auth_pass: str = "") -> Tuple[int, str]:
    req = urllib.request.Request(url, method="GET")
    if auth_user is not None and auth_pass:
        token = base64.b64encode(f"{auth_user}:{auth_pass}".encode("utf-8")).decode("ascii")
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, ""
    except Exception:
        return 0, ""


def _fetch_selkies_metrics() -> Tuple[bool, str, float]:
    global _cached_auth_user
    t0 = time.monotonic()

    candidates: List[Optional[str]] = []
    if _cached_auth_user is not None:
        candidates.append(_cached_auth_user)
    if BASIC_AUTH_USER and BASIC_AUTH_USER not in candidates:
        candidates.append(BASIC_AUTH_USER)
    if ROBOT_USER and ROBOT_USER not in candidates:
        candidates.append(ROBOT_USER)
    if "ubuntu" not in candidates:
        candidates.append("ubuntu")
    if None not in candidates:
        candidates.append(None)

    for user in candidates:
        status, body = _http_get(SELKIES_METRICS_URL, user, BASIC_AUTH_PASS)
        if status == 200 and body:
            _cached_auth_user = user
            return True, body, time.monotonic() - t0
        if status == 0:
            # Connection refused / down - no need to retry other credentials
            break
    return False, "", time.monotonic() - t0


def _fetch_selkies_status() -> Optional[dict]:
    status, body = _http_get(SELKIES_STATUS_URL)
    if status == 200 and body:
        try:
            return json.loads(body)
        except Exception:
            return None
    return None


def _inject_user_label(sample_line: str) -> str:
    if not ROBOT_USER:
        return sample_line
    # Format: metric_name{k="v"} value [ts] OR metric_name value [ts]
    if "{" in sample_line:
        idx = sample_line.find("{")
        close_idx = sample_line.rfind("}")
        if idx > 0 and close_idx > idx:
            existing = sample_line[idx + 1 : close_idx]
            if re.search(r'(?:^|,)user="', existing):
                return sample_line
            sep = "," if existing else ""
            return (
                sample_line[: idx + 1]
                + f'user="{_esc(ROBOT_USER)}"'
                + sep
                + sample_line[idx + 1 :]
            )
    parts = sample_line.split(None, 1)
    if len(parts) == 2:
        return f'{parts[0]}{{user="{_esc(ROBOT_USER)}"}} {parts[1]}'
    return sample_line


def _parse_webrtc_stats_info(line: str) -> Dict[str, float]:
    """Extract safe numeric WebRTC gauges from Selkies webrtc_statistics_info label set."""
    start = line.find("{")
    end = line.rfind("}")
    if start < 0 or end <= start:
        return {}
    label_blob = line[start + 1 : end]
    kv: Dict[str, str] = {}
    for m in _LABEL_PAIR_RE.finditer(label_blob):
        kv[m.group(1)] = m.group(2)

    def _find_float(suffixes: Tuple[str, ...]) -> Optional[float]:
        for suf in suffixes:
            # Exact match first, then suffix match (e.g. inbound-rtp-xxx.packetsLost)
            if suf in kv:
                try:
                    return float(kv[suf])
                except ValueError:
                    pass
            dot_suf = "." + suf.split(".")[-1]
            prefix_part = suf.split(".")[0]
            for k, v in kv.items():
                if k.startswith(prefix_part) and k.endswith(dot_suf):
                    try:
                        return float(v)
                    except ValueError:
                        pass
        return None

    extracted: Dict[str, float] = {}
    rtt_s = _find_float(("candidate-pair.currentRoundTripTime", "remote-inbound-rtp.roundTripTime"))
    if rtt_s is not None and rtt_s >= 0:
        extracted["selkies_webrtc_rtt_ms"] = rtt_s * 1000.0

    jitter_s = _find_float(("inbound-rtp.jitter",))
    if jitter_s is not None and jitter_s >= 0:
        extracted["selkies_webrtc_jitter_ms"] = jitter_s * 1000.0

    for metric_name, keys in (
        ("selkies_webrtc_packets_lost", ("inbound-rtp.packetsLost",)),
        ("selkies_webrtc_packets_received", ("inbound-rtp.packetsReceived",)),
        ("selkies_webrtc_frames_dropped", ("inbound-rtp.framesDropped",)),
        ("selkies_webrtc_frames_decoded", ("inbound-rtp.framesDecoded",)),
        ("selkies_webrtc_bytes_received", ("inbound-rtp.bytesReceived",)),
        ("selkies_webrtc_client_fps", ("inbound-rtp.framesPerSecond",)),
    ):
        val = _find_float(keys)
        if val is not None and val >= 0:
            extracted[metric_name] = val

    return extracted


def _filter_selkies_exposition(raw: str) -> Tuple[List[str], Dict[str, float]]:
    kept: List[str] = []
    webrtc_gauges: Dict[str, float] = {}
    skip_current_meta = False

    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("# HELP ") or stripped.startswith("# TYPE "):
            parts = stripped.split(None, 3)
            metric_name = parts[2] if len(parts) >= 3 else ""
            skip_current_meta = any(
                metric_name == p or metric_name.startswith(p) for p in _DROP_METRIC_PREFIXES
            )
            if not skip_current_meta:
                kept.append(stripped)
            continue
        if stripped.startswith("#"):
            continue
        if stripped.startswith("webrtc_statistics_info"):
            webrtc_gauges.update(_parse_webrtc_stats_info(stripped))
            continue
        if any(stripped.startswith(p) for p in _DROP_METRIC_PREFIXES):
            continue
        kept.append(_inject_user_label(stripped))

    return kept, webrtc_gauges


def _parse_proc_net_tcp() -> Tuple[set, Dict[int, int], int]:
    """Read /proc/net/tcp and /proc/net/tcp6 in shared Pod network namespace.

    Returns:
      - listening_ports: set of local listening TCP ports
      - established_by_local_port: count of ESTABLISHED connections per local port
      - outbound_zenoh_conns: ESTABLISHED connections to remote ports 7447/7448
    """
    listening = set()
    established_local: Dict[int, int] = {}
    outbound_zenoh = 0

    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        if not os.path.exists(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                next(fh, None)  # skip header
                for line in fh:
                    cols = line.split()
                    if len(cols) < 4:
                        continue
                    local_hex = cols[1]
                    remote_hex = cols[2]
                    state = cols[3]
                    if ":" not in local_hex or ":" not in remote_hex:
                        continue
                    local_port = int(local_hex.rsplit(":", 1)[1], 16)
                    remote_port = int(remote_hex.rsplit(":", 1)[1], 16)
                    if state == "0A":  # TCP_LISTEN
                        listening.add(local_port)
                    elif state == "01":  # TCP_ESTABLISHED
                        established_local[local_port] = established_local.get(local_port, 0) + 1
                        if remote_port in (7447, 7448):
                            outbound_zenoh += 1
        except Exception:
            continue

    return listening, established_local, outbound_zenoh


def _statvfs_bytes(path: str) -> Optional[Tuple[int, int]]:
    if not os.path.exists(path):
        return None
    try:
        st = os.statvfs(path)
        total = st.f_blocks * st.f_frsize
        avail = st.f_bavail * st.f_frsize
        used = max(0, total - (st.f_bfree * st.f_frsize))
        return used, total if total > 0 else max(used + avail, 0)
    except Exception:
        return None


def _count_podman_containers(storage_path: str) -> Optional[int]:
    cjson = os.path.join(storage_path, "storage", "overlay-containers", "containers.json")
    if not os.path.exists(cjson):
        return 0 if os.path.exists(storage_path) else None
    try:
        with open(cjson, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return len(data) if isinstance(data, list) else 0
    except Exception:
        return None


def _collect_local_host_metrics() -> List[str]:
    """Optional metrics for standalone local Docker Compose testing (disabled in K8s).

    Reads /proc/meminfo, /proc/stat, /proc/net/dev, and nvidia-smi so local single-host
    Docker Compose users see real CPU, RAM, Network, and GPU metrics without cAdvisor/DCGM.
    """
    global _gpu_cache
    lines: List[str] = []
    lbl = _fmt_labels()

    # 1. Host/VM Memory from /proc/meminfo (accurate across cgroup v1, v2 & WSL2)
    mem_used: Optional[int] = None
    mem_limit: Optional[int] = None
    try:
        meminfo: Dict[str, int] = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for row in fh:
                parts = row.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    meminfo[parts[0].rstrip(":")] = int(parts[1]) * 1024
        if "MemTotal" in meminfo:
            mem_limit = meminfo["MemTotal"]
            avail = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
            mem_used = max(0, mem_limit - avail)
    except Exception:
        pass

    if mem_used is not None:
        lines.append("# HELP robot_local_memory_used_bytes Host/VM memory used in bytes (local test mode)")
        lines.append("# TYPE robot_local_memory_used_bytes gauge")
        lines.append(f"robot_local_memory_used_bytes{lbl} {mem_used}")
    if mem_limit is not None and mem_limit > 0:
        lines.append("# HELP robot_local_memory_limit_bytes Host/VM memory total in bytes (local test mode)")
        lines.append("# TYPE robot_local_memory_limit_bytes gauge")
        lines.append(f"robot_local_memory_limit_bytes{lbl} {mem_limit}")

    # 2. Active CPU seconds from /proc/stat (works on cgroup v1, v2 & WSL2) + optional cgroup v2 throttling
    try:
        clk_tck = float(os.sysconf("SC_CLK_TCK"))
        with open("/proc/stat", "r", encoding="utf-8") as fh:
            first = fh.readline().split()
        if first and first[0] == "cpu" and len(first) >= 8:
            # user + nice + system + irq + softirq + steal (exclude idle & iowait)
            vals = [int(x) for x in first[1:9]]
            active_jiffies = vals[0] + vals[1] + vals[2] + vals[5] + vals[6] + (vals[7] if len(vals) > 7 else 0)
            lines.append("# HELP robot_local_cpu_usage_seconds_total Cumulative active CPU seconds (local test mode)")
            lines.append("# TYPE robot_local_cpu_usage_seconds_total counter")
            lines.append(f"robot_local_cpu_usage_seconds_total{lbl} {active_jiffies / clk_tck:.6f}")
    except Exception:
        pass

    try:
        if os.path.exists("/sys/fs/cgroup/cpu.stat"):
            cstat: Dict[str, int] = {}
            with open("/sys/fs/cgroup/cpu.stat", "r", encoding="utf-8") as fh:
                for row in fh:
                    parts = row.split()
                    if len(parts) == 2 and parts[1].isdigit():
                        cstat[parts[0]] = int(parts[1])
            if "nr_periods" in cstat and "nr_throttled" in cstat:
                lines.append("# HELP robot_local_cpu_periods_total Total CFS CPU periods (local test mode)")
                lines.append("# TYPE robot_local_cpu_periods_total counter")
                lines.append(f"robot_local_cpu_periods_total{lbl} {cstat['nr_periods']}")
                lines.append("# HELP robot_local_cpu_throttled_periods_total Throttled CFS CPU periods (local test mode)")
                lines.append("# TYPE robot_local_cpu_throttled_periods_total counter")
                lines.append(f"robot_local_cpu_throttled_periods_total{lbl} {cstat['nr_throttled']}")
    except Exception:
        pass

    # Network bytes & drops from /proc/net/dev
    try:
        rx_b = tx_b = rx_d = tx_d = 0
        with open("/proc/net/dev", "r", encoding="utf-8") as fh:
            for row in fh.readlines()[2:]:
                if ":" not in row:
                    continue
                iface, rest = row.split(":", 1)
                iface = iface.strip()
                if iface == "lo":
                    continue
                cols = rest.split()
                if len(cols) >= 12:
                    rx_b += int(cols[0])
                    rx_d += int(cols[3])
                    tx_b += int(cols[8])
                    tx_d += int(cols[11])
        lines.extend([
            "# HELP robot_local_network_receive_bytes_total Non-loopback RX bytes (local test mode)",
            "# TYPE robot_local_network_receive_bytes_total counter",
            f"robot_local_network_receive_bytes_total{lbl} {rx_b}",
            "# HELP robot_local_network_transmit_bytes_total Non-loopback TX bytes (local test mode)",
            "# TYPE robot_local_network_transmit_bytes_total counter",
            f"robot_local_network_transmit_bytes_total{lbl} {tx_b}",
            "# HELP robot_local_network_receive_dropped_total Non-loopback RX dropped packets (local test mode)",
            "# TYPE robot_local_network_receive_dropped_total counter",
            f"robot_local_network_receive_dropped_total{lbl} {rx_d}",
            "# HELP robot_local_network_transmit_dropped_total Non-loopback TX dropped packets (local test mode)",
            "# TYPE robot_local_network_transmit_dropped_total counter",
            f"robot_local_network_transmit_dropped_total{lbl} {tx_d}",
        ])
    except Exception:
        pass

    # GPU metrics via nvidia-smi (cached 5s to keep scrape overhead tiny)
    now = time.monotonic()
    if now - _gpu_cache[0] < 5.0:
        lines.extend(_gpu_cache[1])
    else:
        gpu_lines: List[str] = []
        try:
            proc = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=index,name,utilization.gpu,utilization.encoder,memory.used,memory.total,temperature.gpu,power.draw",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True,
                text=True,
                timeout=2.0,
                check=False,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                gpu_lines.extend([
                    "# HELP robot_local_gpu_utilization_percent GPU compute utilization percent (local test mode)",
                    "# TYPE robot_local_gpu_utilization_percent gauge",
                    "# HELP robot_local_gpu_encoder_utilization_percent GPU NVENC utilization percent (local test mode)",
                    "# TYPE robot_local_gpu_encoder_utilization_percent gauge",
                    "# HELP robot_local_gpu_memory_used_bytes GPU VRAM used in bytes (local test mode)",
                    "# TYPE robot_local_gpu_memory_used_bytes gauge",
                    "# HELP robot_local_gpu_memory_total_bytes GPU VRAM total in bytes (local test mode)",
                    "# TYPE robot_local_gpu_memory_total_bytes gauge",
                    "# HELP robot_local_gpu_temperature_celsius GPU temperature in Celsius (local test mode)",
                    "# TYPE robot_local_gpu_temperature_celsius gauge",
                    "# HELP robot_local_gpu_power_watts GPU power draw in Watts (local test mode)",
                    "# TYPE robot_local_gpu_power_watts gauge",
                ])
                for row in proc.stdout.strip().splitlines():
                    parts = [p.strip() for p in row.split(",")]
                    if len(parts) < 8:
                        continue
                    glbl = _fmt_labels({"gpu": parts[0], "modelName": parts[1]})
                    def _num(s: str) -> Optional[float]:
                        try:
                            return float(s)
                        except ValueError:
                            return None
                    u_gpu, u_enc, m_used, m_tot, temp, pwr = (_num(parts[i]) for i in range(2, 8))
                    if u_gpu is not None:
                        gpu_lines.append(f"robot_local_gpu_utilization_percent{glbl} {u_gpu}")
                    if u_enc is not None:
                        gpu_lines.append(f"robot_local_gpu_encoder_utilization_percent{glbl} {u_enc}")
                    if m_used is not None:
                        gpu_lines.append(f"robot_local_gpu_memory_used_bytes{glbl} {int(m_used * 1048576)}")
                    if m_tot is not None:
                        gpu_lines.append(f"robot_local_gpu_memory_total_bytes{glbl} {int(m_tot * 1048576)}")
                    if temp is not None:
                        gpu_lines.append(f"robot_local_gpu_temperature_celsius{glbl} {temp}")
                    if pwr is not None:
                        gpu_lines.append(f"robot_local_gpu_power_watts{glbl} {pwr}")
        except Exception:
            pass
        _gpu_cache = (now, gpu_lines)
        lines.extend(gpu_lines)

    return lines


def build_metrics_payload() -> str:
    lines: List[str] = []
    listening, established, outbound_zenoh = _parse_proc_net_tcp()

    if EXPORTER_MODE == "zenoh-hub":
        lines.append("# HELP robot_zenoh_hub_port_listening Whether zenoh-hub TCP/WS port is listening (1=up, 0=down)")
        lines.append("# TYPE robot_zenoh_hub_port_listening gauge")
        all_up = 1
        for svc, port in ZENOH_HUB_PORTS:
            up = 1 if port in listening else 0
            if up == 0:
                all_up = 0
            lines.append(f'robot_zenoh_hub_port_listening{_fmt_labels({"service": svc, "port": str(port)})} {up}')

        lines.append("# HELP robot_zenoh_hub_active_connections Established TCP connections to zenoh-hub port")
        lines.append("# TYPE robot_zenoh_hub_active_connections gauge")
        for svc, port in ZENOH_HUB_PORTS:
            lines.append(
                f'robot_zenoh_hub_active_connections{_fmt_labels({"service": svc, "port": str(port)})} {established.get(port, 0)}'
            )

        lines.append("# HELP robot_zenoh_hub_up Overall zenoh-hub readiness (1=up, 0=degraded)")
        lines.append("# TYPE robot_zenoh_hub_up gauge")
        lines.append(f"robot_zenoh_hub_up{_fmt_labels()} {all_up}")
        return "\n".join(lines) + "\n"

    # Default mode: selkies user Pod exporter
    ok, raw_metrics, dur = _fetch_selkies_metrics()
    status_obj = _fetch_selkies_status()

    lbl = _fmt_labels()
    lines.extend([
        "# HELP robot_selkies_up Whether Selkies /api/metrics loopback scrape succeeded (1=up, 0=down)",
        "# TYPE robot_selkies_up gauge",
        f"robot_selkies_up{lbl} {1 if ok else 0}",
        "# HELP robot_selkies_scrape_duration_seconds Duration of Selkies loopback scrape in seconds",
        "# TYPE robot_selkies_scrape_duration_seconds gauge",
        f"robot_selkies_scrape_duration_seconds{lbl} {dur:.6f}",
    ])

    if isinstance(status_obj, dict):
        mode = str(status_obj.get("mode", "unknown"))
        dual = str(status_obj.get("dual_mode", status_obj.get("enable_dual_mode", "unknown"))).lower()
        lines.extend([
            "# HELP robot_selkies_mode_info Active Selkies streaming mode information",
            "# TYPE robot_selkies_mode_info gauge",
            f'robot_selkies_mode_info{_fmt_labels({"mode": mode, "dual_mode": dual})} 1',
        ])

    # Filtered Selkies native Prometheus metrics + parsed numeric WebRTC stats
    if ok and raw_metrics:
        kept, webrtc_gauges = _filter_selkies_exposition(raw_metrics)
        lines.extend(kept)
        if webrtc_gauges:
            help_map = {
                "selkies_webrtc_rtt_ms": "Client-reported WebRTC candidate-pair RTT in milliseconds",
                "selkies_webrtc_jitter_ms": "Client-reported WebRTC video jitter in milliseconds",
                "selkies_webrtc_packets_lost": "Client-reported WebRTC cumulative packets lost",
                "selkies_webrtc_packets_received": "Client-reported WebRTC cumulative packets received",
                "selkies_webrtc_frames_dropped": "Client-reported WebRTC cumulative video frames dropped",
                "selkies_webrtc_frames_decoded": "Client-reported WebRTC cumulative video frames decoded",
                "selkies_webrtc_bytes_received": "Client-reported WebRTC cumulative bytes received",
                "selkies_webrtc_client_fps": "Client-reported WebRTC video frames per second",
            }
            for mname, mval in webrtc_gauges.items():
                lines.append(f"# HELP {mname} {help_map.get(mname, mname)}")
                lines.append(f"# TYPE {mname} gauge")
                lines.append(f"{mname}{lbl} {mval}")

    # Core Pod service port liveness & active TCP sessions
    lines.append("# HELP robot_service_port_listening Whether core Robot-Infra service TCP port is listening (1=up, 0=down)")
    lines.append("# TYPE robot_service_port_listening gauge")
    for svc, port in SELKIES_PORTS:
        up = 1 if port in listening else 0
        lines.append(f'robot_service_port_listening{_fmt_labels({"service": svc, "port": str(port)})} {up}')

    lines.append("# HELP robot_active_tcp_connections Established TCP connections per core service port")
    lines.append("# TYPE robot_active_tcp_connections gauge")
    for svc, port in SELKIES_PORTS:
        lines.append(
            f'robot_active_tcp_connections{_fmt_labels({"service": svc, "port": str(port)})} {established.get(port, 0)}'
        )

    ros_bridge_active = 1 if (7447 in listening or outbound_zenoh > 0) else 0
    lines.extend([
        "# HELP robot_ros_bridge_active Whether cross-Pod ros-bridge (zenoh-bridge-ros2dds) is active (1=active, 0=idle)",
        "# TYPE robot_ros_bridge_active gauge",
        f"robot_ros_bridge_active{lbl} {ros_bridge_active}",
        "# HELP robot_ros_bridge_outbound_connections Active outbound TCP connections to remote Zenoh bridge ports (7447/7448)",
        "# TYPE robot_ros_bridge_outbound_connections gauge",
        f"robot_ros_bridge_outbound_connections{lbl} {outbound_zenoh}",
    ])

    # Shared memory (/dev/shm) usage
    shm = _statvfs_bytes(SHM_PATH)
    if shm is not None:
        used, total = shm
        ratio = (used / total) if total > 0 else 0.0
        lines.extend([
            "# HELP robot_shm_used_bytes Used bytes on /dev/shm",
            "# TYPE robot_shm_used_bytes gauge",
            f"robot_shm_used_bytes{lbl} {used}",
            "# HELP robot_shm_limit_bytes Total capacity in bytes on /dev/shm",
            "# TYPE robot_shm_limit_bytes gauge",
            f"robot_shm_limit_bytes{lbl} {total}",
            "# HELP robot_shm_usage_ratio Usage ratio (0..1) on /dev/shm",
            "# TYPE robot_shm_usage_ratio gauge",
            f"robot_shm_usage_ratio{lbl} {ratio:.6f}",
        ])

    # Personal home PVC & Podman storage PVC usage (read-only statvfs)
    home_st = _statvfs_bytes(HOME_STORAGE_PATH)
    if home_st is not None:
        h_used, h_total = home_st
        lines.extend([
            "# HELP robot_home_storage_used_bytes Used bytes on personal /home/ubuntu volume",
            "# TYPE robot_home_storage_used_bytes gauge",
            f"robot_home_storage_used_bytes{lbl} {h_used}",
            "# HELP robot_home_storage_total_bytes Total bytes on personal /home/ubuntu volume",
            "# TYPE robot_home_storage_total_bytes gauge",
            f"robot_home_storage_total_bytes{lbl} {h_total}",
        ])

    podman_st = _statvfs_bytes(PODMAN_STORAGE_PATH)
    if podman_st is not None:
        p_used, p_total = podman_st
        lines.extend([
            "# HELP robot_podman_storage_used_bytes Used bytes on Rootless Podman storage volume",
            "# TYPE robot_podman_storage_used_bytes gauge",
            f"robot_podman_storage_used_bytes{lbl} {p_used}",
            "# HELP robot_podman_storage_total_bytes Total bytes on Rootless Podman storage volume",
            "# TYPE robot_podman_storage_total_bytes gauge",
            f"robot_podman_storage_total_bytes{lbl} {p_total}",
        ])

    podman_cnt = _count_podman_containers(PODMAN_STORAGE_PATH)
    if podman_cnt is not None:
        lines.extend([
            "# HELP robot_podman_containers_total Registered Rootless Podman containers in storage",
            "# TYPE robot_podman_containers_total gauge",
            f"robot_podman_containers_total{lbl} {podman_cnt}",
        ])

    if ENABLE_LOCAL_HOST_METRICS:
        lines.extend(_collect_local_host_metrics())

    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        payload = build_metrics_payload().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        # Suppress noisy per-scrape access logs
        return


def main() -> None:
    server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), MetricsHandler)
    print(
        f"[robot-metrics-exporter] listening on {LISTEN_ADDR}:{LISTEN_PORT} "
        f"(mode={EXPORTER_MODE}, target={SELKIES_METRICS_URL}, local_host={ENABLE_LOCAL_HOST_METRICS})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
