#!/bin/bash
# AWG Cascade Multi — ip rules (persistent, idempotent)
# Вызывается из awg-cascade-iprule.service при boot, а также из watchdog
# и helper-скриптов когда они меняют маршрутизацию.
#
# Идемпотентность через "удалить все правила по priority, затем добавить" —
# защита от дублей если ip rule add вызвался несколько раз.

BOT_UID=$(id -u awgbot 2>/dev/null || echo 999)

# Удаляем все правила в наших слотах priorities (могло накопиться дублей)
for prio in 998 1000 1001; do
    while ip rule show priority $prio 2>/dev/null | grep -q "^$prio:"; do
        ip rule del priority $prio 2>/dev/null || break
    done
done

# 998: бот SSH-исходящий (tcp:22) → eth0 main. Чтобы могли управлять
# любыми exit-серверами в обход block'ов outbound :22 у NL-хостеров.
ip rule add ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID lookup main priority 998

# 1000: клиенты awg0 (fwmark 0x1) → ECMP table 100
ip rule add fwmark 0x1 lookup 100 priority 1000

# 1001: бот (остальной outbound, например Telegram API) → ECMP table 100 через cascade
ip rule add uidrange $BOT_UID-$BOT_UID lookup 100 priority 1001
