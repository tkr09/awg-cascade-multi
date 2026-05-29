"""
Peers (клиенты awg0) — список, добавление, удаление, QR, статус, exit policy, note.
"""
from __future__ import annotations

import io
import json
import logging
import re
from pathlib import Path

import qrcode
from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import (BufferedInputFile, CallbackQuery,
                           InlineKeyboardButton, InlineKeyboardMarkup, Message)

from common import (PEERS_DIR, admin_only, awg_show_peers, cfg, fmt_age,
                    fmt_bytes, format_geo, geoip_lookup, html_escape,
                    name_to_flag, peer_update, peers_list, state_load,
                    sudo_run)

LOG = logging.getLogger("awg.peers")
router = Router(name="peers")


class AddPeerFSM(StatesGroup):
    waiting_name = State()


class PeerNoteFSM(StatesGroup):
    waiting_text = State()


_close_kb = InlineKeyboardMarkup(inline_keyboard=[[
    InlineKeyboardButton(text="❌ Закрыть", callback_data="close"),
]])


def _peer_conf_path(name: str) -> Path:
    return PEERS_DIR / f"{name}.conf"


def _make_qr_png(conf_text: str) -> bytes:
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, border=2, box_size=8)
    qr.add_data(conf_text)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def peers_kb(peers: list[dict]) -> InlineKeyboardMarkup:
    rows = []
    for p in peers:
        pinned = p.get("pinned_exit")
        suffix = f"  → {pinned}" if pinned else "  · 🔄 auto"
        rows.append([InlineKeyboardButton(
            text=f"👤 {p['name']}  {p['ip']}{suffix}",
            callback_data=f"peer:menu:{p['name']}"
        )])
    rows.append([
        InlineKeyboardButton(text="➕ Добавить",  callback_data="peers:add"),
        InlineKeyboardButton(text="🏠 Меню",      callback_data="main"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def peer_menu_kb(name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="🔄 Обновить",   callback_data=f"peer:menu:{name}"),
            InlineKeyboardButton(text="📱 QR",         callback_data=f"peer:qr:{name}"),
        ],
        [
            InlineKeyboardButton(text="📄 Конфиг",     callback_data=f"peer:conf:{name}"),
            InlineKeyboardButton(text="🎯 Exit",       callback_data=f"peer:pin:{name}"),
        ],
        [
            InlineKeyboardButton(text="📝 Заметка",    callback_data=f"peer:note:{name}"),
            InlineKeyboardButton(text="🔁 Rotate",     callback_data=f"peer:rotate:{name}"),
        ],
        [InlineKeyboardButton(text="🗑 Удалить",       callback_data=f"peer:rm:{name}")],
        [InlineKeyboardButton(text="◀️ К списку",     callback_data="peers:list")],
    ])


# ─── Render ──────────────────────────────────────────────────────────────────

async def render_peer_status(peer: dict, with_geo: bool = True) -> str:
    """Возвращает HTML-форматированный статус peer'а с live-данными."""
    name = peer["name"]
    ip = peer["ip"]
    pinned = peer.get("pinned_exit")
    note = peer.get("note", "")
    created = peer.get("created", "?")

    # live data
    awg = await awg_show_peers("awg0")
    live = awg.get(peer["pubkey"], {})
    hs = live.get("hs_age", 9999)
    endpoint = live.get("endpoint")
    rx = live.get("rx", 0)
    tx = live.get("tx", 0)

    active = hs is not None and hs < 180
    status_icon = "🟢" if active else "⚪"
    status_text = (
        f"Active  · last handshake <code>{fmt_age(hs)}</code> ago"
        if active else "Inactive"
    )

    external_ip = endpoint.rsplit(":", 1)[0] if endpoint else "—"
    external_port = endpoint.rsplit(":", 1)[1] if endpoint else ""

    if pinned:
        st = state_load()
        pinned_exit = next((e for e in st.get("exits", []) if e["interface"] == pinned), None)
        if pinned_exit:
            flag = name_to_flag(pinned_exit.get("name", ""))
            policy = f"🎯 {flag} <b>{pinned_exit['name']}</b> (pinned)"
        else:
            policy = f"🎯 <b>{pinned}</b> (pinned, exit missing!)"
    else:
        policy = "🔄 <b>Auto</b> (ECMP по всем exit'ам)"

    lines = [
        f"<b>👤 {name}</b>  <code>{ip}</code>",
        f"",
        f"{status_icon} {status_text}",
        f"📍 External: <code>{external_ip}{':' + external_port if external_port else ''}</code>",
        f"📊 Traffic:  ↓ <b>{fmt_bytes(rx)}</b>  ↑ <b>{fmt_bytes(tx)}</b>",
        f"🎯 Exit:     {policy}",
    ]

    # GeoIP (с таймаутом — может быть медленно)
    if with_geo and external_ip and external_ip != "—":
        try:
            geo = await geoip_lookup(external_ip)
            g = format_geo(geo)
            if g:
                lines.append(f"🌍 GeoIP:    <code>{g}</code>")
        except Exception:
            pass

    lines.append(f"")
    lines.append(f"Created: <code>{created}</code>")
    if note:
        lines.append(f"📝 <i>{html_escape(note)}</i>")

    return "\n".join(lines)


