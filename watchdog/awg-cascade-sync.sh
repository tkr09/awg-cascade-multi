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
#     exit-warp, ssh-harden, fail2ban). При изменении кода бот перезапускается.
#   • systemd-юниты awg-cascade-*.service
#   • каноничный sudoers awgbot (с visudo-валидацией)
#   • идемпотентные guards: gai.conf IPv4, маскировка ifupdown, alerting-блок
#   • version-stamp /etc/awg-cascade/version
# НЕ ТРОГАЕТ: awg0/awgN/wgc3, ключи, peers.json, state.json, venv бота, серверные
# значения config (RU_PUBLIC_IP/порт/подсеть, параметры обфускации и т.п.).
#
# ВАЖНО про область проверки: всё, что вне списка выше (setup.sh и генерируемый
# им iprule.service), drift-guard НЕ видит. С v2.2 сюда больше не относится
# awg-cascade-iptables.sh: он стал обычным файлом репо и проверяется наравне с
# остальными — раньше правка firewall доезжала до ноды только повторным
# запуском installer'а, а «дрейфа нет» про эти правила ничего не значило.
# Поэтому итоговое сообщение всегда печатает, что именно было проверено — иначе
# «дрейфа нет» читается как заявление о всей ноде, чем оно не является.
#
# Usage:
#   awg-cascade-sync.sh [ref]        — применить (re-deploy)
#   awg-cascade-sync.sh --check [ref] — только показать дрейф (ничего не менять)
# =============================================================================
set -u
REPO_URL="https://github.com/tkr09/awg-cascade-multi.git"
# Config читаем строгим разбором. Фолбэка на `source` здесь НЕТ намеренно:
# он существовал только на время раскатки v2.2.0 и сам по себе был дырой —
# достаточно было убрать cfg.sh, чтобы вернуть исполнение bot-writable файла
# от root. Нет парсера — нет конфига, это честный отказ.
{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true
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
# Счётчик НЕуспешных действий. Отдельно от drift: drift — это «сколько нашли
# отличий», errors — «сколько не смогли устранить». Раньше их не различали, и
# провал install, restart или enable не мешал записать version-stamp и напечатать
# «Синхронизировано». На ноде оставалась смесь версий, помеченная как целевой
# релиз, и мониторинг по stamp этого не видел — то есть ровно то, ради чего stamp
# и заводился, переставало работать именно в тот момент, когда нужно.
errors=0
# Что именно поменялось — нужно, чтобы понять, какие компоненты требуют
# АКТИВАЦИИ. Файл на диске и работающий процесс — разные вещи (см. ниже).
CHANGED=""
note_changed() { case " $CHANGED " in *" $1 "*) ;; *) CHANGED="$CHANGED $1" ;; esac; }
fail() { errors=$(( errors + 1 )); echo "  🔴 $1" >&2; }

sync_file() {  # <src> <dst> <mode> [доп. аргументы install, например -o awgbot -g awgbot]
    local src="$1" dst="$2" mode="$3"; shift 3
    [ -f "$src" ] || return 0

    # Сравниваем не только содержимое, но и права с владельцем. Файл с верными
    # байтами и mode 777 или чужим владельцем — это тоже дрейф, а cmp его не
    # видит. Для приватных ключей и sudoers разница принципиальна.
    local want_own="" cur_mode="" cur_own=""
    case " $* " in *" -o "*) want_own=$(echo "$*" | sed -n 's/.*-o \([^ ]*\).*/\1/p') ;; esac
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        cur_mode=$(stat -c '%a' "$dst" 2>/dev/null || echo "")
        cur_own=$(stat -c '%U' "$dst" 2>/dev/null || echo "")
        if [ "$cur_mode" = "$mode" ] && { [ -z "$want_own" ] || [ "$cur_own" = "$want_own" ]; }; then
            return 0
        fi
        drift=$(( drift + 1 ))
        if [ "$CHECK" = "1" ]; then
            echo "  ДРЕЙФ ПРАВ: $dst (mode $cur_mode, владелец $cur_own; ожидалось $mode${want_own:+/$want_own})"
            return 0
        fi
        install -m "$mode" "$@" "$src" "$dst" \
            && echo "  права исправлены: $dst" \
            || fail "не удалось исправить права: $dst"
        return 0
    fi

    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: $dst (отличается от репо $VER)"
    else
        if install -m "$mode" "$@" "$src" "$dst"; then
            echo "  обновлён: $dst"
            note_changed "$(basename "$dst")"
        else
            fail "не удалось установить: $dst"
        fi
    fi
}

echo "=== helper-скрипты ==="
for f in "$TMP"/repo/watchdog/awg-cascade-*.sh; do
    [ -e "$f" ] || continue
    sync_file "$f" "/usr/local/sbin/$(basename "$f")" 755
done

