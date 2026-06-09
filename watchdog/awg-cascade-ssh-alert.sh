#!/bin/bash
# =============================================================================
# AWG Cascade Multi — SSH login alert (pam_exec hook)
# Вызывается из /etc/pam.d/sshd: session optional pam_exec.so ... этот скрипт.
# Алертит ТОЛЬКО на интерактивный вход (pts-tty), чтобы не спамить на
# автоматических `ssh host '<cmd>'` (у них нет pts). Дедуп per user@host (1ч).
# =============================================================================
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
# только интерактив (есть pseudo-terminal); неинтерактивные команды пропускаем
case "${PAM_TTY:-}" in
    *pts*) ;;
    *) exit 0 ;;
esac

# отключаемо через SSH_ALERT=0 в конфиге
. /etc/awg-cascade/config 2>/dev/null || true
[ "${SSH_ALERT:-1}" = "1" ] || exit 0

/usr/local/sbin/awg-cascade-alert.sh \
    "ssh-${PAM_USER:-?}-${PAM_RHOST:-?}" 3600 \
    "🔐 SSH вход: ${PAM_USER:-?}@$(hostname)" "high" "warning" \
    "$(printf 'Пользователь: %s\nС адреса: %s\nTTY: %s\nВремя: %s' \
        "${PAM_USER:-?}" "${PAM_RHOST:-?}" "${PAM_TTY:-?}" "$(date -Iseconds)")" &
exit 0