# ─── List ────────────────────────────────────────────────────────────────────

@router.callback_query(F.data == "peers:list")
@admin_only
async def cb_list(call: CallbackQuery) -> None:
    await call.answer()
    peers = peers_list()
    if not peers:
        text = "<b>👤 Peers</b>\n\n<i>Список пуст. Добавь первого peer'а.</i>"
    else:
        # Подмешиваем live status: считаем сколько active
        awg = await awg_show_peers("awg0")
        active = 0
        for p in peers:
            live = awg.get(p["pubkey"], {})
            if live.get("hs_age", 9999) < 180:
                active += 1
        text = f"<b>👤 Peers ({active}/{len(peers)} active)</b>\n\nВыбери peer'а:"
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=peers_kb(peers))


@router.callback_query(F.data.startswith("peer:menu:"))
@admin_only
async def cb_peer_menu(call: CallbackQuery) -> None:
    await call.answer()
    name = call.data[len("peer:menu:"):]
    peer = next((p for p in peers_list() if p["name"] == name), None)
    if not peer:
        await call.message.edit_text("Peer не найден.", reply_markup=peers_kb(peers_list()))
        return
    text = await render_peer_status(peer)
    try:
        await call.message.edit_text(text, parse_mode="HTML", reply_markup=peer_menu_kb(name))
    except Exception as e:
        # Если сообщение не изменилось — Telegram ругается. Игнорируем.
        if "message is not modified" not in str(e):
            raise


# ─── Show QR / config ────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("peer:qr:"))
@admin_only
async def cb_peer_qr(call: CallbackQuery) -> None:
    await call.answer("⏳ Готовлю QR…")
    name = call.data[len("peer:qr:"):]
    conf = _peer_conf_path(name)
    if not conf.exists():
        await call.message.answer(f"❌ Конфиг {name} не найден")
        return
    png = _make_qr_png(conf.read_text())
    await call.message.answer_photo(
        BufferedInputFile(png, filename=f"{name}.png"),
        caption=f"📱 QR для импорта в amnezia-client: <b>{name}</b>",
        parse_mode="HTML",
        reply_markup=_close_kb,
    )


@router.callback_query(F.data.startswith("peer:conf:"))
@admin_only
async def cb_peer_conf(call: CallbackQuery) -> None:
    await call.answer()
    name = call.data[len("peer:conf:"):]
    conf = _peer_conf_path(name)
    if not conf.exists():
        await call.message.answer(f"❌ Конфиг {name} не найден")
        return
    await call.message.answer(
        f"<b>{name}.conf:</b>\n<pre>{html_escape(conf.read_text())}</pre>",
        parse_mode="HTML",
        reply_markup=_close_kb,
    )


# ─── Exit policy (pin / auto) ────────────────────────────────────────────────

@router.callback_query(F.data.startswith("peer:pin:"))
@admin_only
async def cb_peer_pin(call: CallbackQuery) -> None:
    await call.answer()
    name = call.data[len("peer:pin:"):]
    peer = next((p for p in peers_list() if p["name"] == name), None)
    if not peer:
        return
    st = state_load()
    exits = [e for e in st.get("exits", []) if e.get("enabled")]
    cur = peer.get("pinned_exit") or "auto"

    rows = [[InlineKeyboardButton(
        text=("✅ " if cur == "auto" else "") + "🔄 Auto (ECMP)",
        callback_data=f"peer:setpin:{name}:auto",
    )]]
    for e in exits:
        flag = name_to_flag(e.get("name", ""))
        chosen = cur == e["interface"]
        rows.append([InlineKeyboardButton(
            text=("✅ " if chosen else "") + f"{flag} {e['name']}",
            callback_data=f"peer:setpin:{name}:{e['interface']}",
        )])
    rows.append([InlineKeyboardButton(text="◀️ Отмена", callback_data=f"peer:menu:{name}")])

    await call.message.edit_text(
        f"<b>🎯 Exit policy для {name}</b>\n\n"
        f"• <b>Auto</b> — трафик балансируется по всем живым exits (ECMP)\n"
        f"• <b>Конкретный exit</b> — трафик всегда через него; если exit упадёт — peer без интернета (kill-switch)\n\n"
        f"Текущая: <code>{cur}</code>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=rows),
    )


