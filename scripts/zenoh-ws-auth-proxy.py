#!/usr/bin/env python3
"""
zenoh-ws-auth-proxy.py — Robot-Infra v4 Authenticated WebSocket Bridge (:7448 -> :7447)

Secures individual user `/zenoh` Ingress endpoints (`wss://<user>.selkies.local/zenoh`)
with HTTP Basic Auth BEFORE upgrading WebSocket traffic to `websocat` -> `127.0.0.1:7447`,
reusing the Pod's existing `SELKIES_BASIC_AUTH_USER` + `SELKIES_BASIC_AUTH_PASSWORD`
(or dedicated `ROS_BRIDGE_AUTH_USER` / `ROS_BRIDGE_AUTH_PASSWORD`) with zero extra
Kubernetes htpasswd Secrets and zero Ingress-NGINX annotation dependencies.

Environment variables:
  ZENOH_WS_PORT          Public container port (default: 7448)
  ZENOH_INTERNAL_WS_PORT Internal loopback websocat port (default: 17448)
  ZENOH_TCP_PORT         Local zenoh-bridge-ros2dds TCP port (default: 7447)
  ZENOH_WS_AUTH_ENABLED  auto (default: enabled when SELKIES_ENABLE_BASIC_AUTH=true and
                         a password is set) | true | false
"""

import asyncio
import base64
import hmac
import os
import signal
import subprocess
import sys
from typing import List, Optional, Tuple

LISTEN_HOST = os.environ.get("ZENOH_WS_BIND", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("ZENOH_WS_PORT", "7448"))
INTERNAL_WS_PORT = int(os.environ.get("ZENOH_INTERNAL_WS_PORT", "17448"))
ZENOH_TCP_PORT = int(os.environ.get("ZENOH_TCP_PORT", "7447"))
MAX_HEADER_BYTES = 16384
HEADER_TIMEOUT_SEC = 5.0


def _read_secret_file(path: str) -> str:
    try:
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read().strip()
    except Exception:
        pass
    return ""


def _resolve_auth_config() -> Tuple[bool, List[str], str]:
    mode = os.environ.get("ZENOH_WS_AUTH_ENABLED", "auto").strip().lower()
    selkies_auth = os.environ.get("SELKIES_ENABLE_BASIC_AUTH", "true").strip().lower()

    pw = (
        os.environ.get("ROS_BRIDGE_AUTH_PASSWORD", "")
        or os.environ.get("SELKIES_BASIC_AUTH_PASSWORD", "")
        or _read_secret_file("/run/secrets/selkies-auth/WEB_PASSWORD")
        or os.environ.get("PASSWD", "")
        or _read_secret_file("/run/secrets/selkies-auth/LINUX_PASSWORD")
    )

    if mode in ("0", "false", "no", "off"):
        enabled = False
    elif mode in ("1", "true", "yes", "on"):
        enabled = bool(pw)
    else:
        enabled = (selkies_auth in ("1", "true", "yes", "on")) and bool(pw)

    users: List[str] = []
    for candidate in (
        os.environ.get("ROS_BRIDGE_AUTH_USER", "").strip(),
        os.environ.get("SELKIES_BASIC_AUTH_USER", "").strip(),
        "ubuntu",
    ):
        if candidate and candidate not in users:
            users.append(candidate)

    return enabled, users, pw


def _check_basic_auth(header_bytes: bytes, allowed_users: List[str], expected_pw: str) -> bool:
    try:
        text = header_bytes.decode("latin-1")
    except Exception:
        return False

    auth_val: Optional[str] = None
    for line in text.split("\r\n")[1:]:
        if not line:
            break
        if line.lower().startswith("authorization:"):
            auth_val = line.split(":", 1)[1].strip()
            break

    if not auth_val or not auth_val.lower().startswith("basic "):
        return False

    b64_part = auth_val[6:].strip()
    try:
        decoded = base64.b64decode(b64_part).decode("utf-8")
    except Exception:
        return False

    if ":" not in decoded:
        return False
    user, pw = decoded.split(":", 1)

    pw_ok = hmac.compare_digest(pw.encode("utf-8"), expected_pw.encode("utf-8"))
    user_ok = any(hmac.compare_digest(user.encode("utf-8"), u.encode("utf-8")) for u in allowed_users)
    return user_ok and pw_ok


