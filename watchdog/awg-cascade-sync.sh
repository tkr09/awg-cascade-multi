#!/bin/bash
# =============================================================================
# AWG Cascade Multi — sync / drift-guard
# Идемпотентно приводит КОД и КОНФИГ-ДОБАВКИ ноды в соответствие с публичным
# репо на заданном ref (по умолчанию — последний тег). Клонирует репо в /tmp.
#
# Синхронизирует ТОЛЬКО безопасные элементы:
#   • helper-скрипты /usr/local/sbin/awg-cascade-*.sh
#   • systemd-юниты awg-cascade-*.service
#   • каноничный sudoers awgbot (с visudo-валидацией)
#   • идемпотентные guards: gai.conf IPv4, маскировка ifupdown, alerting-блок
#   • version-stamp /etc/awg-cascade/version
# НЕ ТРОГАЕТ: awg0/awgN, ключи, peers.json, state.json, серверные значения
# config (RU_PUBLIC_IP/порт/подсеть и т.п.).
#
# Usage:
#   awg-cascade-sync.sh [ref]        — применить (re-deploy)
#   awg-cascade-sync.sh --check [ref] — только показать дрейф (ничего не менять)
# =============================================================================
set -u
REPO_URL="https://github.com/tkr09/awg-cascade-multi.git"
. /etc/awg-cascade/config 2>/dev/null || true
: "${BOT_USER:=awgbot}"

CHECK=0
[ "${1:-}" = "--check" ] && { CHECK=1; shift; }
REF="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Клонирую $REPO_URL ..."
if ! git clone --quiet "$REPO_URL" "$TMP/repo" 2>/dev/null; then
    echo "🔴 clone не удался (сеть?). Прерываю."; exit 1
fi
cd "$TMP/repo" || exit 1
if [ -n "$REF" ]; then
    git checkout --quiet "$REF" 2>/dev/null || { echo "🔴 ref '$REF' не найден"; exit 1; }
else
    REF=$(git describe --tags --abbrev=0 2>/dev/null || echo main)
    git checkout --quiet "$REF" 2>/dev/null || true
fi
VER=$(git describe --tags --always 2>/dev/null || echo "$REF")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
echo "→ Версия в репо: $VER ($COMMIT)"

drift=0
sync_file() {  # <src> <dst> <mode>
    local src="$1" dst="$2" mode="$3"
    [ -f "$src" ] || return 0
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: $dst (отличается от репо $VER)"
    else
        install -m "$mode" "$src" "$dst" && echo "  обновлён: $dst"
    fi
}

echo "=== helper-скрипты ==="
for f in "$TMP"/repo/watchdog/awg-cascade-*.sh; do
    [ -e "$f" ] || continue
    sync_file "$f" "/usr/local/sbin/$(basename "$f")" 755
done

# Орфаны: скрипты на ноде, которых больше нет в репо (удалённые фичи). Защищаем
# те, что setup.sh генерит inline и в watchdog/ их НЕТ (иначе снесём kill-switch).
PROTECT_SH="awg-cascade-iptables.sh awg-cascade-iprule.sh"
for dst in /usr/local/sbin/awg-cascade-*.sh; do
    [ -e "$dst" ] || continue
    base=$(basename "$dst")
    case " $PROTECT_SH " in *" $base "*) continue ;; esac
    [ -f "$TMP/repo/watchdog/$base" ] && continue
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ОРФАН: $dst (нет в репо $VER)"
    else
        rm -f "$dst" && echo "  удалён орфан: $dst"
    fi
done

echo "=== systemd-юниты ==="
units_changed=0
for f in "$TMP"/repo/systemd/awg-cascade-*.service; do
    [ -e "$f" ] || continue
    before=$drift
    sync_file "$f" "/etc/systemd/system/$(basename "$f")" 644
    [ "$drift" -ne "$before" ] && units_changed=1
done

