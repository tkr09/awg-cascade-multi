#!/bin/bash
# Complete runtime activation; pending state clears only after every check passes.
set -euo pipefail
umask 077
[ "$EUID" -eq 0 ] && [ "$#" -eq 0 ] || exit 2
exec 9>/run/awg-cascade-activation.lock
flock -w 30 -x 9
BASE=/etc/awg-cascade
BOT=/opt/awg-cascade-bot
. /usr/local/sbin/awg-cascade-cfg.sh
awgc_load_config
[ -f "$BASE/installed-version" ] || { echo 'No installed version to activate' >&2; exit 1; }
printf 'activation in progress\n' >> "$BASE/activation-pending"
PREVIOUS=""; SWAPPED=0; VENV=""
activation_exit() {
    local result=$?
    trap - EXIT
    if [ "$result" -ne 0 ]; then
        # Restore the dependency environment; keep pending for runtime recovery.
        if [ "$SWAPPED" = 1 ] && [ -d "$PREVIOUS" ]; then
            systemctl stop awg-cascade-bot || true
            mv "$BOT/venv" "$VENV.failed" && mv "$PREVIOUS" "$BOT/venv" || true
        fi
        echo 'Activation incomplete; pending retained. Correct the failure and retry activation.' >&2
    fi
    exit "$result"
}
trap activation_exit EXIT
/usr/local/sbin/awg-cascade-permissions.sh
for script in /usr/local/sbin/awg-cascade-*.sh; do bash -n "$script"; done
python3 -I -c 'import ast,pathlib; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path("/usr/local/sbin").glob("awg-cascade-*.py")]'
# A legacy environment may be bot-writable. Build through the system Python.
VENV=$(mktemp -d "$BOT/.venv.XXXXXX")
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet -r "$BOT/requirements.txt"
"$VENV/bin/python" -m pip check
"$VENV/bin/python" -c 'import aiogram, asyncssh, qrcode'
systemctl stop awg-cascade-bot
if [ -e "$BOT/venv" ]; then PREVIOUS="$VENV.previous"; mv "$BOT/venv" "$PREVIOUS"; fi
chmod -R a+rX "$VENV"
mv "$VENV" "$BOT/venv"
SWAPPED=1
systemctl daemon-reload
/usr/local/sbin/awg-cascade-recover.sh
/usr/local/sbin/awg-cascade-iprule.sh
/usr/local/sbin/awg-cascade-iptables.sh
systemctl enable awg-cascade-recover.service
systemctl restart awg-cascade-watchdog awg-cascade-bot
sleep 3
systemctl is-active --quiet awg-cascade-watchdog
[ "${BOT_ENABLED:-1}" != 1 ] || systemctl is-active --quiet awg-cascade-bot
install -m 640 -o root -g "$BOT_USER" "$BASE/installed-version" "$BASE/.active-version.new"
mv "$BASE/.active-version.new" "$BASE/active-version"
rm -f "$BASE/activation-pending"
echo 'Runtime activation verified; active-version updated'
