#!/bin/bash
# =============================================================================
# AWG Cascade Multi — traffic sampler (история трафика per-peer для графиков)
#
# Снимает кумулятивные счётчики `awg show awg0 transfer` (pubkey rx tx) и
# дописывает в CSV. Вызывается watchdog'ом раз в ~5 мин (TICK_COUNT % 30).
# Бот читает CSV и рисует unicode-спарклайн скорости per-peer.
#
# Формат строки CSV:  epoch,pubkey,rx_bytes,tx_bytes
# Счётчики кумулятивные (сброс при down/up awg0 или re-add пира) — бот считает
# дельты между соседними замерами и клампит отрицательные (сброс) в 0.
#
# Ретенция: раз в сутки прунит строки старше TRAFFIC_RETENTION_DAYS.
# Объём: ~10 пиров × 288 замеров/сут ≈ 150 КБ/сут, за 14 дней ~2 МБ.
# =============================================================================
set -u
. /etc/awg-cascade/config 2>/dev/null || true
: "${TRAFFIC_RETENTION_DAYS:=14}"

DIR=/var/lib/awg-cascade
CSV="$DIR/traffic.csv"
PRUNE_MARK="$DIR/.traffic-last-prune"
NOW=$(date +%s)

mkdir -p "$DIR"

# ─── Замер: дописываем по строке на каждого пира awg0 ────────────────────────
awg show awg0 transfer 2>/dev/null | while IFS=$'\t' read -r pubkey rx tx; do
    [ -n "$pubkey" ] || continue
    printf '%s,%s,%s,%s\n' "$NOW" "$pubkey" "${rx:-0}" "${tx:-0}" >> "$CSV"
done
chmod 644 "$CSV" 2>/dev/null || true

# ─── Ретенция: прунить не чаще раза в сутки (дёшево) ─────────────────────────
last=$(cat "$PRUNE_MARK" 2>/dev/null || echo 0)
case "$last" in (*[!0-9]*|"") last=0 ;; esac
if [ $(( NOW - last )) -ge 86400 ] && [ -f "$CSV" ]; then
    cutoff=$(( NOW - TRAFFIC_RETENTION_DAYS * 86400 ))
    tmp=$(mktemp)
    if awk -F, -v c="$cutoff" 'NF>=4 && $1+0 >= c' "$CSV" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$CSV"
        chmod 644 "$CSV" 2>/dev/null || true
    else
        rm -f "$tmp"
    fi
    echo "$NOW" > "$PRUNE_MARK"
fi
