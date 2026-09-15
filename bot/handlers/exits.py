"""
Exits — список, статус, добавление, удаление, WARP toggle, live ping, заметка.
"""
from __future__ import annotations

import asyncio
import contextlib
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

from common import (KNOWN_HOSTS_PATH, admin_only, cfg, fmt_age, format_geo,
                    geoip_lookup, host_key_forget, host_key_known,
                    _host_key_remember, html_escape, local_run, name_to_flag,
                    peers_list, ping_bar, safe_edit_text, ssh_copy_id, ssh_exec,
                    state_load, state_locked, status_icon, sudo_run, SSH_KEY)

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
        [InlineKeyboardButton(text="🔑 Ключ другой RU", callback_data=f"exit:authkey:{iface}")],
        [InlineKeyboardButton(text="🔄 Reboot exit",  callback_data=f"exit:reboot:{iface}")],
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
        lines += ["", f"📝 <i>{html_escape(note)}</i>"]
    return "\n".join(lines)


@router.callback_query(F.data.startswith("exit:menu:"))
@admin_only
async def cb_exit_menu(call: CallbackQuery, state: FSMContext) -> None:
    # Сюда ведут кнопки «Отмена» диалогов note/rename/веса — завершаем FSM,
    # иначе следующее сообщение уедет в брошенный диалог (см. cb_main).
    await call.answer()
    await state.clear()
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
        # БЕЗ sudo: ping несёт cap_net_raw=ep, поэтому -I <iface> работает и от
        # awgbot. Раньше тут был `sudo /bin/ping`, и это отвалилось разом на всех
        # нодах: правила на ping в каноничном sudoers (setup.sh/sync.sh) нет —
        # оно жило дописанным ВРУЧНУЮ на ноде, а sync.sh приводит
        # /etc/sudoers.d/<bot> к канону и стирает всё лишнее.
        # Отсюда правило: всё, что боту нужно под sudo, должно быть в каноне,
        # иначе не переживёт синк. Здесь sudo просто не нужен — так надёжнее.
        out, _, rc = await local_run(
            "ping", "-I", iface, "-c", "1", "-W", "2", "1.1.1.1", timeout=4
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
    cur_text = f"<i>«{html_escape(cur_note)}»</i>" if cur_note else "<i>(пусто)</i>"

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

    async with state_locked() as st:
        e = _get_exit(st, iface)
        if e:
            e["note"] = text[:200]
    if not e:
        await message.answer("Exit не найден")
        return
    # Показываем меню с обновлённым статусом (там же видна новая заметка)
    await message.answer(
        _render_exit_status(e),
        parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


# ─── Rename ──────────────────────────────────────────────────────────────────

class AuthKeyFSM(StatesGroup):
    waiting = State()


@router.callback_query(F.data.startswith("exit:authkey:"))
@admin_only
async def cb_exit_authkey(call: CallbackQuery, state: FSMContext) -> None:
    await call.answer()
    iface = call.data[len("exit:authkey:"):]
    st = state_load()
    e = _get_exit(st, iface)
    if not e:
        await call.message.edit_text("Exit не найден.")
        return
    await state.set_state(AuthKeyFSM.waiting)
    await state.update_data(iface=iface)
    await call.message.edit_text(
        f"🔑 <b>Ключ другой RU → {html_escape(e['name'])}</b>\n\n"
        "Этот exit закрыт для входа по паролю, поэтому новая RU сама на него "
        "зайти не может — ключ должна положить RU, для которой exit уже свой.\n\n"
        "Пришли <b>публичный</b> ключ новой RU одной строкой. Взять его там так:\n"
        "<pre>cat /etc/awg-cascade/ssh/id_ed25519.pub</pre>\n"
        "Строка с опциями (<code>command=</code>, <code>from=</code>) принята не будет.",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="❌ Отмена", callback_data=f"exit:menu:{iface}")
        ]]),
    )


