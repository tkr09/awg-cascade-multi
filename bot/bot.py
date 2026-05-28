#!/usr/bin/env python3
"""
AWG Cascade Multi — Telegram bot.

Запускается systemd'ом под пользователем awgbot.
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode

# Локальные модули
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import cfg
from handlers import exits, main_menu, peers, settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
LOG = logging.getLogger("awg.bot")


async def main() -> None:
    c = cfg()
    LOG.info("AWG Cascade Multi bot starting, admin=%s", c.tg_chat_id)

    bot = Bot(
        token=c.tg_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher()

    # Routers
    dp.include_router(main_menu.router)
    dp.include_router(exits.router)
    dp.include_router(peers.router)
    dp.include_router(settings.router)

    # Стартовое сообщение админу
    try:
        await bot.send_message(
            c.tg_chat_id,
            "🚀 Bot started. /start — главное меню.",
        )
    except Exception as e:
        LOG.warning("Не удалось отправить startup-сообщение: %s", e)

    LOG.info("Polling...")
    await dp.start_polling(bot)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        LOG.info("Bot stopped")
