#!/bin/bash
# AWG Cascade Multi — per-peer inter-client LAN access (idempotent).
#
# Зачем: по умолчанию ВЕСЬ трафик клиентов метится fwmark 0x1 и уходит в ECMP
# table 100 (exits). Это значит, что клиент↔клиент не работает (пакет уезжает
# на exit, который про внутренний IP ничего не знает). Это правильно для
# большинства пиров (изоляция), но некоторым доверенным пирам нужно ходить к
# конкретным внутренним устройствам (свои роутеры/админка).
#
# Модель: per-peer whitelist пар src→dst.
#   peers.json: { "ip": "<src>", "iface": "<awg0|wgc3>", "lan_allow": ["<dst1>"] }
#   Разрешает <src> → <dst>: маршрутизировать локально (RETURN до MARK) +
#   FORWARD ACCEPT. Всё остальное к внутренним /24 — жёсткий DROP (default-deny).
#
# ДВА КЛИЕНТСКИХ ИНТЕРФЕЙСА: awg0 (2.0) и опциональный CLIENT3_IFACE (3.0), у
# каждого своя /24. Пары обрабатываются КРОСС-ИНТЕРФЕЙСНО: пир, переехавший на
# 3.0, должен сохранить доступ к своим устройствам, оставшимся на awg0. Поэтому
# default-deny и established-возвраты строятся по декартову произведению
# {входной интерфейс} × {клиентская подсеть}, а правило пары берёт входной
# интерфейс из поля iface самого src-пира.
#
# Идемпотентно: flush своих правил по комментарию awg-lan*, затем rebuild.
# Вызывается: из awg-cascade-iptables.sh (boot/персист) и ботом после тумблера.

set -u
. /etc/awg-cascade/config 2>/dev/null || true
PEERS=/etc/awg-cascade/peers.json
LOG=/var/log/awg-cascade-watchdog.log

log() { echo "$(date -Iseconds) INTERCLIENT $*" >> "$LOG" 2>/dev/null || true; }

# Клиентская подсеть awg0: из config ($CLIENT_NET), иначе вывести из интерфейса
CN="${CLIENT_NET:-}"
if [ -z "$CN" ]; then
    CN=$(ip -o -4 addr show awg0 2>/dev/null | awk '{print $4}' | head -1 \
         | sed 's#\.[0-9]\{1,3\}/[0-9]\{1,2\}#.0/24#')
fi
[ -n "$CN" ] || { log "FAIL: client subnet unknown"; exit 0; }

# Таблица "интерфейс подсеть" по строке на клиентский интерфейс
IF_NETS="awg0 $CN"
if [ -n "${CLIENT3_IFACE:-}" ] && [ -n "${CLIENT3_NET:-}" ] \
   && ip link show "$CLIENT3_IFACE" >/dev/null 2>&1; then
    IF_NETS="$IF_NETS
$CLIENT3_IFACE $CLIENT3_NET"
fi
ALL_NETS=$(printf '%s\n' "$IF_NETS" | awk '{print $2}')

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

# ─── 2. База: default-deny + established-ответы ──────────────────────────────
# Порядок в цепочках (сверху вниз) после всех вставок:
#   [пары NEW src→dst] [established-ответы к /24] [default-deny] [базовые правила]
# Вставляем через -I 1 в ОБРАТНОМ порядке (deny → established → пары).
#
# Зачем established: трафик пары двусторонний. NEW src→dst разрешает пара (шаг 3),
# но ОБРАТНЫЙ пакет (dst→src, напр. SYN-ACK) иначе попадёт под общий MARK 0x1 и
# уедет в exit. Поэтому established-ответы к внутренним /24 — RETURN (локально) +
# ACCEPT. Это безопасно: established-стейт существует только для потоков, чьё
# NEW-направление уже разрешено whitelist'ом (для остальных NEW к /24 — DROP).
#
# Обратный пакет может прийти на ДРУГОЙ интерфейс, чем ушёл прямой (пара
# wgc3→awg0 возвращается как awg0→wgc3), поэтому оба слоя строятся по всем
# сочетаниям интерфейс×подсеть.

while read -r IF _; do
    [ -n "$IF" ] || continue
    for DN in $ALL_NETS; do
        iptables -I FORWARD 1 -i "$IF" -d "$DN" -m comment --comment "awg-lan-deny" -j DROP
    done
done <<EOF
$IF_NETS
EOF

while read -r IF _; do
    [ -n "$IF" ] || continue
    for DN in $ALL_NETS; do
        iptables -I FORWARD 1 -i "$IF" -d "$DN" -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "awg-lan" -j ACCEPT
        iptables -t mangle -I PREROUTING 1 -i "$IF" -d "$DN" -m conntrack --ctstate ESTABLISHED,RELATED \
            -m comment --comment "awg-lan" -j RETURN
    done
done <<EOF
$IF_NETS
EOF

# ─── 3. Per-pair allow (NEW src → dst) ───────────────────────────────────────
# Входной интерфейс берём из самого пира: пир на 3.0 приходит не с awg0.
if [ -f "$PEERS" ]; then
    jq -r '.[] | select(.lan_allow != null and (.lan_allow | length) > 0)
                 | . as $p | .lan_allow[] | "\($p.ip) \(.) \($p.iface // "awg0")"' "$PEERS" 2>/dev/null \
    | while read -r src dst sif; do
        [ -n "$src" ] && [ -n "$dst" ] || continue
        sif="${sif:-awg0}"
        # mangle: маршрут локальный (RETURN перед MARK 0x1) — вставляем выше established
        iptables -t mangle -I PREROUTING 1 -i "$sif" -s "$src/32" -d "$dst/32" \
            -m comment --comment "awg-lan" -j RETURN
        # filter: разрешить форвард пары (выше established/deny/изоляции интерфейсов)
        iptables -I FORWARD 1 -i "$sif" -s "$src/32" -d "$dst/32" \
            -m comment --comment "awg-lan" -j ACCEPT
        log "allow $src ($sif) -> $dst"
    done
fi

# ─── 4. Persist ───────────────────────────────────────────────────────────────
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
log "applied (ifaces: $(printf '%s' "$IF_NETS" | awk '{printf "%s ", $1}'))"