@router.message(AuthKeyFSM.waiting)
@admin_only
async def fsm_authkey(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    iface = data["iface"]
    key = (message.text or "").strip()
    if not key:
        await message.answer("Пустое сообщение — жду публичный ключ.")
        return
    await state.clear()

    st = state_load()
    e = _get_exit(st, iface)
    if not e:
        await message.answer("Exit не найден.")
        return

    status = await message.answer("⏳ Кладу ключ на exit...")
    # Ключ уходит через stdin: в argv он был бы виден в ps всем на ноде.
    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-exit-authkey.sh", iface,
        timeout=60, stdin_data=key + "\n",
    )
    if rc != 0:
        reason = ""
        try:
            reason = json.loads(err.strip().splitlines()[-1]).get("error", "")
        except Exception:
            reason = (err or out)[:300]
        await status.edit_text(
            "❌ Ключ не добавлен.\n<pre>" + html_escape(reason) + "</pre>",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    result = json.loads(out)
    head = "✅ Ключ добавлен" if result.get("added") else "✅ Ключ уже был на месте"
    await status.edit_text(
        f"{head} — <b>{html_escape(result['exit'])}</b>\n\n"
        f"отпечаток: <code>{html_escape(result['fingerprint'])}</code>\n"
        f"ключей у root на exit'е: {result.get('keys_total', '?')}\n\n"
        "Теперь с той RU можно подключить этот exit:\n"
        f"<pre>awg-cascade-bootstrap-exit.sh {html_escape(result['ip'])} "
        f"{html_escape(result['exit'])}</pre>",
        parse_mode="HTML",
        reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
    )


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

    async with state_locked() as st:
        e = _get_exit(st, iface)
        if e:
            e["name"] = new_name
    if not e:
        await message.answer("Exit не найден.")
        return
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

    # GeoIP по exit IP — ДО взятия блокировки: это сетевой запрос, а под
    # STATE_LOCK ждёт watchdog.
    warp_geo = None
    if exit_warp_ip:
        try:
            geo = await geoip_lookup(exit_warp_ip)
            warp_geo = format_geo(geo) if geo else None
        except Exception:
            warp_geo = None

    # Между чтением state выше и этим местом прошёл SSH (до 120 с) и GeoIP.
    # Раньше здесь писался объект, прочитанный ДО них, и всё, что watchdog
    # успел записать за это время (ping_ring, status, weight), пропадало.
    # Теперь перечитываем под блокировкой и правим только свои поля.
    def _apply(exit_obj: dict) -> None:
        exit_obj["warp_state"] = new_warp
        if exit_warp_ip:
            exit_obj["warp_exit_ip"] = exit_warp_ip
            exit_obj["warp_exit_geo"] = warp_geo
        elif new_warp == "off":
            exit_obj.pop("warp_exit_ip", None)
            exit_obj.pop("warp_exit_geo", None)

    async with state_locked() as fresh:
        fresh_e = _get_exit(fresh, iface)
        if fresh_e is not None:
            _apply(fresh_e)
    _apply(e)   # локальная копия — только для отрисовки ответа ниже

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


# ─── Reboot exit ─────────────────────────────────────────────────────────────

REBOOT_GUARD = "python3 -I /usr/local/sbin/awg-cascade-reboot.py"


@router.callback_query(F.data.startswith("exit:reboot:"))
@admin_only
async def cb_exit_reboot(call: CallbackQuery) -> None:
    await call.answer("🔍 Опрашиваю exit…")
    iface = call.data[len("exit:reboot:"):]
    e = _get_exit(state_load(), iface)
    if not e:
        return
    flag = name_to_flag(e.get("name", ""))

    # Готовность ядра проверяет ОБЩИЙ guard на самом exit'е, а не самодельный
    # подсчёт строк здесь.
    #
    # Раньше экран считал совпадения версии ядра во всём выводе `dkms status`.
    # Совпасть могла строка другого модуля или состояние built — и владелец
    # видел «всё готово» там, где модуля для целевого ядра нет. После загрузки
    # туннель бы не поднялся (A05 аудита v2.7.6).
    #
    # awg-cascade-reboot.py проверяет фактическую первую запись grub.cfg, статус
    # installed именно для amneziawg и наличие файла модуля под это ядро, а при
    # нестандартном GRUB_DEFAULT или одноразовом next_entry отказывается вовсе.
    probe = (
        "echo \"up=$(uptime -p | sed 's/^up //')\"; "
        "echo \"run=$(uname -r)\"; "
        "echo \"pending=$([ -f /var/run/reboot-required ] && echo yes || echo no)\"; "
        "echo \"tunnels=$(ls -1 /etc/amnezia/amneziawg/awg-in*.conf 2>/dev/null | wc -l)\"; "
        "g=$(" + REBOOT_GUARD + " 2>&1); rc=$?; "
        "echo \"guard_rc=$rc\"; echo \"guard=$(echo \"$g\" | tr '\\n' ' ')\""
    )
    out, _, rc = await ssh_exec(e["ip"], probe, username="root", key_path=SSH_KEY, timeout=30)
    info = dict(
        l.split("=", 1) for l in out.strip().splitlines() if "=" in l
    ) if rc == 0 else {}

    approved = False
    if not info:
        body = "⚠️ <i>Не удалось опросить exit по SSH — состояние неизвестно.</i>"
        guard_line = ""
    else:
        pend = "🔴 да" if info.get("pending") == "yes" else "✅ нет"
        body = (
            f"Ядро сейчас: <code>{html_escape(info.get('run', '?'))}</code>\n"
            f"Uptime:      <code>{html_escape(info.get('up', '?'))}</code>\n"
            f"Ждёт ребута: {pend}"
        )
        approved = info.get("guard_rc") == "0"
        if approved:
            try:
                target = json.loads(info.get("guard", "{}")).get("boot_kernel", "?")
            except Exception:
                target = "?"
            guard_line = ("\n\n✅ <b>Проверено:</b> загрузится "
                          f"<code>{html_escape(str(target))}</code>, "
                          "модуль amneziawg для него установлен.")
        else:
            guard_line = ("\n\n🔴 <b>Проверка готовности НЕ пройдена:</b>\n"
                          f"<pre>{html_escape(info.get('guard', 'нет ответа')[:300])}</pre>"
                          "После такой перезагрузки туннель может не подняться.")

    # Shared exit: на сервере живёт туннель ещё одной RU, и её клиентов мы
    # уроним заодно. Владелец этой RU про них ничего не знает.
    others = max(0, int(info.get("tunnels", "1") or 1) - 1) if info else 0
    shared_line = (
        f"\n\n⚠️ <b>Exit общий:</b> на нём ещё {others} туннель(я) другой RU — "
        "перезагрузка оборвёт и их."
    ) if others else ""

    pinned = [p["name"] for p in peers_list() if p.get("pinned_exit") == iface]
    pinned_line = (
        f"\n\n📌 Потеряют интернет на время ребута (pinned): "
        f"<b>{html_escape(', '.join(pinned))}</b>"
    ) if pinned else ""

    if approved:
        action = InlineKeyboardButton(text="🔄 Перезагрузить",
                                      callback_data=f"exit:reboot-yes:{iface}")
    else:
        action = InlineKeyboardButton(text="⚠️ Перезагрузить без проверки",
                                      callback_data=f"exit:reboot-force:{iface}")
    kb = InlineKeyboardMarkup(inline_keyboard=[[
        action,
        InlineKeyboardButton(text="❌ Отмена", callback_data=f"exit:menu:{iface}"),
    ]])
    await safe_edit_text(
        call.message,
        f"<b>🔄 Reboot: {flag} {e['name']}</b>  <code>{e['ip']}</code>\n\n"
        f"{body}{guard_line}{shared_line}\n\n"
        f"Exit выпадет из ECMP на ~1 мин. Остальные пиры (Auto) переключатся "
        f"на живые exits автоматически, watchdog вернёт этот в строй после загрузки."
        f"{pinned_line}",
        parse_mode="HTML", reply_markup=kb,
    )


@router.callback_query(F.data.startswith("exit:reboot-yes:"))
@router.callback_query(F.data.startswith("exit:reboot-force:"))
@admin_only
async def cb_exit_reboot_yes(call: CallbackQuery) -> None:
    forced = call.data.startswith("exit:reboot-force:")
    await call.answer("⏳ Перезагружаю…")
    iface = call.data.split(":", 2)[2]
    e = _get_exit(state_load(), iface)
    if not e:
        return
    flag = name_to_flag(e.get("name", ""))

    # Проверяем ПОВТОРНО, прямо перед командой: между экраном подтверждения и
    # нажатием могло пройти сколько угодно времени, а состояние ноды за это
    # время меняется — например, приехало новое ядро.
    if not forced:
        out, err, rc = await ssh_exec(e["ip"], REBOOT_GUARD,
                                      username="root", key_path=SSH_KEY, timeout=30)
        if rc != 0:
            await safe_edit_text(
                call.message,
                f"🔴 <b>Перезагрузка отменена:</b> проверка готовности не пройдена.\n"
                f"<pre>{html_escape((err or out)[:400])}</pre>\n"
                "Можно перезагрузить вручную, но туннель после этого может не подняться.",
                parse_mode="HTML",
                reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
                    InlineKeyboardButton(text="⚠️ Всё равно перезагрузить",
                                         callback_data=f"exit:reboot-force:{iface}"),
                    InlineKeyboardButton(text="❌ Отмена",
                                         callback_data=f"exit:menu:{iface}"),
                ]]),
            )
            return

    # Отложенный ребут: обычный `reboot` по SSH не срабатывает — sshd убивается
    # раньше, чем systemd выполнит команду. Таймер переживает разрыв сессии.
    out, err, rc = await ssh_exec(
        e["ip"],
        "systemd-run --on-active=3 --timer-property=AccuracySec=100ms systemctl reboot",
        username="root", key_path=SSH_KEY, timeout=20,
    )
    if rc != 0:
        await safe_edit_text(
            call.message,
            f"❌ Не удалось запустить ребут:\n<pre>{html_escape((err or out)[:400])}</pre>",
            parse_mode="HTML",
            reply_markup=exit_menu_kb(iface, e.get("warp_state", "off")),
        )
        return

    LOG.warning("reboot %s (%s) forced=%s", e["name"], e["ip"], forced)
    head = ("⚠️ <b>Перезагрузка БЕЗ проверки готовности</b>\n\n" if forced else "")
    await safe_edit_text(
        call.message,
        f"{head}🔄 <b>{flag} {e['name']}</b> уходит в перезагрузку…\n\n"
        f"Обычно возвращается за ~60–90 сек. Watchdog сам вернёт его в ECMP "
        f"после появления handshake.\n\n"
        f"<i>Проверить: 📊 Статус или 🩺 Диагностика через минуту.</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="📊 Статус", callback_data=f"exit:status:{iface}"),
            InlineKeyboardButton(text="◀️ К списку", callback_data="exits:list"),
        ]]),
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

    # Захватываем ip + exit_iface ДО удаления (exit-remove.sh сотрёт из state).
    st = state_load()
    e = _get_exit(st, iface)
    exit_ip = e.get("ip") if e else None
    exit_iface = e.get("exit_iface", "awg-in") if e else "awg-in"

    # Кто был запинен на этот exit — снимаем ДО удаления, чтобы было что показать:
    # сам скрипт обнулит pinned_exit, и после вызова список уже не восстановить.
    pinned_names = [p["name"] for p in peers_list() if p.get("pinned_exit") == iface]

    # 1. RU-side: down awgN, rm conf/keys, убрать из state, пересобрать ECMP.
    out, err, rc = await sudo_run(
        "/usr/local/sbin/awg-cascade-exit-remove.sh", iface, timeout=300,
    )
    if rc != 0:
        await safe_edit_text(
            call.message,
            f"❌ Ошибка удаления:\n<pre>{(err or out)[:400]}</pre>",
            parse_mode="HTML",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
                InlineKeyboardButton(text="◀️ К списку", callback_data="exits:list")]]),
        )
        return

    # 2. Exit-side cleanup ТОЛЬКО для shared-интерфейса awg-in-N (N>=2).
    #    Primary awg-in (чужого RU) НИКОГДА не трогаем. Best-effort: если exit
    #    недоступен — удаление на RU всё равно состоялось.
    exit_cleanup = ""
    # Диапазон слотов задан в setup-exit.sh как 2..99. Прежний шаблон
    # `[2-9][0-9]?` покрывал 2-9 и 20-99, но не 10-19: при удалении такого exit'а
    # интерфейс, конфиг и ключи молча оставались на сервере.
    if exit_ip and re.match(r"^awg-in-([2-9]|[1-9][0-9])$", exit_iface):
        teardown = (
            f"/usr/local/sbin/awg-cascade-exit-warp.sh uninstall {exit_iface} >/dev/null 2>&1; "
            f"systemctl disable --now awg-quick@{exit_iface} >/dev/null 2>&1; "
            f"ip link del {exit_iface} 2>/dev/null; "
            f"rm -f /etc/amnezia/amneziawg/{exit_iface}.conf "
            f"/etc/awg-cascade-exit/info-{exit_iface}.json "
            f"/etc/awg-cascade-exit/awg2_params-{exit_iface} "
            f"/etc/awg-cascade-exit/private-{exit_iface}.key "
            f"/etc/awg-cascade-exit/public-{exit_iface}.key; "
            f"echo CLEANUP_OK"
        )
        try:
            o2, e2, rc2 = await ssh_exec(
                exit_ip, teardown, username="root", key_path=SSH_KEY, timeout=30,
            )
            exit_cleanup = (f"\n🧹 На exit убран <code>{exit_iface}</code>"
                            if rc2 == 0 and "CLEANUP_OK" in o2
                            else f"\n⚠️ Exit-cleanup не удался (убери <code>{exit_iface}</code> вручную)")
        except Exception as ex:
            exit_cleanup = (f"\n⚠️ Exit недоступен — <code>{exit_iface}</code> "
                            f"остался на сервере: {html_escape(str(ex))[:120]}")

    # safe_edit_text — retry 1-2-4с. Удаление exit'а через который бот ходит в
    # Telegram вызывает кратковременный flap egress (ECMP пересобирается) →
    # edit_text может таймаутить. State уже изменён, retry дотянется.
    # Имена интерфейсов переиспользуются: освободившийся awgN достанется
    # следующему добавленному exit'у. Поэтому про снятые pin'ы говорим явно —
    # молча они бы «переехали» на новый exit в другой стране.
    unpin_line = (
        f"\n📌 Сняты pin'ы (теперь Auto): <b>{html_escape(', '.join(pinned_names))}</b>"
        if pinned_names else ""
    )

    await safe_edit_text(
        call.message,
        f"🗑 Exit <b>{iface}</b> удалён.{exit_cleanup}{unpin_line}",
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
        f"<pre>printf '\\n%s\\n' '{pub}' >> ~/.ssh/authorized_keys</pre>\n\n"
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

    # 0. Снимаем старый пин host-ключа для этого IP.
    #
    # Добавление exit'а — это провижининг, который инициируем МЫ, поэтому смена
    # ключа здесь ожидаема и легитимна: адрес мог быть переустановлен или отдан
    # хостером под новую машину. Без сброса бот честно упёрся бы в расхождение
    # и отказался подключаться — правильное поведение в любой другой момент, но
    # не в этот. Дальше первый же контакт запомнит новый ключ (TOFU).
    # НО: сбрасываем только для адреса, который сейчас НЕ обслуживает exit.
    #
    # Раньше пин снимался безусловно, и это делало «добавить exit» универсальным
    # способом стереть защиту: адрес живого exit'а, у которого ключ вдруг не
    # сходится, достаточно было провести через этот диалог, и расхождение
    # исчезало молча. Смена ключа для уже работающего сервера — событие, о
    # котором надо знать, а не побочный эффект добавления.
    if any(e.get("ip") == ip for e in state_load().get("exits", [])):
        await update_status(
            f"❌ {ip} уже обслуживает exit в каскаде.\n\n"
            "Если сервер переустановили — сначала удалите этот exit, затем "
            "добавляйте заново: только так снимется пин его host-key."
        )
        return
    dropped = await asyncio.to_thread(host_key_forget, ip)
    if dropped:
        LOG.info("addexit: снят прежний host-key пин для %s", ip)

    # 1. Если есть пароль — копируем pubkey
    if password:
        await update_status("1/6 Копирую свой ssh-ключ на exit...")
        pub = Path(str(SSH_KEY) + ".pub").read_text().strip()
        ok, err = await ssh_copy_id(ip, password, pub)
        if not ok:
            await update_status(f"❌ Не удалось залогиниться:\n<pre>{err[:300]}</pre>")
            return

    # CLI and bot share one root-owned, resumable engine. No secrets in argv.
    await update_status("SSH доступ готов. Устанавливаю exit; повтор с тем же IP и именем продолжит прерванную операцию.")
    out, err, rc = await sudo_run("/usr/local/sbin/awg-cascade-provision.sh", ip, name, timeout=3300)
    # rc == 2 — особый исход: exit настроен, добавлен и работает, не
    # подтвердилась только его перезагрузка в новое ядро. Повторять
    # провижининг в этом случае нельзя: он уже сделан.
    if rc not in (0, 2):
        await update_status("❌ Установка не завершена. Повторите добавление с тем же IP и именем.\n<pre>" + html_escape(err[:400]) + "</pre>")
        return
    provision = json.loads(out)
    EXIT_INDEX = provision["index"]
    notes = []
    if provision.get("proto", "").startswith("failed"):
        notes.append("протокол 3.1 не включён, туннель остался на 2.0")
    if provision.get("reboot", "").startswith("failed"):
        notes.append("перезагрузка exit'а не подтверждена: "
                     + html_escape(str(provision["reboot"])))
    reboot_note = ""
    if notes:
        reboot_note = ("\n\n⚠️ " + "; ".join(notes)
                       + "\nПровижининг НЕ повторять — проверьте сам сервер.")

    flag2 = name_to_flag(name)
    await update_status(
        f"1/6 ✓ SSH\n"
        f"2/6 ✓ Index {EXIT_INDEX}\n"
        f"3/6 ✓ Keys\n"
        f"4/6 ✓ Exit настроен\n"
        f"5/6 ✓ awg{EXIT_INDEX} up на RU\n"
        f"6/6 ✓ Добавлен в state.json\n\n"
        f"✅ {flag2} <b>{name}</b> готов!\n"
        f"Через ~5 сек watchdog подхватит и добавит в ECMP." + reboot_note
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
