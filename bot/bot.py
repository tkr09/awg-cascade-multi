#!/usr/bin/env python3
"""
AWG Cascade Multi — Telegram bot.

Запускается systemd'ом под пользователем awgbot.

Resilience: при TelegramNetworkError (cascade временно down, api.telegram.org
недоступен) бот не падает а ждёт с exponential backoff и retry'ит. systemd
Restart=always остаётся как backup (после max retries или fatal exception).
"""
from __future__ import annotations

import asyncio
import logging
import os
import sys

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.enums import ParseMode
from aiogram.exceptions import TelegramNetworkError, TelegramRetryAfter

# Локальные модули
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import cfg
from handlers import exits, main_menu, peers, settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
LOG = logging.getLogger("awg.bot")

# Параметры resilience
INITIAL_BACKOFF_SEC = 10
MAX_BACKOFF_SEC = 300            # 5 мин потолок
SESSION_TIMEOUT_SEC = 30         # общий timeout HTTP-запроса к Telegram API
STARTUP_NOTIFY_RETRIES = 3       # сколько раз пробовать прислать startup сообщение


async def _try_startup_notify(bot: Bot, chat_id: int) -> None:
    """Уведомление о запуске. Не критично — если не получилось, бот всё равно работает."""
    for attempt in range(STARTUP_NOTIFY_RETRIES):
        try:
            await bot.send_message(chat_id, "🚀 Bot started. /start — главное меню.")
            return
        except TelegramNetworkError as e:
            LOG.warning("Startup notify attempt %d failed: %s", attempt + 1, e)
            await asyncio.sleep(5)
        except Exception as e:
            LOG.warning("Startup notify failed (non-network): %s", e)
            return
    LOG.warning("Startup notify: %d attempts exhausted", STARTUP_NOTIFY_RETRIES)


async def _run_polling_with_retry(dp: Dispatcher, bot: Bot) -> None:
    """Запускает polling с автоматическим retry на TelegramNetworkError."""
    backoff = INITIAL_BACKOFF_SEC
    while True:
        try:
            await dp.start_polling(bot)
            # Если start_polling вернулся без исключения — значит остановили намеренно
            LOG.info("Polling stopped cleanly, exiting")
            return
        except TelegramRetryAfter as e:
            # Flood control от Telegram
            wait = max(1, int(getattr(e, "retry_after", 30)))
            LOG.warning("Telegram RetryAfter: wait %ds", wait)
            await asyncio.sleep(wait)
            backoff = INITIAL_BACKOFF_SEC  # сброс
        except TelegramNetworkError as e:
            LOG.warning(
                "TelegramNetworkError: %s — retry in %ds",
                str(e)[:200], backoff,
            )
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF_SEC)
        except (KeyboardInterrupt, SystemExit, asyncio.CancelledError):
            raise
        except Exception:
            LOG.exception("Unexpected exception in polling — retry in %ds", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, MAX_BACKOFF_SEC)


async def main() -> None:
    c = cfg()
    LOG.info("AWG Cascade Multi bot starting, admin=%s", c.tg_chat_id)

    # Сессия с увеличенным timeout (cascade может дать высокий RTT через NL)
    session = AiohttpSession(timeout=SESSION_TIMEOUT_SEC)

    bot = Bot(
        token=c.tg_token,
        session=session,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher()

    # Routers
    dp.include_router(main_menu.router)
    dp.include_router(exits.router)
    dp.include_router(peers.router)
    dp.include_router(settings.router)

    # Стартовое сообщение (best-effort, не блокирует запуск polling)
    asyncio.create_task(_try_startup_notify(bot, c.tg_chat_id))

    LOG.info("Polling... (session timeout=%ds, retry backoff=%d..%ds)",
             SESSION_TIMEOUT_SEC, INITIAL_BACKOFF_SEC, MAX_BACKOFF_SEC)
    try:
        await _run_polling_with_retry(dp, bot)
    finally:
        await bot.session.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        LOG.info("Bot stopped")