@router.callback_query(F.data.startswith("peer:setpin:"))
@admin_only
async def cb_peer_setpin(call: CallbackQuery) -> None:
    await call.answer("⏳")
    parts = call.data.split(":", 3)
    _, _, name, target = parts
    new_pin = None if target == "auto" else target
    p = peer_update(name, pinned_exit=new_pin)
    if not p:
        await call.message.edit_text("Peer не найден.")
        return
    # Триггерим watchdog чтобы применил новые правила
    await sudo_run("/usr/bin/systemctl", "kill", "-s", "SIGUSR1", "awg-cascade-watchdog", timeout=3)
    # Возвращаем меню peer'а
    text = await render_peer_status(p, with_geo=False)
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=peer_menu_kb(name))


# ─── Note ────────────────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("peer:note:"))
@admin_only
async def cb_peer_note(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    name = call.data[len("peer:note:"):]
    p = next((x for x in peers_list() if x["name"] == name), None)
    cur = p.get("note", "") if p else ""
    cur_text = f"<i>«{html_escape(cur)}»</i>" if cur else "<i>(пусто)</i>"

    await state.set_state(PeerNoteFSM.waiting_text)
    await state.update_data(name=name)
    await call.message.edit_text(
        f"📝 <b>Заметка для {name}</b>\n\n"
        f"Текущая: {cur_text}\n\n"
        f"Введи новый текст (или <code>-</code> чтобы очистить).",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data=f"peer:menu:{name}")
        ]]),
    )


@router.message(PeerNoteFSM.waiting_text)
@admin_only
async def fsm_peer_note(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    name = data["name"]
    text = (message.text or "").strip()
    if text == "-":
        text = ""
    text = text[:200]
    await state.clear()

    p = peer_update(name, note=text)
    if not p:
        await message.answer("Peer не найден")
        return
    status = await render_peer_status(p, with_geo=False)
    await message.answer(status, parse_mode="HTML", reply_markup=peer_menu_kb(name))


# ─── Add peer ────────────────────────────────────────────────────────────────

@router.callback_query(F.data == "peers:add")
@admin_only
async def cb_peer_add(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(AddPeerFSM.waiting_name)
    await call.message.edit_text(
        "<b>➕ Новый peer</b>\n\nВведи имя (a-z, 0-9, _, -; например <code>phone-2</code>, <code>laptop</code>):",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data="main")
        ]]),
    )


@router.message(AddPeerFSM.waiting_name)
@admin_only
async def fsm_peer_name(message: Message, state: FSMContext) -> None:
    name = (message.text or "").strip()
    name = re.sub(r"[^a-zA-Z0-9._-]", "", name)
    if not name:
        await message.answer("Имя пустое после очистки. Попробуй ещё раз.")
        return
    if any(p["name"] == name for p in peers_list()):
        await message.answer(f"Peer с именем <b>{name}</b> уже есть.", parse_mode="HTML")
        return

    await state.clear()
    await message.answer(f"⏳ Создаю peer <b>{name}</b>...", parse_mode="HTML")

    out, err, rc = await sudo_run("/usr/local/sbin/awg-cascade-peer-add.sh", name, timeout=15)
    if rc != 0:
        await message.answer(
            f"❌ Не удалось создать peer:\n<pre>{html_escape((err or out)[:500])}</pre>",
            parse_mode="HTML",
        )
        return

    try:
        result = json.loads(out)
    except json.JSONDecodeError:
        await message.answer(f"❌ Не-JSON ответ:\n<pre>{html_escape(out[:500])}</pre>", parse_mode="HTML")
        return

    if not result.get("ok"):
        await message.answer(f"❌ {result.get('error', 'unknown error')}")
        return

    client_conf = result["client_conf"]
    peer_ip = result["ip"]
    png = _make_qr_png(client_conf)

    await message.answer_photo(
        BufferedInputFile(png, filename=f"{name}.png"),
        caption=(
            f"✅ Peer <b>{name}</b>  IP <code>{peer_ip}</code>\n\n"
            f"📱 Сканируй QR в amnezia-client → Импорт"
        ),
        parse_mode="HTML",
        reply_markup=_close_kb,
    )
    await message.answer(
        f"<b>{name}.conf:</b>\n<pre>{html_escape(client_conf)}</pre>",
        parse_mode="HTML",
        reply_markup=_close_kb,
    )