async def _pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def _handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    auth_enabled: bool,
    allowed_users: List[str],
    expected_pw: str,
) -> None:
    buf = bytearray()
    try:
        while b"\r\n\r\n" not in buf:
            if len(buf) >= MAX_HEADER_BYTES:
                client_writer.close()
                return
            chunk = await asyncio.wait_for(client_reader.read(4096), timeout=HEADER_TIMEOUT_SEC)
            if not chunk:
                client_writer.close()
                return
            buf.extend(chunk)
    except Exception:
        try:
            client_writer.close()
        except Exception:
            pass
        return

    hdr_end = buf.find(b"\r\n\r\n") + 4
    header_block = bytes(buf[:hdr_end])
    first_line = header_block.split(b"\r\n", 1)[0]

    # Unauthenticated local health check
    if first_line.startswith(b"GET /healthz "):
        client_writer.write(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n"
        )
        await client_writer.drain()
        client_writer.close()
        return

    if auth_enabled and not _check_basic_auth(header_block, allowed_users, expected_pw):
        client_writer.write(
            b'HTTP/1.1 401 Unauthorized\r\n'
            b'WWW-Authenticate: Basic realm="Robot-Infra ROS2 Bridge"\r\n'
            b'Content-Type: text/plain; charset=utf-8\r\n'
            b'Content-Length: 13\r\n'
            b'Connection: close\r\n\r\n'
            b'Unauthorized\n'
        )
        await client_writer.drain()
        client_writer.close()
        return

    try:
        up_reader, up_writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", INTERNAL_WS_PORT), timeout=3.0
        )
    except Exception:
        client_writer.write(
            b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 12\r\nConnection: close\r\n\r\nBad Gateway\n"
        )
        await client_writer.drain()
        client_writer.close()
        return

    up_writer.write(bytes(buf))
    await up_writer.drain()

    await asyncio.gather(
        _pipe(client_reader, up_writer),
        _pipe(up_reader, client_writer),
    )


async def _main() -> int:
    auth_enabled, allowed_users, expected_pw = _resolve_auth_config()
    ws_proc = subprocess.Popen(
        [
            "/usr/local/bin/websocat",
            "--binary",
            "--exit-on-eof",
            f"ws-l:127.0.0.1:{INTERNAL_WS_PORT}",
            f"tcp:127.0.0.1:{ZENOH_TCP_PORT}",
        ]
    )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass

    server = await asyncio.start_server(
        lambda r, w: _handle_client(r, w, auth_enabled, allowed_users, expected_pw),
        host=LISTEN_HOST,
        port=LISTEN_PORT,
    )
    print(
        f"[zenoh-ws] listening on {LISTEN_HOST}:{LISTEN_PORT} -> 127.0.0.1:{INTERNAL_WS_PORT} -> 127.0.0.1:{ZENOH_TCP_PORT} "
        f"(basic_auth={'enabled' if auth_enabled else 'disabled'}, allowed_users={allowed_users})",
        flush=True,
    )

    async def _watch_child() -> None:
        while not stop_event.is_set():
            if ws_proc.poll() is not None:
                stop_event.set()
                break
            await asyncio.sleep(1.0)

    watcher = asyncio.create_task(_watch_child())
    await stop_event.wait()
    watcher.cancel()
    server.close()
    await server.wait_closed()

    if ws_proc.poll() is None:
        ws_proc.terminate()
        try:
            ws_proc.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            ws_proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(_main()))