# Орфаны: скрипты на ноде, которых больше нет в репо (удалённые фичи).
# Список защиты пуст: и iptables.sh, и iprule.sh теперь лежат в watchdog/, то
# есть находятся по общему правилу «есть в репо — не орфан». Переменную
# оставляем как точку расширения, если снова появится генерируемый скрипт.
PROTECT_SH=""
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
    # Он же root-owned в /usr/local/sbin: client3.sh исполняет генератор от root,
    # и брать его из bot-writable каталога нельзя.
    sync_file "$TMP/repo/awg2-params.sh"                     "/usr/local/sbin/awg2-params.sh"                  755
    sync_file "$TMP/repo/exit-side/awg-cascade-exit-warp.sh" "$BOT_DIR/scripts/awg-cascade-exit-warp.sh"      755 $BOT_OWN
    sync_file "$TMP/repo/watchdog/awg-cascade-ssh-harden.sh" "$BOT_DIR/scripts/awg-cascade-ssh-harden.sh"     755 $BOT_OWN
    sync_file "$TMP/repo/watchdog/awg-cascade-fail2ban.sh"   "$BOT_DIR/scripts/awg-cascade-fail2ban.sh"       755 $BOT_OWN

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
# .timer наравне с .service: раньше цикл смотрел только на сервисы, и таймер,
# добавленный в репо, на ноду не приезжал вообще — drift-guard при этом молчал.
for f in "$TMP"/repo/systemd/awg-cascade-*.service "$TMP"/repo/systemd/awg-cascade-*.timer; do
    [ -e "$f" ] || continue
    before=$drift
    sync_file "$f" "/etc/systemd/system/$(basename "$f")" 644
    [ "$drift" -ne "$before" ] && units_changed=1
done

# Орфан-юниты: на ноде есть, в репо нет. Защищаем inline-генерируемые setup.sh
# (iptables/iprule.service) — их в репо нет, но они критичны для boot.
PROTECT_UNIT="awg-cascade-iptables.service awg-cascade-iprule.service"
for dst in /etc/systemd/system/awg-cascade-*.service /etc/systemd/system/awg-cascade-*.timer; do
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

# Канон ДОЛЖЕН совпадать с блоком в setup.sh: синк стирает всё, чего здесь нет.
# Набор сведён к тому, что бот реально зовёт — см. пояснение в setup.sh.
echo "=== sudoers (каноничный) ==="
SUD="/etc/sudoers.d/$BOT_USER"
cat > "$TMP/sud" <<EOF
# AWG Cascade Multi — $BOT_USER privileges
# Чтение состояния туннелей (awg show <iface> dump).
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/awg show *
# Разбудить watchdog после смены pin/веса.
$BOT_USER ALL=(root) NOPASSWD: /usr/bin/systemctl kill -s SIGUSR1 awg-cascade-watchdog
# Helper'ы каскада. Wildcard по имени — чтобы не ловить рассинхрон при
# добавлении нового helper'а; аргументы проверяет сам helper.
$BOT_USER ALL=(root) NOPASSWD: /usr/local/sbin/awg-cascade-*.sh
EOF
if [ ! -f "$SUD" ] || ! cmp -s "$TMP/sud" "$SUD"; then
    drift=$(( drift + 1 ))
    if [ "$CHECK" = "1" ]; then
        echo "  ДРЕЙФ: $SUD"
    elif visudo -c -f "$TMP/sud" >/dev/null 2>&1; then
        install -m 440 "$TMP/sud" "$SUD" && echo "  обновлён: $SUD" \
            || fail "не удалось установить $SUD"
    else
        fail "sudoers не прошёл visudo — пропускаю (бот останется на прежних правах)"
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
SCOPE="helper-скрипты, systemd-юниты и таймеры, sudoers, код бота и scripts/"
UNCHECKED="setup.sh, inline-генерируемый iprule.service, venv, ключи и значения config"

if [ "$CHECK" = "1" ]; then
    echo "─────────────────────────────"
    echo "   проверено:     $SCOPE"
    echo "   вне проверки:  $UNCHECKED"
    if [ "$drift" -eq 0 ]; then echo "✅ Дрейфа нет — проверяемая область соответствует репо $VER"; exit 0
    else echo "⚠️ Найдено расхождений: $drift (репо $VER). Применить: awg-cascade-sync.sh $REF"; exit 2; fi
