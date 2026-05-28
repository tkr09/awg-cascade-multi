"""
Главное меню + статус каскада (read-only).
"""
from __future__ import annotations

import logging

from aiogram import F, Router
from aiogram.filters import Command, CommandStart
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup, Message

from common import (admin_only, cfg, fmt_age, name_to_flag, ping_bar,
                    state_load, status_icon)

LOG = logging.getLogger("awg.main_menu")
router = Router(name="main_menu")


def main_kb(state: dict) -> InlineKeyboardMarkup:
    exits = state.get("exits", [])
    up = sum(1 for e in exits if e.get("status") == "up" and e.get("enabled"))
    total = len([e for e in exits if e.get("enabled")])

    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"🌍 Exits ({up}/{total} up)", callback_data="exits:list")],
        [InlineKeyboardButton(text="👤 Peers (клиенты)",          callback_data="peers:list")],
        [
            InlineKeyboardButton(text="📊 Полный статус", callback_data="status:full"),
            InlineKeyboardButton(text="🔄 Refresh",       callback_data="main"),
        ],
        [InlineKeyboardButton(text="➕ Добавить exit",  callback_data="exits:add")],
        [InlineKeyboardButton(text="➕ Добавить peer",  callback_data="peers:add")],
        [InlineKeyboardButton(text="⚙️ Настройки",      callback_data="settings:main")],
    ])


def render_main(state: dict) -> str:
    c = cfg()
    exits = state.get("exits", [])
    enabled = [e for e in exits if e.get("enabled")]
    up = [e for e in enabled if e.get("status") == "up"]
    down = [e for e in enabled if e.get("status") != "up"]
    ks = state.get("kill_switch_active", True)
    ks_icon = "🔒 ACTIVE (no exits)" if ks else "🔓 OK"

    avg_ping = None
    if up:
        pings = [e.get("ping_avg") for e in up if e.get("ping_avg") is not None]
        if pings:
            avg_ping = sum(pings) / len(pings)

    lines = [
        f"<b>🛡 AWG Cascade Multi</b>  <code>{c.ru_public_ip}</code>",
        f"",
        f"<b>Exits:</b> {len(up)}/{len(enabled)} up" + (f"  ·  avg ping <b>{avg_ping:.0f}ms</b>" if avg_ping else ""),
        f"<b>Kill-switch:</b> {ks_icon}",
        f"<b>Watchdog:</b> {state.get('last_update', '?')[11:19] if state.get('last_update') else '?'} UTC",
        f"",
    ]
    if up:
        lines.append("<b>Активные exits:</b>")
        for e in up:
            flag = name_to_flag(e.get("name", ""))
            p = e.get("ping_avg")
            w = e.get("weight", "?")
            lines.append(f"  {flag} <b>{e['name']}</b>  ping <code>{p:.0f}ms</code>  w<code>{w}</code>" if p else f"  {flag} {e['name']}")
    if down:
        lines.append("\n<b>Down:</b>")
        for e in down:
            flag = name_to_flag(e.get("name", ""))
            lines.append(f"  {flag} <b>{e['name']}</b>  🔴 down")
    if not enabled:
        lines.append("<i>Нет активных exits. Добавь через ➕ Добавить exit.</i>")
    return "\n".join(lines)


@router.message(CommandStart())
@admin_only
async def cmd_start(message: Message) -> None:
    state = state_load()
    await message.answer(render_main(state), parse_mode="HTML", reply_markup=main_kb(state))


@router.message(Command("status"))
@admin_only
async def cmd_status(message: Message) -> None:
    state = state_load()
    await message.answer(render_main(state), parse_mode="HTML", reply_markup=main_kb(state))


@router.callback_query(F.data == "main")
@admin_only
async def cb_main(call: CallbackQuery) -> None:
    await call.answer()
    state = state_load()
    await call.message.edit_text(render_main(state), parse_mode="HTML", reply_markup=main_kb(state))


@router.callback_query(F.data == "close")
@admin_only
async def cb_close(call: CallbackQuery) -> None:
    """Удалить сообщение (например, после показа QR/конфига)."""
    await call.answer()
    try:
        await call.message.delete()
    except Exception:
        pass


# ─── Full status ─────────────────────────────────────────────────────────────

@router.callback_query(F.data == "status:full")
@admin_only
async def cb_status_full(call: CallbackQuery) -> None:
    await call.answer()
    state = state_load()
    c = cfg()
    exits = state.get("exits", [])

    lines = [
        f"<b>📊 Полный статус</b>",
        f"",
        f"<b>RU:</b> <code>{c.ru_public_ip}</code>  port <code>{c.awg0_port}/udp</code>",
        f"<b>Client subnet:</b> <code>{c.client_net}</code>",
        f"<b>Kill-switch:</b> {'🔒' if state.get('kill_switch_active') else '🔓'}",
        f"",
    ]

    if not exits:
        lines.append("<i>Exits ещё не добавлены.</i>")
    else:
        for e in exits:
            icon = status_icon(e.get("status"))
            flag = name_to_flag(e.get("name", ""))
            enabled = "✓" if e.get("enabled") else "✗"
            name = e.get("name", "?")
            ip = e.get("ip", "?")
            port = e.get("port", "?")
            iface = e.get("interface", "?")
            ping = e.get("ping_avg")
            ploss = e.get("ping_loss", 0)
            hs = e.get("handshake_age")
            weight = e.get("weight", "?")
            ring = e.get("ping_ring", [])
            warp = e.get("warp_state", "off")
            warp_icon = {"on": "🔵", "off": "⚪"}.get(warp, "❓")
            note = e.get("note", "")

            lines.append(f"<b>{icon} {flag} {name}</b>  <code>{ip}:{port}</code>  enabled={enabled}")
            lines.append(f"  iface <code>{iface}</code>  weight <code>{weight}</code>  WARP {warp_icon}")
            if ping is not None:
                lines.append(f"  ping <code>{ping:.0f}ms</code>  loss <code>{ploss:.0f}%</code>  hs <code>{fmt_age(hs)}</code>")
                lines.append(f"  <code>{ping_bar(ring)}</code>")
            if note:
                lines.append(f"  📝 <i>{note}</i>")
            lines.append("")

    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="🔄 Refresh", callback_data="status:full"),
        InlineKeyboardButton(text="🏠 Меню",    callback_data="main"),
    ]])
    await call.message.edit_text("\n".join(lines), parse_mode="HTML", reply_markup=kb)
