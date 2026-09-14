#!/bin/bash
# AWG Cascade Multi — ip rules (persistent, idempotent)
# Вызывается из awg-cascade-iprule.service при boot, а также из watchdog
# и helper-скриптов когда они меняют маршрутизацию.
#
# Идемпотентность через "удалить все правила по priority, затем добавить" —
# защита от дублей если ip rule add вызвался несколько раз.

# Имя пользователя берём из config, а не литералом: при установке с другим
# BOT_USER правило uidrange молча считалось бы для несуществующего awgbot и
# уезжало в фолбэк 999 — то есть бот ходил бы в Telegram мимо exit'ов, светя
# IP российской ноды. Фолбэк оставлен на случай, если config недоступен.
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true
: "${BOT_USER:=awgbot}"
BOT_UID=$(id -u "$BOT_USER" 2>/dev/null || echo 999)

# Удаляем все правила в наших слотах priorities (могло накопиться дублей)
for prio in 997 998 1000 1001; do
    while ip rule show priority $prio 2>/dev/null | grep -q "^$prio:"; do
        ip rule del priority $prio 2>/dev/null || break
    done
done

# 997: трафик МЕЖДУ клиентскими подсетями → main (локальная доставка).
#
# Зачем отдельным правилом, выше пина. awg-cascade-interclient.sh разрешает
# доверенные пары клиентов, делая RETURN до MARK, — расчёт на то, что без метки
# пакет пойдёт по обычному маршруту к соседней клиентской подсети. Для auto-пира
# так и есть. Но у pinned-пира правило priority 999 выбирает таблицу по ОДНОМУ
# только source IP, про fwmark оно ничего не знает. Поэтому разрешённый пакет
# к соседу всё равно попадал в default exit-таблицы и до соседа не доходил:
# LAN-доступ работал у обычных клиентов и молча не работал у привязанных.
#
# Безопасность от этого не страдает: КОМУ можно к соседу, решает whitelist в
# FORWARD (пары ACCEPT поверх default-deny на все клиентские /24), а не
# маршрутизация. Здесь мы лишь возвращаем локальному трафику локальный путь.
for _net in "${CLIENT_NET:-}" "${CLIENT3_NET:-}"; do
    [ -n "$_net" ] || continue
    ip rule add to "$_net" lookup main priority 997
done

# 998: бот SSH-исходящий (tcp:22) → eth0 main. Чтобы могли управлять
# любыми exit-серверами в обход block'ов outbound :22 у NL-хостеров.
ip rule add ipproto tcp dport 22 uidrange $BOT_UID-$BOT_UID lookup main priority 998

# 1000: клиенты awg0 (fwmark 0x1) → ECMP table 100
ip rule add fwmark 0x1 lookup 100 priority 1000

# 1001: бот (остальной outbound, например Telegram API) → ECMP table 100 через cascade
ip rule add uidrange $BOT_UID-$BOT_UID lookup 100 priority 1001
