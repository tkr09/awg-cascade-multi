#!/bin/bash
# Scheduled reboot always passes the kernel/pending-operation guard.
set -euo pipefail
umask 077
STORE=/etc/awg-cascade/config
[ -f "$STORE" ] || STORE=/etc/awg-cascade-exit/autoreboot
AUTO_REBOOT=0; AUTO_REBOOT_HOUR=03; REBOOT_POLICY=manual
. /usr/local/sbin/awg-cascade-cfg.sh
[ ! -f "$STORE" ] || awgc_load_config "$STORE"
ARG=${1:-}
set_value() {
    if grep -q "^$1=" "$STORE"; then sed -i "s/^$1=.*/$1=\"$2\"/" "$STORE"
    else printf '%s="%s"\n' "$1" "$2" >> "$STORE"; fi
}
case "$ARG" in
    off) AUTO_REBOOT=0; REBOOT_POLICY=manual ;;
    [0-9]|[01][0-9]|2[0-3]) AUTO_REBOOT=1; AUTO_REBOOT_HOUR=$(printf '%02d' "$((10#$ARG))"); REBOOT_POLICY=scheduled ;;
    --show) echo "enabled=$AUTO_REBOOT policy=$REBOOT_POLICY hour=$AUTO_REBOOT_HOUR UTC"; exit 0 ;;
    --check|'') ;;
    *) exit 2 ;;
esac
OVERRIDE=/etc/apt/apt.conf.d/99-awg-cascade-reboot
WANT=0
[ "$AUTO_REBOOT" = 1 ] && [ "$REBOOT_POLICY" = scheduled ] && WANT=1
if [ "$ARG" = --check ]; then
    grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' "$OVERRIDE" || exit 1
    if [ "$WANT" = 1 ]; then systemctl is-active --quiet awg-cascade-reboot.timer
    else ! systemctl is-active --quiet awg-cascade-reboot.timer; fi
    exit $?
fi
mkdir -p "$(dirname "$STORE")"
touch "$STORE"
if [ -n "$ARG" ]; then
    set_value AUTO_REBOOT "$AUTO_REBOOT"; set_value AUTO_REBOOT_HOUR "$AUTO_REBOOT_HOUR"; set_value REBOOT_POLICY "$REBOOT_POLICY"
fi
echo 'Unattended-Upgrade::Automatic-Reboot "false";' > "$OVERRIDE"
if [ "$WANT" = 1 ]; then
    minute=$(hostname | cksum | awk '{print $1 % 60}')
    cat > /etc/systemd/system/awg-cascade-reboot.service <<'UNIT'
[Unit]
Description=Guarded AWG Cascade reboot
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I /usr/local/sbin/awg-cascade-reboot.py --scheduled
TimeoutStartSec=240
UNIT
    cat > /etc/systemd/system/awg-cascade-reboot.timer <<UNIT
[Unit]
Description=AWG Cascade maintenance window
[Timer]
OnCalendar=*-*-* $AUTO_REBOOT_HOUR:$(printf '%02d' "$minute"):00 UTC
Persistent=false
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now awg-cascade-reboot.timer
    echo "Плановая перезагрузка включена; shared exit по-прежнему требует ручного согласования"
else
    systemctl disable --now awg-cascade-reboot.timer 2>/dev/null || true
    echo "Автоматическая перезагрузка выключена; прежний AUTO_REBOOT=1 требует заново выбрать окно"
fi
