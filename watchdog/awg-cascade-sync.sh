#!/bin/bash
# =============================================================================
# AWG Cascade Multi — sync / drift-guard
# Идемпотентно приводит КОД и КОНФИГ-ДОБАВКИ ноды в соответствие с публичным
# репо на заданном ref (по умолчанию — последний тег). Клонирует репо в /tmp.
#
# Синхронизирует ТОЛЬКО безопасные элементы:
#   • helper-скрипты /usr/local/sbin/awg-cascade-*.sh
#   • код бота /opt/awg-cascade-bot/{*.py,handlers/*.py,requirements.txt}
#     + provisioning-скрипты /opt/awg-cascade-bot/scripts/ (setup-exit, awg2-params,
#     exit-warp, ssh-harden). При изменении кода бот перезапускается.
#   • systemd-юниты awg-cascade-*.service
#   • каноничный sudoers awgbot (с visudo-валидацией)
#   • идемпотентные guards: gai.conf IPv4, маскировка ifupdown, alerting-блок
#   • version-stamp /etc/awg-cascade/version
# НЕ ТРОГАЕТ: awg0/awgN/wgc3, ключи, peers.json, state.json, venv бота, серверные
# значения config (RU_PUBLIC_IP/порт/подсеть, параметры обфускации и т.п.).
#
# ВАЖНО про область проверки: всё, что вне списка выше (в первую очередь setup.sh
# и inline-генерируемые setup.sh'ем iptables.sh/iprule.sh), drift-guard НЕ видит.
# Поэтому итоговое сообщение всегда печатает, что именно было проверено — иначе
# «дрейфа нет» читается как заявление о всей ноде, чем оно не является.
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
sync_file() {  # <src> <dst> <mode> [доп. аргументы install, например -o awgbot -g awgbot]
    local src="$1" dst="$2" mode="$3"; shift 3
    [ -f "$src" ] || return 0
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: $dst (отличается от репо $VER)"
    else
        install -m "$mode" "$@" "$src" "$dst" && echo "  обновлён: $dst"
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

echo "=== код бота (/opt/awg-cascade-bot) ==="
# Раньше эта область НЕ проверялась вообще, при том что скрипт печатал
# «нода соответствует репо $VER». Тег v2.1.3 правит ровно bot/handlers/exits.py,
# поэтому на живых нодах выдавалось ложное «дрейфа нет» — version-stamp честно
# показывал v2.1.2, а drift-guard утверждал соответствие v2.1.3. Теперь код
# бота и его provisioning-скрипты тоже под guard'ом.
#
# venv НЕ трогаем: он собирается на ноде и в репо его нет.
BOT_DIR=/opt/awg-cascade-bot
bot_changed=0
req_changed=0
if [ ! -d "$BOT_DIR" ]; then
    echo "  $BOT_DIR отсутствует — пропускаю (нода без бота)"
else
    # Файлы бота принадлежат $BOT_USER. Если пользователя нет — ставим без chown,
    # иначе install упал бы и оборвал синк.
    BOT_OWN=""
    id "$BOT_USER" >/dev/null 2>&1 && BOT_OWN="-o $BOT_USER -g $BOT_USER"
    _bot_before=$drift

    for f in "$TMP"/repo/bot/*.py; do
        [ -e "$f" ] || continue
        sync_file "$f" "$BOT_DIR/$(basename "$f")" 644 $BOT_OWN
    done

    # requirements.txt: синкаем файл, но venv автоматически НЕ переустанавливаем —
    # новая версия зависимости может сломать работающего бота. Только предупреждаем.
    if [ -f "$TMP/repo/bot/requirements.txt" ] \
       && ! cmp -s "$TMP/repo/bot/requirements.txt" "$BOT_DIR/requirements.txt" 2>/dev/null; then
        req_changed=1
    fi
    sync_file "$TMP/repo/bot/requirements.txt" "$BOT_DIR/requirements.txt" 644 $BOT_OWN

    [ "$CHECK" = "1" ] || mkdir -p "$BOT_DIR/handlers" "$BOT_DIR/scripts"
    for f in "$TMP"/repo/bot/handlers/*.py; do
        [ -e "$f" ] || continue
        sync_file "$f" "$BOT_DIR/handlers/$(basename "$f")" 644 $BOT_OWN
    done

    # Provisioning-скрипты, которые бот SCP-ит на новый exit. Лежат в репо в трёх
    # разных местах, поэтому перечислены поимённо, а не глобом.
    sync_file "$TMP/repo/setup-exit.sh"                      "$BOT_DIR/scripts/setup-exit.sh"                 755 $BOT_OWN
    sync_file "$TMP/repo/awg2-params.sh"                     "$BOT_DIR/scripts/awg2-params.sh"                755 $BOT_OWN
    sync_file "$TMP/repo/exit-side/awg-cascade-exit-warp.sh" "$BOT_DIR/scripts/awg-cascade-exit-warp.sh"      755 $BOT_OWN
    sync_file "$TMP/repo/watchdog/awg-cascade-ssh-harden.sh" "$BOT_DIR/scripts/awg-cascade-ssh-harden.sh"     755 $BOT_OWN

    # Орфаны в handlers/: удалённый из репо хендлер иначе останется на ноде вместе
    # со своим .pyc и продолжит импортироваться.
    for dst in "$BOT_DIR"/handlers/*.py; do
        [ -e "$dst" ] || continue
        base=$(basename "$dst")
        [ -f "$TMP/repo/bot/handlers/$base" ] && continue
        drift=$(( drift + 1 ))
        if [ "$CHECK" = "1" ]; then
            echo "  ОРФАН: $dst (нет в репо $VER)"
        else
            rm -f "$dst" && echo "  удалён орфан: $dst"
        fi
    done

    [ "$drift" -ne "$_bot_before" ] && bot_changed=1
fi

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
# Второй клиентский интерфейс: вызов client3-fw в iptables.sh. Этот скрипт
# генерится setup.sh инлайном и потому НЕ синкается — правим точечно и только
# на нодах, где второй интерфейс реально настроен (на остальных — no-op).
if [ -n "${CLIENT3_IFACE:-}" ] && [ -x /usr/local/sbin/awg-cascade-client3-fw.sh ] \
   && ! /usr/local/sbin/awg-cascade-client3-fw.sh --check-hook >/dev/null 2>&1; then
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: iptables.sh не вызывает client3-fw ($CLIENT3_IFACE без firewall-правил)"
    else
        /usr/local/sbin/awg-cascade-client3-fw.sh --hook | sed 's/^/  /'
        /usr/local/sbin/awg-cascade-iptables.sh >/dev/null 2>&1 || true
    fi
fi
# SSH: вход только по ключам (cloud-init drop-in может вернуть пароли обратно)
if [ -x /usr/local/sbin/awg-cascade-ssh-harden.sh ] \
   && ! /usr/local/sbin/awg-cascade-ssh-harden.sh --check >/dev/null 2>&1; then
    drift=$(( drift + 1 ))
    [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: SSH разрешает вход по паролю" \
        || { /usr/local/sbin/awg-cascade-ssh-harden.sh | sed 's/^/  /'; }
fi
# авто-ребут после unattended-upgrades (окно из AUTO_REBOOT_HOUR в config)
if [ -x /usr/local/sbin/awg-cascade-autoreboot.sh ] \
   && ! /usr/local/sbin/awg-cascade-autoreboot.sh --check >/dev/null 2>&1; then
    drift=$(( drift + 1 ))
    [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: auto-reboot окно не настроено (AUTO_REBOOT_HOUR)" \
        || { /usr/local/sbin/awg-cascade-autoreboot.sh | sed 's/^/  /'; }
fi
# SSH-login pam hook
if ! grep -q "awg-cascade-ssh-alert" /etc/pam.d/sshd 2>/dev/null; then
    drift=$(( drift + 1 ))
    [ "$CHECK" = "1" ] && echo "  ДРЕЙФ: pam SSH-alert hook отсутствует" \
        || { echo "session    optional   pam_exec.so /usr/local/sbin/awg-cascade-ssh-alert.sh" >> /etc/pam.d/sshd; echo "  pam SSH-alert добавлен"; }
fi

# Область проверки печатаем явно: раньше скрипт утверждал «нода соответствует
# репо $VER», не заглянув в код бота, и на v2.1.3 это было прямой неправдой.
SCOPE="helper-скрипты, systemd-юниты, sudoers, код бота и scripts/"
UNCHECKED="setup.sh, inline-генерируемые iptables.sh/iprule.sh, venv, ключи и значения config"

if [ "$CHECK" = "1" ]; then
    echo "─────────────────────────────"
    echo "   проверено:     $SCOPE"
    echo "   вне проверки:  $UNCHECKED"
    if [ "$drift" -eq 0 ]; then echo "✅ Дрейфа нет — проверяемая область соответствует репо $VER"; exit 0
    else echo "⚠️ Найдено расхождений: $drift (репо $VER). Применить: awg-cascade-sync.sh $REF"; exit 2; fi
else
    [ "$units_changed" = "1" ] && { systemctl daemon-reload; echo "  systemctl daemon-reload"; }
    if [ "$bot_changed" = "1" ]; then
        # Устаревший .pyc может пережить замену .py — чистим кеш перед рестартом.
        find "$BOT_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
        if systemctl restart awg-cascade-bot 2>/dev/null; then
            echo "  бот перезапущен (код изменился)"
        else
            echo "  ⚠️ бот не перезапустился — проверь: systemctl status awg-cascade-bot"
        fi
    fi
    printf '%s %s %s\n' "$VER" "$COMMIT" "$(date -Iseconds)" > /etc/awg-cascade/version
    echo "─────────────────────────────"
    echo "✅ Синхронизировано с $VER ($COMMIT). Изменений: $drift. version-stamp обновлён."
    echo "   проверено:     $SCOPE"
    echo "   вне проверки:  $UNCHECKED"
    if [ "$req_changed" = "1" ]; then
        echo "  ⚠️ requirements.txt изменился, но venv НЕ обновлён автоматически:"
        echo "     новая версия зависимости может сломать работающего бота. Вручную:"
        echo "       sudo -u $BOT_USER $BOT_DIR/venv/bin/pip install -r $BOT_DIR/requirements.txt"
        echo "       sudo systemctl restart awg-cascade-bot"
    fi
    [ "$drift" -gt 0 ] && echo "ℹ️  Watchdog при необходимости: systemctl restart awg-cascade-watchdog"
    # Без явного exit 0 скрипт возвращал rc=1 при drift=0 (последней командой
    # оказывался ложный тест выше) — вызывающая сторона читала это как сбой.
    exit 0
fi
