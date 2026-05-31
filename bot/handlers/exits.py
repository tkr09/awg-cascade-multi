"""
Exits — список, статус, добавление, удаление, WARP toggle, live ping, заметка.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from pathlib import Path

from aiogram import F, Router
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import (CallbackQuery, InlineKeyboardButton,
                           InlineKeyboardMarkup, Message)

from common import (admin_only, cfg, fmt_age, format_geo, geoip_lookup,
                    html_escape, name_to_flag, ping_bar, safe_edit_text,
                    ssh_copy_id, ssh_exec, state_load, state_save, status_icon,
                    sudo_run, SSH_KEY)

LOG = logging.getLogger("awg.exits")
router = Router(name="exits")


# ─── FSM ─────────────────────────────────────────────────────────────────────

class AddExitFSM(StatesGroup):
    waiting_name = State()
    waiting_ip = State()
    waiting_auth = State()
    waiting_password = State()
    waiting_pubkey_added = State()  # юзер сам добавил наш pubkey


class NoteFSM(StatesGroup):
    waiting_text = State()


# ─── List ────────────────────────────────────────────────────────────────────

def exits_kb(state: dict) -> InlineKeyboardMarkup:
    rows = []
    for e in state.get("exits", []):
        flag = name_to_flag(e.get("name", ""))
        icon = status_icon(e.get("status"))
        rows.append([InlineKeyboardButton(
            text=f"{icon} {flag} {e['name']}  ({e['ip']})",
            callback_data=f"exit:menu:{e['interface']}",
        )])
    rows.append([
        InlineKeyboardButton(text="➕ Добавить exit", callback_data="exits:add"),
        InlineKeyboardButton(text="🏠 Меню",          callback_data="main"),
    ])
    return InlineKeyboardMarkup(inline_keyboard=rows)


@router.callback_query(F.data == "exits:list")
@admin_only
async def cb_list(call: CallbackQuery) -> None:
    await call.answer()
    state = state_load()
    exits = state.get("exits", [])
    if not exits:
        text = "<b>🌍 Exits</b>\n\n<i>Список пуст. Добавь первый exit-сервер.</i>"
    else:
        text = f"<b>🌍 Exits ({len(exits)})</b>\n\nВыбери exit для управления:"
    await call.message.edit_text(text, parse_mode="HTML", reply_markup=exits_kb(state))


# ─── Exit menu ───────────────────────────────────────────────────────────────

def exit_menu_kb(iface: str, warp: str) -> InlineKeyboardMarkup:
    warp_icon = {"on": "🔵 ON", "off": "⚪ OFF"}.get(warp, "❓")
    warp_action = "warp_off" if warp == "on" else "warp_on"
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="📊 Статус",   callback_data=f"exit:status:{iface}"),
            InlineKeyboardButton(text="📡 Live Ping", callback_data=f"exit:ping:{iface}"),
        ],
        [InlineKeyboardButton(text=f"WARP: {warp_icon}", callback_data=f"exit:{warp_action}:{iface}")],
        [
            InlineKeyboardButton(text="📝 Заметка", callback_data=f"exit:note:{iface}"),
            InlineKeyboardButton(text="✏️ Имя",     callback_data=f"exit:rename:{iface}"),
        ],
        [InlineKeyboardButton(text="🔁 Rotate (anti-DPI)", callback_data=f"exit:rotate:{iface}")],
        [InlineKeyboardButton(text="🗑 Удалить exit", callback_data=f"exit:rm:{iface}")],
        [InlineKeyboardButton(text="◀️ К списку",    callback_data="exits:list")],
    ])




def _get_exit(state: dict, iface: str) -> dict | None:
    for e in state.get("exits", []):
        if e.get("interface") == iface:
            return e
    return None


def _render_exit_status(e: dict) -> str:
    flag = name_to_flag(e.get("name", ""))
    icon = status_icon(e.get("status"))
    ping = e.get("ping_avg")
    ploss = e.get("ping_loss", 0)
    hs = e.get("handshake_age")
    warp = e.get("warp_state", "off")
    warp_icon = {"on": "🔵 ON", "off": "⚪ OFF"}.get(warp, "❓")
    warp_exit_ip = e.get("warp_exit_ip")
    warp_geo = e.get("warp_exit_geo")
    warp_line = f"{warp_icon}"
    if warp == "on" and warp_exit_ip:
        warp_line += f"  exit <code>{warp_exit_ip}</code>"
        if warp_geo:
            warp_line += f"\n           🌍 <code>{html_escape(warp_geo)}</code>"
    ring = e.get("ping_ring", [])
    note = e.get("note", "")

    lines = [
        f"<b>{icon} {flag} {e['name']}</b>",
        f"",
        f"IP:       <code>{e['ip']}:{e['port']}</code>",
        f"iface:    <code>{e['interface']}</code>",
        f"tunnel:   <code>{e.get('ru_tunnel_ip', '?')} → {e.get('exit_tunnel_ip', '?')}</code>",
        f"weight:   <code>{e.get('weight', '?')}</code>",
        f"WARP:     {warp_line}",
        f"",
    ]
    if ping is not None:
        lines.append(f"ping:     <code>{ping:.0f} ms</code>  loss <code>{ploss:.0f}%</code>")
        lines.append(f"hs age:   <code>{fmt_age(hs)}</code>")
        lines.append(f"history:  <code>{ping_bar(ring)}</code>")
    else:
        lines.append(f"<i>Watchdog ещё не собрал статистику.</i>")

    if note:
        lines += ["", f"📝 <i>{note}</i>"]
    return "\n".join(lines)


@router.callback_query(F.data.startswith("exit:menu:"))
@admin_only
async def cb_exit_menu(call: CallbackQuery) -> None:
    await call.answer()
    iface = call.data[len("exit:menu:"):]
    state = state_load()
    e = _get_exit(state, iface)
    if not e:
        await call.message.edit_text("Exit не найден.", reply_markup=exits_kb(state))
        return
    await call.message.edit_text(
        _render_exit_status(e), parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


@router.callback_query(F.data.startswith("exit:status:"))
@admin_only
async def cb_exit_status(call: CallbackQuery) -> None:
    await call.answer("🔄")
    iface = call.data[len("exit:status:"):]
    state = state_load()
    e = _get_exit(state, iface)
    if not e:
        await call.message.edit_text("Exit не найден.", reply_markup=exits_kb(state))
        return
    await call.message.edit_text(
        _render_exit_status(e), parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


# ─── Live Ping ───────────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("exit:ping:"))
@admin_only
async def cb_exit_ping(call: CallbackQuery) -> None:
    await call.answer("📡 10 тиков…")
    iface = call.data[len("exit:ping:"):]
    e = _get_exit(state_load(), iface)
    if not e:
        return
    flag = name_to_flag(e.get("name", ""))
    msg = await call.message.edit_text(
        f"📡 <b>Live Ping {flag} {e['name']}</b>\n\n<i>Запускаю...</i>",
        parse_mode="HTML"
    )

    results = []
    for i in range(10):
        out, _, rc = await sudo_run(
            "/bin/ping", "-I", iface, "-c", "1", "-W", "2", "1.1.1.1", timeout=4
        )
        if rc == 0:
            m = re.search(r"time=([0-9.]+)", out)
            ms = float(m.group(1)) if m else -1
        else:
            ms = -1
        results.append(ms)

        # Обновляем сообщение
        ok_results = [r for r in results if r >= 0]
        avg = sum(ok_results) / len(ok_results) if ok_results else 0
        loss = sum(1 for r in results if r < 0) * 100 / len(results)
        bar = ping_bar(results)
        text = (
            f"📡 <b>Live Ping {flag} {e['name']}</b>\n\n"
            f"Tick {i+1}/10  "
            f"avg <b>{avg:.0f}ms</b>  loss <b>{loss:.0f}%</b>\n\n"
            f"<code>{bar}</code>"
        )
        try:
            await msg.edit_text(text, parse_mode="HTML")
        except Exception:
            pass
        await asyncio.sleep(0.8)

    # Финальный summary
    ok_results = [r for r in results if r >= 0]
    if ok_results:
        text = (
            f"📡 <b>Live Ping {flag} {e['name']}</b>  ✅ done\n\n"
            f"avg <b>{sum(ok_results)/len(ok_results):.0f}ms</b>  "
            f"min <code>{min(ok_results):.0f}</code>  max <code>{max(ok_results):.0f}</code>\n"
            f"loss <b>{(10-len(ok_results))*10}%</b>\n\n"
            f"<code>{ping_bar(results)}</code>"
        )
    else:
        text = f"📡 <b>{flag} {e['name']}</b>  ❌ все пинги потеряны"

    await msg.edit_text(text, parse_mode="HTML", reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")))


# ─── Note ────────────────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("exit:note:"))
@admin_only
async def cb_exit_note(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    iface = call.data[len("exit:note:"):]
    st = state_load()
    e = _get_exit(st, iface)
    cur_note = e.get("note", "") if e else ""
    cur_text = f"<i>«{cur_note}»</i>" if cur_note else "<i>(пусто)</i>"

    await state.set_state(NoteFSM.waiting_text)
    await state.update_data(iface=iface)
    await call.message.edit_text(
        f"📝 <b>Заметка для {e['name'] if e else iface}</b>\n\n"
        f"Текущая: {cur_text}\n\n"
        f"Введи новый текст (или <code>-</code> чтобы очистить).\n"
        f"Заметка видна в меню exit'а и в полном статусе.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data=f"exit:menu:{iface}")
        ]]),
    )


@router.message(NoteFSM.waiting_text)
@admin_only
async def fsm_note_text(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    iface = data["iface"]
    text = (message.text or "").strip()
    if text == "-":
        text = ""
    await state.clear()

    st = state_load()
    e = _get_exit(st, iface)
    if not e:
        await message.answer("Exit не найден")
        return
    e["note"] = text[:200]
    state_save(st)
    # Показываем меню с обновлённым статусом (там же видна новая заметка)
    await message.answer(
        _render_exit_status(e),
        parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


# ─── Rename ──────────────────────────────────────────────────────────────────

class RenameFSM(StatesGroup):
    waiting = State()


@router.callback_query(F.data.startswith("exit:rename:"))
@admin_only
async def cb_exit_rename(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    iface = call.data[len("exit:rename:"):]
    await state.set_state(RenameFSM.waiting)
    await state.update_data(iface=iface)
    await call.message.edit_text(
        "✏️ <b>Новое имя</b>\n\nФормат: <code>XX-N</code> где XX = код страны (NL, DE, PL, FI, RU...) и N = номер. Пример: <code>DE-2</code>.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data=f"exit:menu:{iface}")
        ]]),
    )


@router.message(RenameFSM.waiting)
@admin_only
async def fsm_rename(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    iface = data["iface"]
    new_name = (message.text or "").strip().upper()
    new_name = re.sub(r"[^A-Z0-9_-]", "", new_name)[:20]
    if not new_name:
        await message.answer("Пустое имя.")
        return
    await state.clear()

    st = state_load()
    e = _get_exit(st, iface)
    if not e:
        await message.answer("Exit не найден.")
        return
    e["name"] = new_name
    state_save(st)
    await message.answer(
        f"✅ Имя обновлено: <b>{new_name}</b>",
        parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


# ─── WARP toggle ─────────────────────────────────────────────────────────────

@router.callback_query(F.data.regexp(r"^exit:warp_(on|off):"))
@admin_only
async def cb_warp_toggle(call: CallbackQuery) -> None:
    parts = call.data.split(":")
    action = parts[1]  # warp_on / warp_off
    iface = parts[2]
    state = state_load()
    e = _get_exit(state, iface)
    if not e:
        await call.answer("Exit не найден", show_alert=True)
        return
    flag = name_to_flag(e.get("name", ""))
    await call.answer(f"⏳ WARP {action[5:]} …")
    await call.message.edit_text(
        f"⏳ {flag} <b>{e['name']}</b> — переключаю WARP → <b>{action[5:].upper()}</b>...",
        parse_mode="HTML",
    )

    # Вызываем helper-скрипт по SSH на exit. Timeout=120 — первая установка
    # качает wgcf и регистрирует WARP-аккаунт.
    # Передаём имя интерфейса НА EXIT'е (awg-in / awg-in-N) — helper метит
    # только этот iface, чтобы на shared-exit не задеть WARP другого RU.
    op = "on" if action == "warp_on" else "off"
    exit_iface = e.get("exit_iface", "awg-in")
    out, err, rc = await ssh_exec(
        e["ip"], f"sudo /usr/local/sbin/awg-cascade-exit-warp.sh {op} {exit_iface}",
        username="root", key_path=SSH_KEY, timeout=120,
    )

    new_warp = "unknown"
    exit_warp_ip = None
    if rc == 0:
        try:
            res = json.loads(out)
            new_warp = res.get("warp_state", "unknown")
            exit_warp_ip = res.get("exit_ip") or None
        except json.JSONDecodeError:
            new_warp = op if "OK" in out else "unknown"

    # Сохраняем в state. При WARP on делаем GeoIP-lookup на exit IP — кешируем.
    e["warp_state"] = new_warp
    if exit_warp_ip:
        e["warp_exit_ip"] = exit_warp_ip
        try:
            geo = await geoip_lookup(exit_warp_ip)
            e["warp_exit_geo"] = format_geo(geo) if geo else None
        except Exception:
            e["warp_exit_geo"] = None
    elif new_warp == "off":
        e.pop("warp_exit_ip", None)
        e.pop("warp_exit_geo", None)
    state_save(state)

    # UI update через safe_edit_text — retry 3x с backoff 1/2/4 сек.
    # Cascade моргает при WARP toggle (роуты на exit перестраиваются),
    # Telegram может дропнуть connection — retry'имся. State уже сохранён выше.
    if rc != 0:
        await safe_edit_text(
            call.message,
            f"❌ Не удалось переключить WARP:\n<pre>{html_escape((err or out)[:500])}</pre>",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    suffix = ""
    if exit_warp_ip:
        suffix = f"\n\n🌐 WARP exit IP: <code>{exit_warp_ip}</code>"
        if e.get("warp_exit_geo"):
            suffix += f"\n🌍 <code>{html_escape(e['warp_exit_geo'])}</code>"
    await safe_edit_text(
        call.message,
        f"{flag} <b>{e['name']}</b>: WARP → <b>{new_warp.upper()}</b>{suffix}",
        parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, new_warp),
    )


# ─── Rotate exit (anti-DPI) ──────────────────────────────────────────────────

@router.callback_query(F.data.startswith("exit:rotate:"))
@admin_only
async def cb_exit_rotate(call: CallbackQuery) -> None:
    await call.answer()
    iface = call.data[len("exit:rotate:"):]
    e = _get_exit(state_load(), iface)
    if not e:
        return
    flag = name_to_flag(e.get("name", ""))
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🎭 Обфускация (H1-H4)", callback_data=f"exit:rotate-go:{iface}:obfuscation")],
        [InlineKeyboardButton(text="🔑 Ключи (privkeys + PSK)", callback_data=f"exit:rotate-go:{iface}:keys")],
        [InlineKeyboardButton(text="⚡ Всё (обфускация + ключи)", callback_data=f"exit:rotate-go:{iface}:all")],
        [InlineKeyboardButton(text="❌ Отмена", callback_data=f"exit:menu:{iface}")],
    ])
    await call.message.edit_text(
        f"<b>🔁 Rotate exit: {flag} {e['name']}</b>  ({iface})\n\n"
        f"Главное оружие против ТСПУ: RU↔Exit-туннель имеет фиксированную DPI-сигнатуру "
        f"(H1-H4 + S1-S4). Если её утечка / mass-fingerprinting → детектят.\n\n"
        f"<b>🎭 Обфускация</b>: новые H1-H4. Ключи не меняются. Самое лёгкое — клиенты не пострадают.\n"
        f"<b>🔑 Ключи</b>: новые privkeys RU+Exit + PSK. Если ключи могли утечь.\n"
        f"<b>⚡ Всё</b>: и то и другое. Максимум.\n\n"
        f"Во всех режимах: ~5-10 сек downtime в самом туннеле. Клиенты которые сейчас "
        f"в этот exit (или Auto-ECMP) переключатся на другие exits на время — "
        f"watchdog подхватит. После rotate → handshake восстановится → exit опять в ECMP.",
        parse_mode="HTML", reply_markup=kb,
    )


@router.callback_query(F.data.startswith("exit:rotate-go:"))
@admin_only
async def cb_exit_rotate_go(call: CallbackQuery) -> None:
    await call.answer("⏳ Rotating…")
    parts = call.data.split(":", 3)
    _, _, iface, mode = parts
    e = _get_exit(state_load(), iface)
    if not e:
        return
    flag = name_to_flag(e.get("name", ""))

    await call.message.edit_text(
        f"⏳ {flag} <b>{e['name']}</b>: rotate <code>{mode}</code>…\n\n"
        f"Обновляю exit-сторону, потом RU-сторону, перезапускаю awg, жду handshake.",
        parse_mode="HTML",
    )

    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-exit-rotate.sh", iface, mode, timeout=45,
    )
    if rc != 0:
        await safe_edit_text(
            call.message,
            f"❌ Rotate failed:\n<pre>{html_escape((err or out)[:600])}</pre>",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    try:
        result = json.loads(out)
    except json.JSONDecodeError:
        await safe_edit_text(
            call.message,
            f"❌ Не-JSON ответ:\n<pre>{html_escape(out[:500])}</pre>",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    if not result.get("ok"):
        await safe_edit_text(
            call.message,
            f"❌ {result.get('error', 'unknown')}",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    hs_ok = result.get("handshake_ok", False)
    changes = ", ".join(result.get("changes", []))

    # Свежий state
    new_state = state_load()
    new_e = _get_exit(new_state, iface)
    status_text = await _render_status_after_rotate(new_e, mode, changes, hs_ok)

    await safe_edit_text(
        call.message,
        status_text, parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, new_e.get("warp_state", "off")),
    )


async def _render_status_after_rotate(e: dict, mode: str, changes: str, hs_ok: bool) -> str:
    flag = name_to_flag(e.get("name", ""))
    hs_icon = "✅" if hs_ok else "⏳"
    return (
        f"🔁 <b>{flag} {e['name']}: rotate done</b>\n\n"
        f"Mode: <code>{mode}</code>\n"
        f"Changed: <code>{changes}</code>\n"
        f"Handshake: {hs_icon} {'OK' if hs_ok else 'wait (может занять ~30s)'}\n\n"
        f"Watchdog сам подхватит новое состояние и обновит ECMP.\n"
        f"Текущее состояние в полном статусе ↓"
    )


# ─── Remove ──────────────────────────────────────────────────────────────────

@router.callback_query(F.data.startswith("exit:rm:"))
@admin_only
async def cb_exit_rm(call: CallbackQuery) -> None:
    await call.answer()
    iface = call.data[len("exit:rm:"):]
    state = state_load()
    e = _get_exit(state, iface)
    if not e:
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=f"🗑 Точно удалить {e['name']}", callback_data=f"exit:rm-yes:{iface}"),
        InlineKeyboardButton(text="❌ Отмена",                      callback_data=f"exit:menu:{iface}"),
    ]])
    await call.message.edit_text(
        f"⚠️ Удалить exit <b>{e['name']}</b> ({iface})?\n\n"
        f"• Туннель будет опущен\n"
        f"• Exit будет убран из ECMP\n"
        f"• На самой exit-ноде ключи остаются (можно переподключить позже)\n\n"
        f"Если останется 0 живых exits — kill-switch активируется (клиенты потеряют интернет).",
        parse_mode="HTML", reply_markup=kb,
    )


@router.callback_query(F.data.startswith("exit:rm-yes:"))
@admin_only
async def cb_exit_rm_yes(call: CallbackQuery) -> None:
    await call.answer("⏳")
    iface = call.data[len("exit:rm-yes:"):]
    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-exit-remove.sh", iface, timeout=20,
    )
    if rc != 0:
        await call.message.edit_text(
            f"❌ Ошибка удаления:\n<pre>{(err or out)[:400]}</pre>",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
                InlineKeyboardButton(text="◀️ К списку", callback_data="exits:list")]]),
        )
        return
    await call.message.edit_text(
        f"🗑 Exit <b>{iface}</b> удалён.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="🌍 К списку", callback_data="exits:list"),
            InlineKeyboardButton(text="🏠 Меню",     callback_data="main"),
        ]]),
    )


# ─── Add exit (FSM) ──────────────────────────────────────────────────────────

@router.callback_query(F.data == "exits:add")
@admin_only
async def cb_add(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(AddExitFSM.waiting_name)
    await call.message.edit_text(
        "<b>➕ Новый exit</b>\n\n"
        "Шаг 1/4: <b>Имя</b>\n"
        "Формат <code>XX-N</code> (XX = код страны, N = номер). "
        "Флаг подберётся автоматически.\n\n"
        "Примеры: <code>NL-2</code>, <code>DE-1</code>, <code>FI-1</code>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data="main")]]),
    )


@router.message(AddExitFSM.waiting_name)
@admin_only
async def fsm_name(message: Message, state: FSMContext) -> None:
    name = (message.text or "").strip().upper()
    name = re.sub(r"[^A-Z0-9_-]", "", name)[:20]
    if not name:
        await message.answer("Пустое имя.")
        return
    # Проверяем дубликаты
    st = state_load()
    if any(e["name"] == name for e in st.get("exits", [])):
        await message.answer(f"Exit с именем <b>{name}</b> уже есть.", parse_mode="HTML")
        return

    await state.update_data(name=name)
    await state.set_state(AddExitFSM.waiting_ip)
    await message.answer(
        f"✅ Имя: <b>{name}</b>\n\n"
        f"Шаг 2/4: <b>Публичный IP exit-сервера</b>",
        parse_mode="HTML",
    )


@router.message(AddExitFSM.waiting_ip)
@admin_only
async def fsm_ip(message: Message, state: FSMContext) -> None:
    ip = (message.text or "").strip()
    if not re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip):
        await message.answer("Невалидный IP-адрес. Формат: <code>1.2.3.4</code>", parse_mode="HTML")
        return
    await state.update_data(ip=ip)
    await state.set_state(AddExitFSM.waiting_auth)

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🔑 Пароль root",         callback_data="addexit:auth:password")],
        [InlineKeyboardButton(text="✅ Мой ключ уже добавлен", callback_data="addexit:auth:keyadded")],
        [InlineKeyboardButton(text="❌ Отмена",              callback_data="main")],
    ])
    await message.answer(
        f"✅ IP: <code>{ip}</code>\n\n"
        f"Шаг 3/4: <b>SSH-аутентификация</b>\n\n"
        f"• <b>Пароль root</b> — я залогинюсь и добавлю свой ключ\n"
        f"• <b>Ключ уже добавлен</b> — если ты уже положил мой публичный ключ в <code>~/.ssh/authorized_keys</code>",
        parse_mode="HTML",
        reply_markup=kb,
    )


@router.callback_query(F.data == "addexit:auth:password", AddExitFSM.waiting_auth)
@admin_only
async def cb_auth_pwd(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(AddExitFSM.waiting_password)
    await call.message.edit_text(
        "🔑 Введи пароль <b>root</b> для exit-сервера:",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data="main")]]),
    )


@router.callback_query(F.data == "addexit:auth:keyadded", AddExitFSM.waiting_auth)
@admin_only
async def cb_auth_keyadded(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await state.set_state(AddExitFSM.waiting_pubkey_added)
    pub = Path(str(SSH_KEY) + ".pub").read_text().strip()
    await call.message.edit_text(
        f"<b>Положи мой публичный ключ</b> на exit-сервере:\n\n"
        f"<pre>{pub}</pre>\n\n"
        f"Команда для exit'а:\n"
        f"<pre>echo '{pub}' >> ~/.ssh/authorized_keys</pre>\n\n"
        f"После этого нажми ▶️.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="▶️ Готово, продолжай", callback_data="addexit:proceed")],
            [InlineKeyboardButton(text="❌ Отмена",            callback_data="main")],
        ]),
    )


@router.message(AddExitFSM.waiting_password)
@admin_only
async def fsm_password(message: Message, state: FSMContext) -> None:
    password = (message.text or "")
    # Удаляем сообщение с паролем
    try:
        await message.delete()
    except Exception:
        pass
    await state.update_data(password=password)
    await _do_provision(message, state)


@router.callback_query(F.data == "addexit:proceed", AddExitFSM.waiting_pubkey_added)
@admin_only
async def cb_proceed(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    await _do_provision(call.message, state, edit_target=call.message)


async def _do_provision(message, state: FSMContext, edit_target=None) -> None:
    data = await state.get_data()
    name = data["name"]
    ip = data["ip"]
    password = data.get("password", "")
    await state.clear()

    flag = name_to_flag(name)
    status_header = f"⏳ {flag} <b>{name}</b> — провижу exit ({ip})...\n\n"

    # Persistent tracker сообщение: создаём один раз, потом edit_message_text по
    # message_id. Это надёжнее чем edit_text на разных Message объектах
    # (которые могут устареть/быть невалидны для edit).
    bot = message.bot
    chat_id = message.chat.id
    tracker = await bot.send_message(
        chat_id, status_header + "🔄 starting...", parse_mode="HTML",
    )
    tracker_msg_id = tracker.message_id

    last_text = None  # для подавления "message is not modified"

    async def update_status(extra: str) -> None:
        """Edit tracker message с retry-loop. State не зависит от UI — main flow продолжается."""
        nonlocal last_text
        from aiogram.exceptions import TelegramBadRequest, TelegramNetworkError
        text = status_header + extra
        if text == last_text:
            return  # без edit — Telegram отвергнет "not modified"
        last_text = text
        for attempt in range(3):
            try:
                await bot.edit_message_text(
                    text=text, chat_id=chat_id, message_id=tracker_msg_id,
                    parse_mode="HTML",
                )
                return
            except TelegramBadRequest as e:
                if "not modified" in str(e).lower():
                    return
                LOG.warning("update_status bad request: %s", e)
                return
            except TelegramNetworkError as e:
                if attempt < 2:
                    await asyncio.sleep((1, 2, 4)[attempt])
                else:
                    LOG.warning("update_status retries exhausted: %s", e)
            except Exception as e:
                LOG.warning("update_status unexpected: %s", e)
                return

    # 1. Если есть пароль — копируем pubkey
    if password:
        await update_status("1/6 Копирую свой ssh-ключ на exit...")
        pub = Path(str(SSH_KEY) + ".pub").read_text().strip()
        ok, err = await ssh_copy_id(ip, password, pub)
        if not ok:
            await update_status(f"❌ Не удалось залогиниться:\n<pre>{err[:300]}</pre>")
            return

    # 2. Определяем EXIT_INDEX (следующий свободный)
    st = state_load()
    used = {e["index"] for e in st.get("exits", [])}
    EXIT_INDEX = next(i for i in range(1, 256) if i not in used)

    # 3. Генерим RU-side ключи для awg<EXIT_INDEX>
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/awg", "genkey",
        stdout=asyncio.subprocess.PIPE,
    )
    out, _ = await proc.communicate()
    ru_privkey = out.decode().strip()

    proc = await asyncio.create_subprocess_shell(
        f"echo '{ru_privkey}' | /usr/bin/awg pubkey",
        stdout=asyncio.subprocess.PIPE,
    )
    out, _ = await proc.communicate()
    ru_pubkey = out.decode().strip()

    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/awg", "genpsk",
        stdout=asyncio.subprocess.PIPE,
    )
    out, _ = await proc.communicate()
    ru_psk = out.decode().strip()

    await update_status(
        f"1/6 ✓ SSH доступ есть\n"
        f"2/6 ✓ Индекс exit: <b>{EXIT_INDEX}</b>\n"
        f"3/6 ✓ Ключи RU-стороны сгенерены\n"
        f"4/6 Заливаю setup-exit.sh и провижу exit-side..."
    )

    # 4. Заливаем setup-exit.sh + awg2-params.sh + warp helper на exit и запускаем
    setup_path = Path("/opt/awg-cascade-bot/scripts/setup-exit.sh")
    awg2_params_path = Path("/opt/awg-cascade-bot/scripts/awg2-params.sh")
    warp_helper_path = Path("/opt/awg-cascade-bot/scripts/awg-cascade-exit-warp.sh")
    if not setup_path.exists():
        await update_status(f"❌ Не найден {setup_path}. Бот не может запровижить exit.")
        return
    if not awg2_params_path.exists():
        await update_status(f"❌ Не найден {awg2_params_path}. v2.0 generator отсутствует.")
        return

    # Копируем через scp через SSH (asyncssh умеет copy)
    import asyncssh as _asyncssh
    try:
        async with _asyncssh.connect(ip, username="root", client_keys=[str(SSH_KEY)],
                                      known_hosts=None, connect_timeout=15) as conn:
            await _asyncssh.scp(str(setup_path), (conn, "/root/setup-exit.sh"))
            await _asyncssh.scp(str(awg2_params_path), (conn, "/tmp/awg2-params.sh"))
            if warp_helper_path.exists():
                await _asyncssh.scp(str(warp_helper_path), (conn, "/tmp/awg-cascade-exit-warp.sh"))
            cmd = (
                f"chmod +x /root/setup-exit.sh && "
                f"BATCH=1 "
                f"EXIT_INDEX={EXIT_INDEX} "
                f"RU_PUBLIC_IP={cfg().ru_public_ip} "
                f"RU_PUBKEY='{ru_pubkey}' "
                f"RU_PSK='{ru_psk}' "
                f"bash /root/setup-exit.sh"
            )
            # 900 sec = 15 min. На fresh Ubuntu VPS первые 5-10 мин держится
            # apt-lock от unattended-upgrades (setup-exit.sh ждёт через
            # wait_apt_lock). Плюс компиляция amneziawg-dkms кушает ещё 2-3 мин.
            result = await asyncio.wait_for(conn.run(cmd, check=False), timeout=900)
            stdout_text = result.stdout if isinstance(result.stdout, str) else \
                          (result.stdout.decode() if result.stdout else "")
            stderr_text = result.stderr if isinstance(result.stderr, str) else \
                          (result.stderr.decode() if result.stderr else "")
            rc = result.exit_status or 0

            if rc != 0:
                await update_status(
                    f"❌ setup-exit.sh exit_code={rc}:\n<pre>"
                    f"{html_escape((stderr_text or stdout_text)[-500:])}</pre>"
                )
                return

            # 5. Парсим JSON из stdout setup-exit.sh. Все логи скрипт шлёт в
            #    stderr, на stdout — только итоговый JSON. В SHARED-режиме info
            #    пишется в per-interface файл (info-awg-in-N.json), которого нет
            #    по фиксированному пути info.json — поэтому cat фиксированного
            #    пути давал ЧУЖОЙ primary info (баг: awg<N> коннектился не туда).
            m = re.search(r"\{.*\}", stdout_text, re.DOTALL)
            if not m:
                await update_status(
                    f"❌ Не нашёл JSON в выводе setup-exit.sh:\n"
                    f"<pre>{html_escape(stdout_text[-400:])}</pre>"
                )
                return
            try:
                exit_info = json.loads(m.group(0))
            except json.JSONDecodeError as e:
                await update_status(
                    f"❌ info JSON невалиден: {e}\n<pre>{html_escape(m.group(0)[:400])}</pre>"
                )
                return
    except Exception as e:
        await update_status(f"❌ Ошибка SSH/scp: {html_escape(str(e))}")
        return

    await update_status(
        f"1/6 ✓ SSH\n"
        f"2/6 ✓ Index {EXIT_INDEX}\n"
        f"3/6 ✓ Keys\n"
        f"4/6 ✓ Exit provisioned\n"
        f"5/6 Поднимаю awg{EXIT_INDEX} на RU..."
    )

    # 6. Создаём awg<N>.conf на RU и поднимаем (через helper-скрипт)
    helper_args = json.dumps({
        "exit_index": EXIT_INDEX,
        "name": name,
        "ru_privkey": ru_privkey,
        "ru_pubkey": ru_pubkey,
        "ru_psk": ru_psk,
        "exit_info": exit_info,
    })
    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-exit-add-ru.sh", helper_args, timeout=30,
    )
    if rc != 0:
        await update_status(f"❌ RU-side setup failed:\n<pre>{(err or out)[:400]}</pre>")
        return

    flag2 = name_to_flag(name)
    await update_status(
        f"1/6 ✓ SSH\n"
        f"2/6 ✓ Index {EXIT_INDEX}\n"
        f"3/6 ✓ Keys\n"
        f"4/6 ✓ Exit provisioned\n"
        f"5/6 ✓ awg{EXIT_INDEX} up на RU\n"
        f"6/6 ✓ Добавлен в state.json\n\n"
        f"✅ {flag2} <b>{name}</b> готов!\n"
        f"Через ~5 сек watchdog подхватит и добавит в ECMP."
    )

    # Финальное отдельное сообщение со списком (не edit чтобы tracker остался виден)
    await asyncio.sleep(1)
    try:
        await bot.send_message(
            chat_id,
            f"✅ {flag2} <b>{name}</b> добавлен. К списку:",
            parse_mode="HTML",
            reply_markup=exits_kb(state_load()),
        )
    except Exception:
        pass
