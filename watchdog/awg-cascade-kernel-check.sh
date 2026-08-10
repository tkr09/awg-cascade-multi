#!/bin/bash
# =============================================================================
# AWG Cascade Multi — контроль отставания ядра (kernel drift)
#
# ЗАЧЕМ: unattended-upgrades НЕ подтягивает новые ядра — они приходят НОВЫМИ
# пакетами (linux-image-X.Y.Z-N), а u-u ставит только обновления существующих
# и пропускает phased-обновления. В логах при этом бодрое «No packages found
# that can be upgraded unattended», и ядро тихо отстаёт месяцами (наблюдали
# отставание 6.8.0-36 → 6.8.0-137 при «включённом» авто-обновлении).
#
# Скрипт проверяет ЛОКАЛЬНУЮ ноду и ВСЕ exits из state.json и шлёт ntfy, если:
#   • в apt доступно новое ядро (нужен ручной `apt dist-upgrade` + rolling reboot);
#   • reboot-required висит дольше REBOOT_STALE_DAYS (значит авто-ребут не сработал).
# Сам НИЧЕГО не обновляет и не перезагружает — только предупреждает.
#
# Запускается из watchdog; внутренний stamp не даёт бегать чаще раза в сутки.
#
# Usage:
#   awg-cascade-kernel-check.sh            — проверить (с учётом суточного stamp)
#   awg-cascade-kernel-check.sh --force    — проверить сейчас, игнорируя stamp
#   awg-cascade-kernel-check.sh --report   — только показать таблицу, без алертов
# =============================================================================
set -u
. /etc/awg-cascade/config 2>/dev/null || true
STATE=/etc/awg-cascade/state.json
SSH_KEY=/etc/awg-cascade/ssh/id_ed25519
ALERT=/usr/local/sbin/awg-cascade-alert.sh
STAMP=/var/lib/awg-cascade/.kernel-check
: "${KERNEL_ALERT_COOLDOWN:=604800}"   # неделя между повторами
: "${REBOOT_STALE_DAYS:=3}"            # reboot-required висит дольше — авто-ребут не сработал
: "${KERNEL_CHECK_EXITS:=1}"           # 0 = проверять только себя

MODE="${1:-}"
mkdir -p /var/lib/awg-cascade

if [ "$MODE" != "--force" ] && [ "$MODE" != "--report" ]; then
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    case "$last" in (*[!0-9]*|"") last=0 ;; esac
    [ $(( $(date +%s) - last )) -lt 86400 ] && exit 0
    date +%s > "$STAMP"
fi

# Возвращает: "<running> <newest_installed> <new_kernel_avail|-> <reboot_days|->"
probe_local() {
    local run newest avail rr days
    run=$(uname -r)
    newest=$(dpkg -l 2>/dev/null | awk '/^ii +linux-image-[0-9]/{print $2}' \
             | sed 's/linux-image-//' | sort -V | tail -1)
    apt-get update -qq >/dev/null 2>&1
    avail=$(apt-get -s dist-upgrade 2>/dev/null | grep -oP '^Inst linux-image-\K[0-9][^ ]*' | sort -V | tail -1)
    if [ -f /var/run/reboot-required ]; then
        days=$(( ( $(date +%s) - $(stat -c %Y /var/run/reboot-required 2>/dev/null || date +%s) ) / 86400 ))
    else
        days="-"
    fi
    echo "$run ${newest:-?} ${avail:--} ${days:--}"
}

PROBE_FN=$(declare -f probe_local)
ISSUES=""
ROWS=""

# ─── локальная нода ──────────────────────────────────────────────────────────
read -r L_RUN L_NEW L_AVAIL L_DAYS <<<"$(probe_local)"
HOST=$(hostname)
ROWS="$ROWS$(printf '%-16s %-20s %-20s %-14s %s' "$HOST*" "$L_RUN" "$L_NEW" "$L_AVAIL" "$L_DAYS")\n"
[ "$L_AVAIL" != "-" ] && ISSUES="$ISSUES• $HOST: доступно новое ядро $L_AVAIL (нужен dist-upgrade)\n"
[ "$L_DAYS" != "-" ] && [ "${L_DAYS:-0}" -ge "$REBOOT_STALE_DAYS" ] && \
    ISSUES="$ISSUES• $HOST: reboot-required висит ${L_DAYS} дн — авто-ребут не сработал\n"

# ─── exits ───────────────────────────────────────────────────────────────────
if [ "$KERNEL_CHECK_EXITS" = "1" ] && [ -f "$STATE" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
    while IFS=$'\t' read -r name ip; do
        [ -n "${ip:-}" ] || continue
        # -n обязателен: без него ssh съедает stdin цикла и обрабатывается
        # только первый exit из списка.
        out=$(ssh -n $SSH_OPTS "root@$ip" "$PROBE_FN; probe_local" 2>/dev/null)
        if [ -z "$out" ]; then
            ROWS="$ROWS$(printf '%-16s %s' "$name" "НЕДОСТУПЕН по SSH")\n"
            continue
        fi
        read -r r_run r_new r_avail r_days <<<"$out"
        ROWS="$ROWS$(printf '%-16s %-20s %-20s %-14s %s' "$name" "$r_run" "$r_new" "$r_avail" "$r_days")\n"
        [ "$r_avail" != "-" ] && ISSUES="$ISSUES• $name ($ip): доступно новое ядро $r_avail\n"
        [ "$r_days" != "-" ] && [ "${r_days:-0}" -ge "$REBOOT_STALE_DAYS" ] && \
            ISSUES="$ISSUES• $name ($ip): reboot-required висит ${r_days} дн\n"
    done < <(jq -r '.exits[] | select(.enabled) | "\(.name)\t\(.ip)"' "$STATE" 2>/dev/null)
fi

# ─── вывод / алерт ───────────────────────────────────────────────────────────
if [ "$MODE" = "--report" ] || [ -t 1 ]; then
    printf '%-16s %-20s %-20s %-14s %s\n' "НОДА" "ЗАПУЩЕНО" "УСТАНОВЛЕНО" "ДОСТУПНО" "REBOOT дн"
    printf "$ROWS"
    echo "─────────────────────────────"
    if [ -n "$ISSUES" ]; then printf "⚠️ Требует внимания:\n$ISSUES"; else echo "✅ Все ядра актуальны"; fi
fi

[ "$MODE" = "--report" ] && exit 0

if [ -n "$ISSUES" ] && [ -x "$ALERT" ]; then
    "$ALERT" kernel-drift "$KERNEL_ALERT_COOLDOWN" "⚠️ Ядра отстают" default warning \
        "$(printf 'Обнаружено отставание ядра:\n\n%b\nОбновление: apt dist-upgrade + rolling reboot (по одной ноде, сверяя dkms status).' "$ISSUES")"
fi
