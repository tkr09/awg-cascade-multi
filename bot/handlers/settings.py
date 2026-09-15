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
                    sudo_run, SSH_KEY)

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
            [InlineKeyboardButton(text="📱 Клиенты 3.x",
                                  callback_data="settings:client3")],
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


def _client3_kb(configured: bool) -> InlineKeyboardMarkup:
    rows = []
    if configured:
        rows.append([InlineKeyboardButton(text="⏹ Выключить 3.x",
                                          callback_data="settings:client3:down")])
    else:
        rows.append([InlineKeyboardButton(text="▶️ Включить 3.x",
                                          callback_data="settings:client3:up")])
    rows.append([InlineKeyboardButton(text="◀️ Настройки", callback_data="settings:main")])
    return InlineKeyboardMarkup(inline_keyboard=rows)


@router.callback_query(F.data == "settings:client3")
@admin_only
async def cb_client3(call: CallbackQuery) -> None:
    """
    Второй клиентский интерфейс (AmneziaWG 3.x).

    Версия протокола для клиентов спрашивается один раз, при установке. Выбрал
    2.0 — интерфейса wgc3 на ноде нет, и бот не может выдать 3.x-конфиг, потому
    что выдавать его не с чего. Путь создать интерфейс позже существовал только
    в CLI, то есть ответ на «почему я не могу добавить peer 3.1» был «переустанови
    ноду или иди в терминал». Теперь это кнопка.
    """
    await call.answer()
    c = cfg()
    if c.client3_iface:
        out, _, _ = await local_run("systemctl", "is-active",
                                    f"awg-quick@{c.client3_iface}", timeout=10)
        text = (
            f"📱 <b>Клиенты 3.x</b>\n\n"
            f"интерфейс: <code>{html_escape(c.client3_iface)}</code> "
            f"({html_escape(out.strip() or '?')})\n"
            f"порт: <code>{html_escape(str(c.client3_port))}/udp</code>\n"
            f"подсеть: <code>{html_escape(str(c.client3_net))}</code>\n\n"
            "Новые peer'ы можно выдавать на обоих интерфейсах — выбор появляется "
            "при создании.\n\n"
            "<i>Роутеры на NativeWG протокол 3.x не понимают и молча откатятся "
            "на 2.0 — им нужен обычный awg0.</i>"
        )
    else:
        text = (
            "📱 <b>Клиенты 3.x</b>\n\n"
            "<b>Не настроен.</b> При установке был выбран протокол 2.0, поэтому "
            "второго интерфейса на ноде нет — и выдать 3.x-конфиг не из чего.\n\n"
            "Включение создаст отдельный интерфейс <code>wgc3</code>: шифрование "
            "заголовков, набивка, случайные таймеры. Существующие peer'ы на "
            "<code>awg0</code> останутся как есть.\n\n"
            "<i>Займёт около минуты: поднимается интерфейс и пересобирается "
            "firewall.</i>"
        )
    await call.message.edit_text(text, parse_mode="HTML",
                                 reply_markup=_client3_kb(bool(c.client3_iface)))


@router.callback_query(F.data == "settings:client3:up")
@admin_only
async def cb_client3_up(call: CallbackQuery) -> None:
    await call.answer()
    await call.message.edit_text("⏳ Поднимаю второй интерфейс...", parse_mode="HTML")
    out, err, rc = await sudo_run("/usr/local/sbin/awg-cascade-client3.sh", "up",
                                  timeout=180)
    tail = (out or err).strip().splitlines()[-8:]
    body = html_escape("\n".join(tail))
    if rc != 0:
        await call.message.edit_text(
            "❌ Не поднялся.\n<pre>" + body + "</pre>",
            parse_mode="HTML", reply_markup=_client3_kb(False))
        return
    await call.message.edit_text(
        "✅ <b>Второй интерфейс поднят</b>\n<pre>" + body + "</pre>\n"
        "Теперь при создании peer'а бот спросит, на каком интерфейсе его выдать.",
        parse_mode="HTML", reply_markup=_client3_kb(True))


@router.callback_query(F.data == "settings:client3:down")
@admin_only
async def cb_client3_down(call: CallbackQuery) -> None:
    await call.answer()
    await call.message.edit_text(
        "⏹ <b>Выключить 3.x?</b>\n\n"
        "Интерфейс будет снесён, а его настройки убраны из config. Выданные на "
        "нём конфиги перестанут работать.\n\n"
        "<i>Если на интерфейсе ещё есть peer'ы, helper откажется — сначала удали "
        "их в разделе Peers.</i>",
        parse_mode="HTML",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="⏹ Да, выключить",
                                  callback_data="settings:client3:down-yes")],
            [InlineKeyboardButton(text="❌ Отмена", callback_data="settings:client3")],
        ]))


@router.callback_query(F.data == "settings:client3:down-yes")
@admin_only
async def cb_client3_down_yes(call: CallbackQuery) -> None:
    await call.answer()
    await call.message.edit_text("⏳ Сношу второй интерфейс...", parse_mode="HTML")
    out, err, rc = await sudo_run("/usr/local/sbin/awg-cascade-client3.sh", "down",
                                  timeout=180)
    tail = (out or err).strip().splitlines()[-8:]
    body = html_escape("\n".join(tail))
    ok = rc == 0
    await call.message.edit_text(
        ("✅ <b>Выключен</b>\n<pre>" if ok else "❌ Не вышло.\n<pre>") + body + "</pre>",
        parse_mode="HTML", reply_markup=_client3_kb(not ok and bool(cfg().client3_iface)))
