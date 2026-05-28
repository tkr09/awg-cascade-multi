#!/bin/bash
# AWG Cascade Multi — ip rules (persistent)
# Вызывается из systemd при старте + по необходимости.
BOT_UID=$(id -u awgbot 2>/dev/null || echo 999)

# Чистим старые наши правила
ip rule del fwmark 0x1 lookup 100 2>/dev/null
ip rule del fwmark 0x2 lookup 100 2>/dev/null
ip rule del uidrange $BOT_UID-$BOT_UID 2>/dev/null
ip rule del ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID 2>/dev/null

# 998: бот SSH-исходящий (tcp:22) → eth0 main. Чтобы могли управлять
# любыми exit-серверами в обход NL-hoster блокировки outbound :22.
ip rule add ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID lookup main priority 998

# 1000: клиенты awg0 → ECMP table 100
ip rule add fwmark 0x1 lookup 100 priority 1000

# 1001: бот (остальной outbound, например Telegram API) → ECMP table 100 через NL
ip rule add uidrange $BOT_UID-$BOT_UID lookup 100 priority 1001
