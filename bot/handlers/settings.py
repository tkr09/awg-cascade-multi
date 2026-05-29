"""
Settings (read-only сейчас).
Rotate keys — per-peer и per-exit, см. handlers/peers.py и handlers/exits.py.
"""
from __future__ import annotations

import logging

from aiogram import F, Router
from aiogram.types import CallbackQuery, InlineKeyboardButton, InlineKeyboardMarkup

from common import admin_only, cfg, state_load

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
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
            InlineKeyboardButton(text="🏠 Меню", callback_data="main")]]),
    )