# ─── Rotate peer keys ────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("peer:rotate:"))
@admin_only
async def cb_peer_rotate(call: CallbackQuery) -> None:
    await call.answer()
    name = call.data[len("peer:rotate:"):]
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=f"⚠️ Rotate {name}", callback_data=f"peer:rotate-yes:{name}"),
        InlineKeyboardButton(text="❌ Отмена",         callback_data=f"peer:menu:{name}"),
    ]])
    await call.message.edit_text(
        f"<b>🔁 Rotate keys: {name}</b>\n\n"
        f"Сейчас:\n"
        f"• Создадутся новые priv/pub ключи и PSK для этого peer'а\n"
        f"• Старая конфигурация на устройстве перестанет работать <b>немедленно</b>\n"
        f"• Бот выдаст новый QR — переимпортируй в amnezia-client\n"
        f"• Другие peer'ы не затрагиваются\n\n"
        f"Зачем: подозрение на утечку именно этого конфига (например, потерял телефон).",
        parse_mode="HTML", reply_markup=kb,
    )


@router.callback_query(F.data.startswith("peer:rotate-yes:"))
@admin_only
async def cb_peer_rotate_yes(call: CallbackQuery) -> None:
    await call.answer("⏳ Rotating…")
    name = call.data[len("peer:rotate-yes:"):]
    await call.message.edit_text(
        f"⏳ <b>Rotating {name}…</b>", parse_mode="HTML",
    )

    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-peer-rotate.sh", name, timeout=15,
    )
    if rc != 0:
        await call.message.answer(
            f"❌ Rotate failed:\n<pre>{html_escape((err or out)[:500])}</pre>",
            parse_mode="HTML",
        )
        return

    try:
        result = json.loads(out)
    except json.JSONDecodeError:
        await call.message.answer(f"❌ Не-JSON:\n<pre>{html_escape(out[:500])}</pre>", parse_mode="HTML")
        return

    if not result.get("ok"):
        await call.message.answer(f"❌ {result.get('error', 'unknown')}")
        return

    conf = result["conf"]
    png = _make_qr_png(conf)
    await call.message.answer_photo(
        BufferedInputFile(png, filename=f"{name}.png"),
        caption=f"✅ <b>{name}</b> rotated.\nПересканируй в amnezia-client.",
        parse_mode="HTML",
        reply_markup=_close_kb,
    )
    await call.message.answer(
        f"<b>{name}.conf:</b>\n<pre>{html_escape(conf)}</pre>",
        parse_mode="HTML",
        reply_markup=_close_kb,
    )


# ─── Remove peer ─────────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("peer:rm:"))
@admin_only
async def cb_peer_rm(call: CallbackQuery) -> None:
    await call.answer()
    name = call.data[len("peer:rm:"):]
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=f"🗑 Точно удалить", callback_data=f"peer:rm-yes:{name}"),
        InlineKeyboardButton(text="❌ Отмена",         callback_data=f"peer:menu:{name}"),
    ]])
    await call.message.edit_text(
        f"⚠️ Удалить peer <b>{name}</b>?\nКлиент потеряет доступ.",
        parse_mode="HTML", reply_markup=kb,
    )


@router.callback_query(F.data.startswith("peer:rm-yes:"))
@admin_only
async def cb_peer_rm_yes(call: CallbackQuery) -> None:
    await call.answer("⏳")
    name = call.data[len("peer:rm-yes:"):]
    out, err, rc = await sudo_run("/usr/local/sbin/awg-cascade-peer-remove.sh", name, timeout=10)
    if rc != 0:
        await call.message.edit_text(
            f"❌ Не удалось удалить:\n<pre>{html_escape((err or out)[:500])}</pre>",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
                InlineKeyboardButton(text="◀️ К списку", callback_data="peers:list")]]),
        )
        return
    await call.message.edit_text(
        f"🗑 Peer <b>{name}</b> удалён.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="👤 К списку", callback_data="peers:list"),
            InlineKeyboardButton(text="🏠 Меню",     callback_data="main"),
        ]]),
    )
