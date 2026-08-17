#!/bin/bash
# =============================================================================
# AWG Cascade Multi — отключение входа по паролю (SSH hardening)
#
# ЗАЧЕМ: свежая нода поднимается с `PasswordAuthentication yes`, и по ней сразу
# начинают долбить брутфорсом — наблюдали 90-100 тыс. попыток за месяц на ноду
# (root/admin/ubuntu + производные от hostname). Пока ключи работают, пароли
# нужны только атакующим.
#
# БЕЗОПАСНОСТЬ: скрипт НИКОГДА не отключает пароли, если в authorized_keys нет
# ни одного ключа — иначе на новой ноде можно запереть самого себя.
#
# ⚠️ ГЛАВНАЯ ЛОВУШКА Ubuntu: /etc/ssh/sshd_config.d/50-cloud-init.conf содержит
# `PasswordAuthentication yes` и ПЕРЕОПРЕДЕЛЯЕТ главный конфиг. Правки только в
# sshd_config не дают ничего. Поэтому чиним и drop-in, и кладём свой 99-* с
# наивысшим приоритетом, а результат сверяем через `sshd -T` (эффективное
# значение), а не чтением файлов.
#
# Usage:
#   awg-cascade-ssh-harden.sh           — отключить пароли (если есть ключи)
#   awg-cascade-ssh-harden.sh --check   — rc=0 уже закрыто, rc=1 нужно применить
#   awg-cascade-ssh-harden.sh --status   — показать состояние
#   awg-cascade-ssh-harden.sh --force   — применить даже без ключей (ОПАСНО)
# =============================================================================
set -u
DROPIN=/etc/ssh/sshd_config.d/99-awg-cascade-hardening.conf
MODE="${1:-}"

eff() { sshd -T 2>/dev/null | grep -oP "^$1 \K.*"; }

# Считаем ключи через awk, а НЕ через grep -c. Прежняя реализация была опасна:
# grep -c при нуле совпадений печатает "0" И выходит с кодом 1, поэтому `|| echo 0`
# дописывал ВТОРОЙ ноль. Выражение $(( n + 0<newline>0 )) падало с arithmetic error,
# count_keys возвращала ПУСТУЮ строку, а тест `[ "$KEYS" -lt 1 ]` на пустой строке
# печатал "integer expected" и давал ЛОЖЬ — то есть скрипт шёл отключать пароли на
# ноде, где ключей нет. Ровно тот сценарий блокировки, от которого он защищает.
#
# Тип ключа ищем в ЛЮБОМ поле строки: authorized_keys допускает префикс опций
# (`restrict,command="..." ssh-ed25519 AAAA...`), и такой ключ полностью рабочий —
# прежний якорь `^(ssh-|...)` его не видел и недосчитывал.
count_keys() {
    local n=0 f
    for f in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2; do
        [ -f "$f" ] || continue
        n=$(( n + $(awk '
            /^[[:space:]]*(#|$)/ { next }
            {
                for (i = 1; i <= NF; i++)
                    if ($i ~ /^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-|sk-(ssh-ed25519|ecdsa-sha2-))/) { c++; next }
            }
            END { print c + 0 }
        ' "$f" 2>/dev/null) ))
    done
    echo "$n"
}

if [ "$MODE" = "--status" ]; then
    echo "  ключей в authorized_keys: $(count_keys)"
    echo "  PasswordAuthentication:   $(eff passwordauthentication)"
    echo "  KbdInteractive:           $(eff kbdinteractiveauthentication)"
    echo "  PermitRootLogin:          $(eff permitrootlogin)"
    # ВАЖНО: только *.conf — sshd читает Include /etc/ssh/sshd_config.d/*.conf,
    # наши .bak/.awgbak он игнорирует, ругаться на них незачем.
    grep -lE '^\s*PasswordAuthentication\s+yes' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
        | sed 's/^/  ⚠ ещё разрешают пароль: /'
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    [ "$(eff passwordauthentication)" = "no" ] && exit 0 || exit 1
fi

KEYS=$(count_keys)
# Fail-safe: любой неожиданный вывод трактуем как «ключей нет», то есть отказ от
# hardening. Ошибка подсчёта должна приводить к сохранению доступа, а не к его потере.
case "$KEYS" in ''|*[!0-9]*) KEYS=0 ;; esac
if [ "$KEYS" -lt 1 ] && [ "$MODE" != "--force" ]; then
    echo "  ⚠ SSH hardening ПРОПУЩЕН: в /root/.ssh/authorized_keys нет ключей."
    echo "    Отключать пароль нельзя — потеряешь доступ. Добавь ключ и запусти:"
    echo "    awg-cascade-ssh-harden.sh"
    exit 2
fi

# 1. drop-in'ы, которые явно разрешают пароль (в первую очередь cloud-init)
for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "$DROPIN" ] && continue
    if grep -qE '^\s*PasswordAuthentication\s+yes' "$f"; then
        cp -a "$f" "$f.awgbak" 2>/dev/null
        sed -i 's/^\s*PasswordAuthentication.*/PasswordAuthentication no/' "$f"
        echo "  поправлен drop-in: $f"
    fi
done

# 2. главный конфиг
if grep -qE '^\s*#?\s*PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^\s*#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
fi

# 3. наш drop-in — грузится последним, перекрывает всё
cat > "$DROPIN" <<'EOF'
# AWG Cascade — вход только по ключам (иначе нода тонет в SSH-брутфорсе).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF
chmod 644 "$DROPIN"

# 4. применяем только если конфиг валиден; reload не рвёт активные сессии
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    sleep 1
    if [ "$(eff passwordauthentication)" = "no" ]; then
        echo "  ✅ вход по паролю отключён (ключей в authorized_keys: $KEYS)"
    else
        echo "  ⚠ применилось не полностью — проверь: sshd -T | grep passwordauth"
    fi
else
    echo "  🔴 sshd -t не прошёл — откатываю свой drop-in, конфиг не тронут"
    rm -f "$DROPIN"
fi
