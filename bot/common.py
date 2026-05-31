"""
Shared helpers — config loader, state IO, SSH helper, admin guard, format utils.
"""
from __future__ import annotations

import asyncio
import contextlib
import fcntl
import json
import logging
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path
from typing import Any, Awaitable, Callable

import asyncssh
from aiogram.types import CallbackQuery, Message

LOG = logging.getLogger("awg.common")

CONFIG_PATH = Path("/etc/awg-cascade/config")
STATE_PATH = Path("/etc/awg-cascade/state.json")
STATE_LOCK = Path("/etc/awg-cascade/state.lock")
PEERS_DIR = Path("/etc/awg-cascade/peers")
EXITS_DIR = Path("/etc/awg-cascade/exits")
SSH_KEY = Path("/etc/awg-cascade/ssh/id_ed25519")
WG_DIR = Path("/etc/amnezia/amneziawg")

# AmneziaWG Default preset
JC = 5; JMIN = 10; JMAX = 50
S1 = 68; S2 = 140; S3 = 14; S4 = 9
JUNK_I1 = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"


# ─── Config ──────────────────────────────────────────────────────────────────

@dataclass
class Config:
    ru_public_ip: str
    awg0_port: int
    client_net: str
    client_net_prefix: str
    server_ip: str
    main_iface: str
    tg_token: str
    tg_chat_id: int
    ntfy_url: str
    ntfy_topic: str
    bot_user: str

    @classmethod
    def load(cls) -> "Config":
        data: dict[str, str] = {}
        text = CONFIG_PATH.read_text()
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, _, v = line.partition("=")
                data[k.strip()] = v.strip().strip('"')
        return cls(
            ru_public_ip=data["RU_PUBLIC_IP"],
            awg0_port=int(data["AWG0_PORT"]),
            client_net=data["CLIENT_NET"],
            client_net_prefix=data["CLIENT_NET_PREFIX"],
            server_ip=data["SERVER_IP"],
            main_iface=data["MAIN_IFACE"],
            tg_token=data["TG_TOKEN"],
            tg_chat_id=int(data["TG_CHAT_ID"]),
            ntfy_url=data["NTFY_URL"],
            ntfy_topic=data["NTFY_TOPIC"],
            bot_user=data["BOT_USER"],
        )


# ─── State ───────────────────────────────────────────────────────────────────

def state_load() -> dict[str, Any]:
    try:
        with STATE_PATH.open() as f:
            return json.load(f)
    except FileNotFoundError:
        return {"schema": 1, "exits": [], "active_default_route": [],
                "kill_switch_active": True, "last_update": None}


def state_save(state: dict[str, Any]) -> None:
    """Atomic save with file lock."""
    state["last_update"] = datetime.now(timezone.utc).isoformat()
    tmp = STATE_PATH.with_suffix(".tmp")
    # Lock file: создаём с 666 если ещё нет (чтобы и watchdog от root и бот от awgbot могли)
    fd = os.open(str(STATE_LOCK), os.O_RDWR | os.O_CREAT, 0o666)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with tmp.open("w") as f:
            json.dump(state, f, indent=2, ensure_ascii=False)
        os.replace(tmp, STATE_PATH)
        os.chmod(STATE_PATH, 0o644)
    finally:
        os.close(fd)


def get_exit(state: dict[str, Any], identifier: str) -> dict[str, Any] | None:
    """identifier — это name или interface (awg1)."""
    for e in state.get("exits", []):
        if e.get("name") == identifier or e.get("interface") == identifier:
            return e
    return None


# ─── Peers (clients of awg0) ─────────────────────────────────────────────────

def peers_list() -> list[dict[str, Any]]:
    peers_json = Path("/etc/awg-cascade/peers.json")
    if not peers_json.exists():
        return []
    return json.loads(peers_json.read_text())


def peers_save(peers: list[dict[str, Any]]) -> None:
    peers_json = Path("/etc/awg-cascade/peers.json")
    tmp = peers_json.with_suffix(".tmp")
    fd = os.open(str(STATE_LOCK), os.O_RDWR | os.O_CREAT, 0o666)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with tmp.open("w") as f:
            json.dump(peers, f, indent=2, ensure_ascii=False)
        os.replace(tmp, peers_json)
        os.chmod(peers_json, 0o644)
    finally:
        os.close(fd)


def peer_update(name: str, **changes: Any) -> dict | None:
    """Update one peer fields atomically. Returns updated peer or None."""
    peers = peers_list()
    updated = None
    for p in peers:
        if p["name"] == name:
            p.update(changes)
            updated = p
            break
    if updated:
        peers_save(peers)
    return updated


def next_peer_ip(cfg: Config) -> str:
    """Найти следующий свободный IP в client_net (10.222.122.0/24)."""
    peers = peers_list()
    taken = {p["ip"] for p in peers}
    # .1 = server, .2..254 = clients
    for octet in range(2, 255):
        ip = f"{cfg.client_net_prefix}{octet}"
        if ip not in taken:
            return ip
    raise RuntimeError("Свободных IP не осталось в client_net")


