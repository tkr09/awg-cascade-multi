#!/bin/bash
# AWG Cascade Multi — per-peer inter-client LAN access (idempotent).
#
# Зачем: по умолчанию ВЕСЬ трафик клиентов awg0 метится fwmark 0x1 и уходит
# в ECMP table 100 (exits). Это значит, что клиент↔клиент не работает (пакет
# уезжает на exit, который про внутренний IP ничего не знает). Это правильно
# для большинства пиров (изоляция), но некоторым доверенным пирам нужно
# ходить к конкретным внутренним устройствам (свои роутеры/админка).
#
# Модель: per-peer whitelist пар src→dst.
#   peers.json: { "ip": "<src>", "lan_allow": ["<dst1>", "<dst2>"] }
#   Разрешает <src> → <dst>: маршрутизировать локально (RETURN до MARK) +
#   FORWARD ACCEPT. Всё остальное к внутренней /24 — жёсткий DROP (default-deny).
#
# Идемпотентно: flush своих правил по комментарию awg-lan*, затем rebuild.
# Вызывается: из awg-cascade-iptables.sh (boot/персист) и ботом после тумблера.

set -u
. /etc/awg-cascade/config 2>/dev/null || true
PEERS=/etc/awg-cascade/peers.json
LOG=/var/log/awg-cascade-watchdog.log

log() { echo "$(date -Iseconds) INTERCLIENT $*" >> "$LOG" 2>/dev/null || true; }

# Клиентская подсеть: из config ($CLIENT_NET), иначе вывести из awg0
CN="${CLIENT_NET:-}"
if [ -z "$CN" ]; then
    CN=$(ip -o -4 addr show awg0 2>/dev/null | awk '{print $4}' | head -1 \
         | sed 's#\.[0-9]\{1,3\}/[0-9]\{1,2\}#.0/24#')
fi
[ -n "$CN" ] || { log "FAIL: client subnet unknown"; exit 0; }

# ─── 1. Flush наших прошлых правил (по комментарию awg-lan / awg-lan-deny) ────
flush_chain() {
    local table_flag="$1" chain="$2" line
    while line=$(iptables $table_flag -S "$chain" 2>/dev/null | grep -m1 'awg-lan'); do
        [ -n "$line" ] || break
        # -A ... → -D ...
        iptables $table_flag ${line/-A/-D} 2>/dev/null || break
    done
}
flush_chain "-t mangle" PREROUTING
flush_chain "" FORWARD

[ -f "$PEERS" ] || { log "no peers.json — only default-deny applied"; }

# ─── 2. Default-deny: awg0 → внутренняя /24 (жёсткий DROP) ─────────────────────
# Ставим в начало FORWARD; разрешающие пары вставим ВЫШЕ него (шаг 3).
iptables -I FORWARD 1 -i awg0 -d "$CN" -m comment --comment "awg-lan-deny" -j DROP

# ─── 3. Per-pair allow (src → dst) ───────────────────────────────────────────
if [ -f "$PEERS" ]; then
    jq -r '.[] | select(.lan_allow != null and (.lan_allow | length) > 0)
                 | .ip as $s | .lan_allow[] | "\($s) \(.)"' "$PEERS" 2>/dev/null \
    | while read -r src dst; do
        [ -n "$src" ] && [ -n "$dst" ] || continue
        # mangle: маршрут локальный (RETURN перед MARK 0x1)
        iptables -t mangle -I PREROUTING 1 -i awg0 -s "$src/32" -d "$dst/32" \
            -m comment --comment "awg-lan" -j RETURN
        # filter: разрешить форвард пары (вставляем выше default-deny)
        iptables -I FORWARD 1 -i awg0 -s "$src/32" -d "$dst/32" \
            -m comment --comment "awg-lan" -j ACCEPT
        log "allow $src -> $dst"
    done
fi

# ─── 4. Persist ───────────────────────────────────────────────────────────────
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
log "applied (client_net=$CN)"
