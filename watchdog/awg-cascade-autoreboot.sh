#!/bin/bash
# =============================================================================
# AWG Cascade Multi — авто-ребут после unattended-upgrades
#
# unattended-upgrades ставит security-патчи ежедневно, но ядро применяется
# только после перезагрузки. Без авто-ребута kernel-патчи копятся месяцами
# (наблюдали 12 версий отставания). Этот скрипт включает автоматический ребут,
# который срабатывает ТОЛЬКО когда появился /var/run/reboot-required.
#
# ГЛАВНОЕ: окна ребута разнесены по нодам (свой час на каждую), чтобы каскад
# никогда не терял несколько exits одновременно → пустая ECMP = kill-switch.
# Минута внутри часа детерминирована (хеш hostname): стабильна между прогонами
# (иначе sync.sh видел бы дрейф каждый раз), но различна между хостами.
#
# Usage:
#   awg-cascade-autoreboot.sh              — применить из конфига
#   awg-cascade-autoreboot.sh <HH>         — включить на час HH и запомнить
#   awg-cascade-autoreboot.sh off          — выключить (ручной контроль)
#   awg-cascade-autoreboot.sh --check      — rc=0 настроено верно, rc=1 нужно применить
#   awg-cascade-autoreboot.sh --show       — показать текущее состояние
# =============================================================================
set -u
UU=/etc/apt/apt.conf.d/50unattended-upgrades

# Где храним настройку: RU — общий config; exit — отдельный файл.
if [ -f /etc/awg-cascade/config ]; then
    STORE=/etc/awg-cascade/config
elif [ -d /etc/awg-cascade-exit ]; then
    STORE=/etc/awg-cascade-exit/autoreboot
else
    STORE=/etc/awg-cascade-autoreboot
fi
[ -f "$STORE" ] && . "$STORE" 2>/dev/null || true

ARG="${1:-}"
AUTO_REBOOT="${AUTO_REBOOT:-0}"
AUTO_REBOOT_HOUR="${AUTO_REBOOT_HOUR:-03}"

# Минута: стабильный хеш от hostname (0..59)
stable_minute() {
    local h
    h=$(hostname 2>/dev/null | cksum | awk '{print $1}')
    printf '%02d' $(( ${h:-0} % 60 ))
}

# Прочитать текущее значение ключа из 50unattended-upgrades (только раскомментированное)
uu_get() {
    grep -oP "^Unattended-Upgrade::$1\s+\"\K[^\"]+" "$UU" 2>/dev/null | tail -1
}

# Идемпотентно выставить ключ: раскомментировать существующий или дописать
uu_set() {
    local key="$1" val="$2"
    if grep -qE "^\s*(//)?\s*Unattended-Upgrade::${key}\s+" "$UU" 2>/dev/null; then
        sed -i -E "s|^\s*(//)?\s*(Unattended-Upgrade::${key})\s+.*;|\2 \"${val}\";|" "$UU"
    else
        echo "Unattended-Upgrade::${key} \"${val}\";" >> "$UU"
    fi
}

# Запомнить настройку в STORE (идемпотентно)
store_set() {
    local key="$1" val="$2"
    [ -f "$STORE" ] || { mkdir -p "$(dirname "$STORE")"; : > "$STORE"; }
    if grep -qE "^${key}=" "$STORE" 2>/dev/null; then
        sed -i -E "s|^${key}=.*|${key}=\"${val}\"|" "$STORE"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$STORE"
    fi
}

case "$ARG" in
    off)
        AUTO_REBOOT=0
        store_set AUTO_REBOOT 0
        ;;
    [0-9]|[0-1][0-9]|2[0-3])
        AUTO_REBOOT=1
        AUTO_REBOOT_HOUR=$(printf '%02d' "$((10#$ARG))")
        store_set AUTO_REBOOT 1
        store_set AUTO_REBOOT_HOUR "$AUTO_REBOOT_HOUR"
        ;;
    --show)
        echo "store:   $STORE (AUTO_REBOOT=$AUTO_REBOOT HOUR=$AUTO_REBOOT_HOUR)"
        echo "текущее: Automatic-Reboot=$(uu_get 'Automatic-Reboot' || echo '—')"
        echo "         Automatic-Reboot-Time=$(uu_get 'Automatic-Reboot-Time' || echo '—')"
        echo "         Automatic-Reboot-WithUsers=$(uu_get 'Automatic-Reboot-WithUsers' || echo '—')"
        echo "pending: $([ -f /var/run/reboot-required ] && echo 'ДА — ребут будет в окно' || echo 'нет')"
        exit 0
        ;;
    --check|"") ;;
    *) echo "Usage: $0 [<HH>|off|--check|--show]"; exit 2 ;;
esac

[ -f "$UU" ] || { echo "🔴 $UU не найден (unattended-upgrades не установлен)"; exit 1; }

# Целевые значения
if [ "$AUTO_REBOOT" = "1" ]; then
    WANT_REBOOT=true
    WANT_TIME="${AUTO_REBOOT_HOUR}:$(stable_minute)"
else
    WANT_REBOOT=false
    WANT_TIME=""
fi

# --check: только сравнить, ничего не менять
if [ "$ARG" = "--check" ]; then
    cur_r=$(uu_get 'Automatic-Reboot')
    cur_t=$(uu_get 'Automatic-Reboot-Time')
    cur_u=$(uu_get 'Automatic-Reboot-WithUsers')
    if [ "$cur_r" != "$WANT_REBOOT" ]; then exit 1; fi
    if [ "$WANT_REBOOT" = "true" ]; then
        [ "$cur_t" = "$WANT_TIME" ] || exit 1
        [ "$cur_u" = "true" ]       || exit 1
    fi
    exit 0
fi

# Применяем
uu_set 'Automatic-Reboot' "$WANT_REBOOT"
if [ "$WANT_REBOOT" = "true" ]; then
    uu_set 'Automatic-Reboot-Time' "$WANT_TIME"
    # WithUsers=true — иначе висящая SSH-сессия заблокирует ребут
    uu_set 'Automatic-Reboot-WithUsers' 'true'
    echo "✅ Авто-ребут ВКЛ: окно ${WANT_TIME} UTC (только при reboot-required)"
else
    echo "✅ Авто-ребут ВЫКЛ (ручной контроль ребутов)"
fi
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