# ─── SSH ─────────────────────────────────────────────────────────────────────

async def ssh_exec(
    host: str, command: str, *, username: str = "root",
    password: str | None = None, key_path: Path | None = SSH_KEY,
    port: int = 22, timeout: float = 60,
) -> tuple[str, str, int]:
    """
    Запускает команду по SSH. Возвращает (stdout, stderr, exit_code).
    Если password задан — авторизация по паролю. Иначе — по key_path.
    """
    opts: dict[str, Any] = {
        "username": username, "port": port, "known_hosts": None,
        "connect_timeout": 15,
    }
    if password:
        opts["password"] = password
    if key_path and key_path.exists() and not password:
        opts["client_keys"] = [str(key_path)]

    try:
        async with asyncssh.connect(host, **opts) as conn:
            result = await asyncio.wait_for(conn.run(command, check=False), timeout=timeout)
            return (
                result.stdout if isinstance(result.stdout, str) else (result.stdout.decode() if result.stdout else ""),
                result.stderr if isinstance(result.stderr, str) else (result.stderr.decode() if result.stderr else ""),
                result.exit_status or 0,
            )
    except asyncio.TimeoutError:
        return "", f"SSH timeout after {timeout}s", -2
    except (asyncssh.PermissionDenied, asyncssh.HostKeyNotVerifiable) as e:
        return "", f"SSH auth error: {e}", -3
    except (OSError, asyncssh.Error) as e:
        return "", f"SSH error: {e}", -1


async def ssh_copy_id(host: str, password: str, pubkey: str, *, port: int = 22) -> tuple[bool, str]:
    """Добавляет наш публичный ключ в ~/.ssh/authorized_keys на удалённом хосте."""
    pub_escaped = pubkey.replace('"', '\\"')
    cmd = (
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
        f'grep -qxF "{pub_escaped}" ~/.ssh/authorized_keys 2>/dev/null || '
        f'echo "{pub_escaped}" >> ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys && echo OK'
    )
    out, err, rc = await ssh_exec(host, cmd, password=password, port=port, timeout=20)
    return rc == 0 and "OK" in out, (err or out)


# ─── Local helpers (для команд на самом RU) ──────────────────────────────────

async def local_run(*args: str, timeout: float = 30) -> tuple[str, str, int]:
    """Запуск локальной команды. Бот работает под awgbot, sudo для нужных команд."""
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return out.decode(errors="replace"), err.decode(errors="replace"), proc.returncode or 0
    except asyncio.TimeoutError:
        proc.kill()
        return "", f"Timeout after {timeout}s", -1


async def sudo_run(*args: str, timeout: float = 30) -> tuple[str, str, int]:
    return await local_run("sudo", *args, timeout=timeout)


# ─── Geo IP ──────────────────────────────────────────────────────────────────

async def geoip_lookup(ip: str) -> dict[str, str] | None:
    """ip-api.com free GeoIP lookup. Force IPv4 (наш cascade тут только IPv4)."""
    out, err, rc = await local_run(
        "curl", "-4", "-fsS", "--max-time", "6",
        f"http://ip-api.com/json/{ip}?fields=status,country,countryCode,city,isp,query",
        timeout=10,
    )
    if rc != 0 or not out:
        LOG.warning("geoip_lookup(%s) failed rc=%s err=%s", ip, rc, err[:100] if err else "")
        return None
    try:
        data = json.loads(out)
        if data.get("status") == "success":
            return data
        LOG.warning("geoip_lookup(%s) status=%s", ip, data.get("status"))
        return None
    except (json.JSONDecodeError, ValueError) as e:
        LOG.warning("geoip_lookup(%s) parse error: %s | out=%r", ip, e, out[:200])
        return None


def format_geo(geo: dict[str, str] | None) -> str:
    if not geo:
        return ""
    return f"{geo.get('country', '?')}, {geo.get('city', '?')} | {geo.get('isp', '?')}"


# ─── Flags ───────────────────────────────────────────────────────────────────

_CC_TO_FLAG = {
    "RU": "🇷🇺", "NL": "🇳🇱", "DE": "🇩🇪", "PL": "🇵🇱", "FI": "🇫🇮",
    "FR": "🇫🇷", "GB": "🇬🇧", "US": "🇺🇸", "CA": "🇨🇦", "JP": "🇯🇵",
    "SE": "🇸🇪", "NO": "🇳🇴", "CH": "🇨🇭", "AT": "🇦🇹", "IT": "🇮🇹",
    "ES": "🇪🇸", "PT": "🇵🇹", "TR": "🇹🇷", "UA": "🇺🇦", "KZ": "🇰🇿",
}

def name_to_flag(name: str) -> str:
    """Из имени вида 'NL-1', 'DE-3', 'PL' извлекает флаг по двухбуквенному коду."""
    m = re.match(r"^([A-Z]{2})[-_].*", name) or re.match(r"^([A-Z]{2})$", name)
    if not m:
        return "🌍"
    return _CC_TO_FLAG.get(m.group(1), "🌍")