else
    [ "$units_changed" = "1" ] && { systemctl daemon-reload; echo "  systemctl daemon-reload"; }
    # Таймеры надо не только положить, но и включить — иначе файл на месте, а
    # бэкапов нет, и это самый неприятный вид тишины.
    # Проверяем is-enabled И is-active. Раньше при enabled-но-остановленном
    # таймере срабатывал `continue`, и такой таймер оставался мёртвым навсегда:
    # файл на месте, enabled на месте, задача не выполняется.
    for t in "$TMP"/repo/systemd/awg-cascade-*.timer; do
        [ -e "$t" ] || continue
        tb=$(basename "$t")
        if systemctl is-enabled "$tb" >/dev/null 2>&1 && systemctl is-active --quiet "$tb"; then
            continue
        fi
        if systemctl enable --now "$tb" >/dev/null 2>&1 && systemctl is-active --quiet "$tb"; then
            echo "  таймер включён: $tb"
        else
            fail "таймер не запустился: $tb (systemctl status $tb)"
        fi
    done
    if [ "$bot_changed" = "1" ]; then
        # Устаревший .pyc может пережить замену .py — чистим кеш перед рестартом.
        find "$BOT_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
        # Мало запустить — надо убедиться, что он остался жив. Бот, упавший на
        # новом коде через секунду после старта, для systemctl restart успех.
        if systemctl restart awg-cascade-bot 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet awg-cascade-bot; then
                echo "  бот перезапущен (код изменился)"
            else
                fail "бот упал после обновления кода (journalctl -u awg-cascade-bot -n 50)"
            fi
        else
            fail "бот не перезапустился (systemctl status awg-cascade-bot)"
        fi
    fi

    echo "─────────────────────────────"
    # version-stamp пишем ТОЛЬКО при полном успехе. Иначе нода с частично
    # применённым обновлением помечена как целевой релиз, и дрейф-мониторинг
    # рапортует «всё сошлось» именно там, где сошлось не всё.
    if [ "$errors" -gt 0 ]; then
        echo "🔴 Синхронизация НЕ завершена: неуспешных действий — $errors (из $drift изменений)."
        echo "   version-stamp НЕ обновлён, нода осталась помечена как $(cat /etc/awg-cascade/version 2>/dev/null | awk '{print $1}')."
        echo "   проверено:     $SCOPE"
        echo "   вне проверки:  $UNCHECKED"
        [ -x /usr/local/sbin/awg-cascade-alert.sh ] && /usr/local/sbin/awg-cascade-alert.sh \
            sync-failed 1800 "🛑 sync не завершился" urgent warning \
            "awg-cascade-sync.sh на $(hostname -s): $errors неуспешных действий при переходе на $VER. Нода в смешанном состоянии." \
            >/dev/null 2>&1 || true
        exit 1
    fi
    # ─── Активация: файл на диске ≠ работающий код ───────────────────────────
    #
    # Раньше sync перезапускал только бота. Уже запущенный watchdog продолжал
    # исполнять ПРЕЖНИЙ код, а firewall не переприменялся вовсе — при этом
    # version-stamp писался новый. Нода отчитывалась о версии, которой в runtime
    # на ней не было. Это ровно тот способ, которым «репо = прод» расходится
    # снова, только уже незаметно.
    case " $CHANGED " in
        *" awg-cascade-watchdog.sh "*)
            # Перезапуск watchdog обратим и клиентского трафика не трогает.
            if systemctl restart awg-cascade-watchdog 2>/dev/null; then
                sleep 2
                if systemctl is-active --quiet awg-cascade-watchdog; then
                    echo "  watchdog перезапущен (код изменился)"
                else
                    fail "watchdog не поднялся после обновления кода"
                fi
            else
                fail "watchdog не перезапустился"
            fi
            ;;
    esac

    # Firewall и policy routing автоматически НЕ переприменяем: это данные-путь,
    # решение принимает оператор. Но и молчать нельзя — иначе новые правила лежат
    # файлом и не действуют до перезагрузки, а stamp уже новый.
    ACTIVATION=""
    for _c in awg-cascade-iptables.sh awg-cascade-client3-fw.sh               awg-cascade-interclient.sh awg-cascade-iprule.sh; do
        case " $CHANGED " in *" $_c "*) ACTIVATION="$ACTIVATION $_c" ;; esac
    done
    if [ -n "$ACTIVATION" ]; then
        mkdir -p /etc/awg-cascade
        echo "$VER$ACTIVATION" > /etc/awg-cascade/activation-pending
    else
        rm -f /etc/awg-cascade/activation-pending 2>/dev/null || true
    fi

    printf '%s %s %s\n' "$VER" "$COMMIT" "$(date -Iseconds)" > /etc/awg-cascade/version
    echo "✅ Синхронизировано с $VER ($COMMIT). Изменений: $drift. version-stamp обновлён."
    echo "   проверено:     $SCOPE"
    echo "   вне проверки:  $UNCHECKED"
    if [ "$req_changed" = "1" ]; then
        echo "  ⚠️ requirements.txt изменился, но venv НЕ обновлён автоматически:"
        echo "     новая версия зависимости может сломать работающего бота. Вручную:"
        echo "       sudo -u $BOT_USER $BOT_DIR/venv/bin/pip install -r $BOT_DIR/requirements.txt"
        echo "       sudo systemctl restart awg-cascade-bot"
    fi
    if [ -n "${ACTIVATION:-}" ]; then
        echo ""
        echo "⚠️  ТРЕБУЕТСЯ АКТИВАЦИЯ. Обновлены, но НЕ применены:$ACTIVATION"
        echo "    Новые правила лежат файлами и вступят в силу при следующей загрузке."
        echo "    Применить сейчас (кратко прервёт клиентский трафик):"
        echo "      sudo /usr/local/sbin/awg-cascade-iptables.sh"
        echo "    Отметка сохранена в /etc/awg-cascade/activation-pending."
    fi
    # Без явного exit 0 скрипт возвращал rc=1 при drift=0 (последней командой
    # оказывался ложный тест выше) — вызывающая сторона читала это как сбой.
    exit 0
fi
