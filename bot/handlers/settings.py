"""
Settings (read-only сейчас).
Rotate keys — per-peer и per-exit, см. handlers/peers.py и handlers/exits.py.
"""
from __future__ import annotations

import logging
from pathlib import Path

from aiogram import F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup

from common import (admin_only, cfg, html_escape, local_run, state_load,
                    SSH_KEY)

LOG = logging.getLogger("awg.settings")
router = Router(name="settings")


@router.callback_query(F.data == "settings:main")
@admin_only
async def cb_settings(call: CallbackQuery) -> None:
    await call.answer()
    c = cfg()
    state = state_load()
    text = (
        f"<b>⚙️ Настройки</b>\n\n"
        f"<b>RU host:</b>      <code>{c.ru_public_ip}</code>\n"
        f"<b>awg0 port:</b>    <code>{c.awg0_port}/udp</code>\n"
        f"<b>Client subnet:</b> <code>{c.client_net}</code>\n"
        + (f"<b>{c.client3_iface} (3.0):</b> <code>{c.client3_port}/udp</code>  "
           f"<code>{c.client3_net}</code>\n" if c.client3_iface else "")
        +
        f"<b>Admin chat:</b>   <code>{c.tg_chat_id}</code>\n"
        f"<b>ntfy topic:</b>   <code>{c.ntfy_topic}</code>\n"
        f"<b>Bot user:</b>     <code>{c.bot_user}</code>\n\n"
        f"<b>state.json:</b>\n"
        f"  exits: <code>{len(state.get('exits', []))}</code>\n"
        f"  last_update: <code>{state.get('last_update', '?')}</code>\n\n"
        f"<i>Rotate keys per-peer: в меню peer'а.\n"
        f"Rotate keys per-exit: в меню exit'а.</i>"
    )
    await call.message.edit_text(
        text, parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🔑 SSH-ключ этой RU",
                                  callback_data="settings:sshkey")],
            [InlineKeyboardButton(text="🏠 Меню", callback_data="main")]]),
    )


@router.callback_query(F.data == "settings:sshkey")
@admin_only
async def cb_ssh_key(call: CallbackQuery) -> None:
    """
    Показать ПУБЛИЧНЫЙ ключ бота этой RU.

    Пара к кнопке «🔑 Ключ другой RU» в карточке exit'а. Чтобы подключить к
    этой RU уже работающий чужой exit, ей нужно отдать свой ключ: вход по
    паролю там отключён, и пускают только по ключу. Раньше ключ можно было
    взять лишь из терминала — то есть весь сценарий упирался в консоль.

    Ключ ПУБЛИЧНЫЙ: доступа он не даёт и существует ровно для того, чтобы его
    отдавать. Приватная часть лежит рядом с правами 600 и в бот не попадает.
    """
    await call.answer()
    pub_path = Path(str(SSH_KEY) + ".pub")
    back = InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="◀️ Настройки", callback_data="settings:main")]])
    try:
        pub = pub_path.read_text().strip()
    except OSError as exc:
        await call.message.edit_text(
            "❌ Публичный ключ не прочитан: <code>" + html_escape(str(exc)) + "</code>",
            parse_mode="HTML", reply_markup=back)
        return

    # Отпечаток — чтобы на принимающей стороне было с чем сверить.
    out, _, rc = await local_run("ssh-keygen", "-lf", str(pub_path), timeout=10)
    fpr = out.split()[1] if rc == 0 and len(out.split()) > 1 else "—"

    await call.message.edit_text(
        "🔑 <b>SSH-ключ бота этой RU</b>\n"
        f"<i>нода {html_escape(cfg().ru_public_ip)}</i>\n\n"
        f"<pre>{html_escape(pub)}</pre>\n"
        f"отпечаток: <code>{html_escape(fpr)}</code>\n\n"
        "<b>Зачем.</b> Чтобы подключить к этой RU уже работающий exit — вход по паролю там отключён, пускают только по ключу.\n\n"
        "<b>Что делать.</b> Открой бота той RU, которой этот exit принадлежит: 🌍 Exits → нужный exit → 🔑 Ключ другой RU → вставь этот текст. Потом вернись сюда и добавь exit кнопкой ➕.\n\n"
        "<i>Ключ публичный — пересылать его безопасно.</i>",
        parse_mode="HTML", reply_markup=back)