# ─── Admin guard ─────────────────────────────────────────────────────────────

_CFG_CACHE: Config | None = None

def cfg() -> Config:
    global _CFG_CACHE
    if _CFG_CACHE is None:
        _CFG_CACHE = Config.load()
    return _CFG_CACHE


def admin_only(handler: Callable[..., Awaitable[Any]]) -> Callable[..., Awaitable[Any]]:
    @wraps(handler)
    async def wrapper(event: Message | CallbackQuery, *args, **kwargs):
        c = cfg()
        uid = event.from_user.id if event.from_user else 0
        if uid != c.tg_chat_id:
            LOG.warning("Rejected non-admin uid=%s", uid)
            if isinstance(event, CallbackQuery):
                await event.answer("⛔ Только для админа", show_alert=True)
            elif isinstance(event, Message):
                await event.answer("⛔ Доступ запрещён")
            return
        return await handler(event, *args, **kwargs)
    return wrapper


# ─── Format helpers ──────────────────────────────────────────────────────────

def fmt_bytes(n: int | float | None) -> str:
    if n is None: return "?"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def fmt_age(sec: int | float | None) -> str:
    if sec is None or sec < 0: return "?"
    sec = int(sec)
    if sec < 60: return f"{sec}s"
    if sec < 3600: return f"{sec // 60}m {sec % 60}s"
    return f"{sec // 3600}h {(sec % 3600) // 60}m"


def status_icon(status: str | None) -> str:
    return {"up": "🟢", "down": "🔴", "disabled": "⚪"}.get(status or "", "❓")


async def awg_show_peers(iface: str = "awg0") -> dict[str, dict]:
    """Возвращает {pubkey: {endpoint, hs_age, rx, tx, allowed_ips}} для каждого peer'а."""
    import time as _time
    out, _, rc = await sudo_run("/usr/bin/awg", "show", iface, "dump", timeout=5)
    if rc != 0:
        return {}
    result: dict[str, dict] = {}
    now = int(_time.time())
    lines = out.strip().split("\n")
    # Первая строка = interface (без peer info). Peers начинаются со второй.
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        pubkey, _psk, endpoint, allowed_ips, hs_ts, rx, tx, _keepalive = parts[:8]
        try:
            hs_age = now - int(hs_ts) if hs_ts != "0" else 9999
        except ValueError:
            hs_age = 9999
        result[pubkey] = {
            "endpoint": endpoint if endpoint and endpoint != "(none)" else None,
            "hs_age": hs_age,
            "rx": int(rx) if rx.isdigit() else 0,
            "tx": int(tx) if tx.isdigit() else 0,
            "allowed_ips": allowed_ips,
        }
    return result


async def safe_edit_text(message, text: str, *, retries: int = 3,
                         backoffs: tuple[float, ...] = (1.0, 2.0, 4.0),
                         **edit_kwargs) -> bool:
    """
    Edit message с retry-loop для устойчивости к Telegram timeouts.

    Telegram API через cascade может временно дропнуть connection (особенно
    во время WARP toggle / rotate когда роутинг моргает). Простой edit_text
    кидает TelegramNetworkError → handler крашится, UI зависает.

    Эта обёртка:
    - Подавляет "message is not modified" (это не ошибка)
    - Retry'ит TelegramNetworkError с exp backoff
    - Возвращает True если успешно, False если все попытки исчерпаны
    """
    from aiogram.exceptions import TelegramBadRequest, TelegramNetworkError
    last_exc: Exception | None = None
    for attempt in range(retries):
        try:
            await message.edit_text(text, **edit_kwargs)
            return True
        except TelegramBadRequest as e:
            if "message is not modified" in str(e).lower():
                return True
            LOG.warning("safe_edit_text bad request: %s", e)
            return False
        except TelegramNetworkError as e:
            last_exc = e
            if attempt < retries - 1:
                pause = backoffs[min(attempt, len(backoffs) - 1)]
                LOG.warning("safe_edit_text network error #%d (%s) — retry in %.0fs",
                           attempt + 1, str(e)[:80], pause)
                await asyncio.sleep(pause)
        except Exception as e:
            LOG.warning("safe_edit_text unexpected: %s", e)
            return False
    LOG.warning("safe_edit_text exhausted %d retries: %s",
                retries, str(last_exc)[:80] if last_exc else "")
    return False


def html_escape(text: str) -> str:
    """Escape для Telegram HTML — иначе <b 0x...> ломает парсер."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def ping_bar(ring: list[int | float], width: int = 20) -> str:
    """ASCII bar visualizing ping ring."""
    if not ring:
        return "—"
    values = [v for v in ring if v >= 0]
    if not values:
        return "💀 все потеряны"
    mx = max(values) or 1
    bars = "▁▂▃▄▅▆▇█"
    out = []
    for v in ring[-width:]:
        if v < 0:
            out.append("✗")
        else:
            idx = min(len(bars) - 1, int(v / mx * (len(bars) - 1)))
            out.append(bars[idx])
    return "".join(out)