# Орфан-юниты: на ноде есть, в репо нет. Защищаем inline-генерируемые setup.sh
# (iptables/iprule.service) — их в репо нет, но они критичны для boot.
PROTECT_UNIT="awg-cascade-iptables.service awg-cascade-iprule.service"
for dst in /etc/systemd/system/awg-cascade-*.service; do
    [ -e "$dst" ] || continue
    base=$(basename "$dst")
    case " $PROTECT_UNIT " in *" $base "*) continue ;; esac
    [ -f "$TMP/repo/systemd/$base" ] && continue
    drift=$(( drift + 1 )); units_changed=1
    if [ "$CHECK" = "1" ]; then
        echo "  ОРФАН-ЮНИТ: $dst (нет в репо $VER)"
    else
        systemctl disable --now "$base" >/dev/null 2>&1 || true
        rm -f "$dst" && echo "  удалён орфан-юнит: $dst"
    fi
done

echo "=== sudoers (каноничный) ==="
SUD="/etc/sudoers.d/$BOT_USER"
cat > "$TMP/sud" <<EOF
# AWG Cascade Multi — $BOT_USER privileges
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg, /usr/bin/awg-quick, /usr/bin/wg-quick
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl
$BOT_USER ALL=(root) NOPASSWD: /sbin/ip, /sbin/iptables, /sbin/ip6tables
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-*.sh
EOF
if [ ! -f "$SUD" ] || ! cmp -s "$TMP/sud" "$SUD"; then
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: $SUD"
    elif visudo -c -f "$TMP/sud" >/dev/null 2>&1; then
        install -m 440 "$TMP/sud" "$SUD" && echo "  обновлён: $SUD"
    else
        echo "  🔴 sudoers не прошёл visudo — пропускаю"
    fi
fi

echo "=== идемпотентные guards ==="
# gai.conf: предпочесть IPv4
if ! grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null; then
    drift=$(( drift + 1 ))
    [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: gai.conf без IPv4-preference" \
        || { echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf; echo "  gai.conf: IPv4-preference добавлен"; }
fi
# маскировка легаси ifupdown (если eth0 под networkd)
if systemctl is-active --quiet systemd-networkd && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    if systemctl is-enabled networking.service >/dev/null 2>&1; then
        drift=$(( drift + 1 ))
        [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: ifupdown не замаскирован" \
            || { systemctl mask networking.service ifup@eth0.service >/dev/null 2>&1; systemctl reset-failed networking.service ifup@eth0.service >/dev/null 2>&1; echo "  ifupdown замаскирован"; }
    fi
fi
# SSH-login pam hook
if ! grep -q "awg-cascade-ssh-alert" /etc/pam.d/sshd 2>/dev/null; then
    drift=$(( drift + 1 ))
    [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: pam SSH-alert hook отсутствует" \
        || { echo "session    optional   pam_exec.so /usr/local/sbin/awg-cascade-ssh-alert.sh" >> /etc/pam.d/sshd; echo "  pam SSH-alert добавлен"; }
fi

if [ "$CHECK" = "1" ]; then
    echo "─────────────────────────────"
    if [ "$drift" -eq 0 ]; then echo "✅ Дрейфа нет — нода соответствует репо $VER"; exit 0
    else echo "⚠️ Найдено расхождений: $drift (репо $VER). Применить: awg-cascade-sync.sh $REF"; exit 2; fi
else
    [ "$units_changed" = "1" ] && { systemctl daemon-reload; echo "  systemctl daemon-reload"; }
    printf '%s %s %s\n' "$VER" "$COMMIT" "$(date -Iseconds)" > /etc/awg-cascade/version
    echo "─────────────────────────────"
    echo "✅ Синхронизировано с $VER ($COMMIT). Изменений: $drift. version-stamp обновлён."
    [ "$drift" -gt 0 ] && echo "ℹ️  Перезапусти при необходимости: systemctl restart awg-cascade-watchdog awg-cascade-bot"
fi
