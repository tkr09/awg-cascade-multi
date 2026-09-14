#!/bin/bash
# =============================================================================
# AWG Cascade Multi — правила iptables (kill-switch + MARK + MASQUERADE).
#
# Вызывается awg-cascade-iptables.service при загрузке, из postboot и вручную.
# Идемпотентен: повторный запуск не плодит дублей.
#
# ПОЧЕМУ ЭТОТ ФАЙЛ ЛЕЖИТ В РЕПО. До v2.2 он генерировался инлайном внутри
# setup.sh, и из-за этого не попадал ни в sync.sh, ни в drift-guard: правка
# firewall доезжала до ноды ТОЛЬКО повторным запуском монолитного installer'а,
# а «дрейфа нет» от drift-guard ничего про эти правила не значило. Теперь это
# обычный helper — синкается и сверяется вместе с остальными.
#
# Единственный параметр, который раньше подставлялся при генерации, — CLIENT_NET.
# Он читается из config, как и всё остальное.
# =============================================================================
#!/bin/bash
# AWG Cascade — apply iptables rules (idempotent)
set -e

{ . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config; } 2>/dev/null || true
C3="${CLIENT3_IFACE:-}"

# Без CLIENT_NET правило MASQUERADE для клиентов собрать не из чего, а без
# него трафик уйдёт на exit с внутренним src и будет им отброшен. Молча
# продолжать тут нельзя.
: "${CLIENT_NET:?CLIENT_NET не задан в /etc/awg-cascade/config}"

# ─── Барьер на время пересборки ──────────────────────────────────────────────
# Пересборка снимает kill-switch и ставит правила по одному: сначала MARK, потом
# MASQUERADE, и только в конце DROP. В промежутке клиентский пакет уже
# замаскирован, но ещё не заблокирован, и если table 100 при этом пуста (все
# exit'ы down, или мы на этапе загрузки), он уходит напрямую через WAN мимо
# каскада. Окно короткое, но оно на каждой пересборке.
#
# Поэтому первым действием кладём DROP для клиентских интерфейсов в САМОЕ начало
# FORWARD, а снимаем последним. Заодно это накрывает второй сценарий из аудита:
# чужой ACCEPT, стоящий выше нашего DROP, наш барьер перекрывает — он идёт первым.
#
# Комментарий барьера намеренно НЕ содержит "awg-cascade": иначе его снёс бы
# собственный flush_our_rules ниже.
# ─── Общая блокировка на всё применение ─────────────────────────────────────
#
# Барьер один на всех (GUARD — фиксированная строка), поэтому два одновременных
# запуска мешали друг другу разрушительно: первый завершившийся снимал барьер,
# пока второй ещё удалял и добавлял правила. Окно без защиты возвращалось ровно
# тем механизмом, который его закрывает.
#
# Тот же lock берёт awg-cascade-interclient.sh при самостоятельном запуске
# (кнопка LAN в боте): он тоже сносит и заново ставит правила.
FWLOCK=/run/awg-cascade-fw.lock
exec 9>"$FWLOCK" || true
if ! flock -w 120 -x 9; then
    echo "awg-cascade-iptables: не дождался блокировки firewall за 120с" >&2
    exit 1
fi

GUARD=awgc-rebuild-guard

# Барьер ставится и для IPv6: его набор перестраивался вообще без защиты.
guard6() {  # $1 = -C|-I|-D
    command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1 || return 0
    if [ "$1" = "-I" ]; then
        ip6tables -C FORWARD -i awg0 -m comment --comment "$GUARD" -j DROP 2>/dev/null             || ip6tables -I FORWARD 1 -i awg0 -m comment --comment "$GUARD" -j DROP 2>/dev/null || true
    else
        while ip6tables -S FORWARD 2>/dev/null | grep -q -- "--comment $GUARD"; do
            spec=$(ip6tables -S FORWARD | grep -m1 -- "--comment $GUARD") || break
            ip6tables ${spec/-A/-D} 2>/dev/null || break
        done
    fi
    return 0
}

guard_up() {
    guard6 -I
    iptables -C FORWARD -i awg0 -m comment --comment "$GUARD" -j DROP 2>/dev/null         || iptables -I FORWARD 1 -i awg0 -m comment --comment "$GUARD" -j DROP
    if [ -n "$C3" ]; then
        iptables -C FORWARD -i "$C3" -m comment --comment "$GUARD" -j DROP 2>/dev/null             || iptables -I FORWARD 1 -i "$C3" -m comment --comment "$GUARD" -j DROP
    fi
    return 0
}

guard_down() {
    guard6 -D
    local spec
    while spec=$(iptables -S FORWARD 2>/dev/null | grep -m1 -- "--comment $GUARD"); do
        [ -n "$spec" ] || break
        iptables ${spec/-A/-D} 2>/dev/null || break
    done
    return 0
}

# Оборвались на середине — барьер ОСТАЁТСЯ. Клиенты без интернета это плохо,
# но утечка мимо каскада хуже: набор правил в этот момент заведомо неполон.
# Чтобы это не осталось незамеченным, шлём алерт.
APPLIED=0
on_exit() {
    if [ "$APPLIED" = "1" ]; then
        guard_down
    else
        logger -t awg-cascade "iptables.sh оборвался — барьер оставлен, клиенты заблокированы" 2>/dev/null || true
        [ -x /usr/local/sbin/awg-cascade-alert.sh ] && /usr/local/sbin/awg-cascade-alert.sh             iptables-rebuild 900 "🛑 firewall не пересобрался" urgent warning             "awg-cascade-iptables.sh оборвался на середине. Клиентский трафик заблокирован барьером — это безопасный исход, но каскад не работает. Нужна ручная проверка."             >/dev/null 2>&1 || true
    fi
}
trap on_exit EXIT

guard_up

# ─── Очистка ТОЛЬКО своих правил, по комментарию ─────────────────────────────
# Раньше здесь было 'iptables-save | grep -v awg-cascade | iptables-restore' плюс
# '-F mangle PREROUTING/OUTPUT'. Полная очистка общих цепочек сносила правила
# любых других компонентов на ноде — комментарий при этом не спрашивали.
# Все наши правила (включая c3-* из client3-fw.sh) помечены "awg-cascade*",
# поэтому адресная чистка их покрывает целиком. Правила "awg-lan" не трогаем:
# ими управляет awg-cascade-interclient.sh, он вызывается в конце и чистит сам.
del_by_comment() {  # $1 = -t табл. или пусто, $2 = цепочка
    local spec
    while spec=$(iptables $1 -S "$2" 2>/dev/null | grep -m1 -- '--comment awg-cascade'); do
        [ -n "$spec" ] || break
        iptables $1 ${spec/-A/-D} 2>/dev/null || break
    done
    return 0
}

del6_by_comment() {  # $1 = цепочка ip6tables
    local spec
    while spec=$(ip6tables -S "$1" 2>/dev/null | grep -m1 -- '--comment awg-cascade'); do
        [ -n "$spec" ] || break
        ip6tables ${spec/-A/-D} 2>/dev/null || break
    done
    return 0
}

flush_our_rules() {
    local ch
    for ch in FORWARD INPUT OUTPUT;            do del_by_comment ""          "$ch"; done
    for ch in PREROUTING OUTPUT FORWARD;       do del_by_comment "-t mangle" "$ch"; done
    for ch in POSTROUTING PREROUTING;          do del_by_comment "-t nat"    "$ch"; done
    for ch in FORWARD OUTPUT;                  do del6_by_comment            "$ch"; done
}

# Снять прошлые наши правила перед повторным применением — иначе они
# дублируются при каждом прогоне (boot/postboot/ручной перезапуск).
flush_our_rules

# --- mangle: MARK клиентского трафика для ECMP routing ---
# 0x1 = трафик клиентов awg0 → table 100 (ECMP exits)
iptables -t mangle -A PREROUTING -i awg0 -m comment --comment "awg-cascade" -j MARK --set-mark 0x1
# Для бота используется НЕ mangle MARK (он не триггерит re-route), а ip rule uidrange — см. ниже

# --- nat: MASQUERADE клиентского трафика на исходе из awg1..awgN ---
# Зачем: внутренний пакет от клиента имеет src=10.222.122.X. Exit-нода видит
# inner packet с этим src — но peer AllowedIPs у неё = 10.99.N.2/32 (наш tunnel IP).
# Wireguard на exit'е отвергает пакеты с src НЕ из AllowedIPs. Решение: на RU
# подменяем src клиентских пакетов на наш tunnel IP (через MASQUERADE на awg1).
# Условие ! -o awg0 = масквардим всё что уходит НЕ к клиенту (то есть на любой awgN).
iptables -t nat -A POSTROUTING -s "$CLIENT_NET" ! -o awg0 -m comment --comment "awg-cascade-masq" -j MASQUERADE

# MASQUERADE для tunnel-side трафика (RU bot + любой локальный с src=10.99.*.*).
# Зачем: Linux ECMP per-flow hash меняет out-interface, но source IP всегда
# берётся с первого nexthop. Если ECMP кинул на awg2 а src остался =10.99.1.2 —
# exit отвергает (AllowedIPs=10.99.<N>.2/32). MASQUERADE подменяет src на
# IP актуального out-interface, exit принимает.
iptables -t nat -A POSTROUTING -s 10.99.0.0/16 -o awg+ -m comment --comment "awg-cascade-tunnel-masq" -j MASQUERADE

# --- filter FORWARD: kill-switch ---
# Клиентский трафик может выйти ТОЛЬКО через awg+ (awg1..awgN)
# Если ECMP-таблица пуста (все exits down) → нет nexthop'а → drop
# Дополнительно: явный DROP если awg0 → не-awg
iptables -A FORWARD -i awg0 -o awg+ -m comment --comment "awg-cascade" -j ACCEPT
iptables -A FORWARD -i awg+ -o awg0 -m comment --comment "awg-cascade" -j ACCEPT
iptables -A FORWARD -i awg0 ! -o awg+ -m comment --comment "awg-cascade-killsw" -j DROP

# --- mangle FORWARD: MSS clamp для TCP (двойная инкапсуляция → нужно PMTU) ---
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m comment --comment "awg-cascade-mss" -j TCPMSS --clamp-mss-to-pmtu

# --- второй клиентский интерфейс (AmneziaWG 3.0), если поднят ---
# No-op без CLIENT3_IFACE в config. ДОЛЖЕН идти после kill-switch'а awg0: тот
# закрывает awg0 → C3 (имя C3 намеренно вне маски awg+), а этот — обратную
# сторону. И ДО interclient: тот вставляет исключения через -I 1, то есть выше.
# Результат helper'ов ПРОВЕРЯЕТСЯ. Раньше стояло `|| true`, и при неудаче
# правил второго интерфейса или LAN-ACL скрипт всё равно выставлял APPLIED=1 и
# снимал барьер — то есть публиковал как готовую заведомо неполную защиту.
HELPERS_OK=1
if [ -x /usr/local/sbin/awg-cascade-client3-fw.sh ]; then
    /usr/local/sbin/awg-cascade-client3-fw.sh || {
        echo "awg-cascade-iptables: client3-fw вернул ошибку" >&2; HELPERS_OK=0; }
fi

# --- per-peer inter-client LAN access (whitelist src→dst + default-deny /24) ---
# Применяет правила awg-lan из peers.json поверх базовых (должно идти ПОСЛЕ MARK).
if [ -x /usr/local/sbin/awg-cascade-interclient.sh ]; then
    # Он берёт тот же lock; мы его уже держим, поэтому передаём флаг.
    AWGC_FW_LOCK_HELD=1 /usr/local/sbin/awg-cascade-interclient.sh || {
        echo "awg-cascade-iptables: interclient вернул ошибку" >&2; HELPERS_OK=0; }
fi

# --- IPv6: каскад IPv4-only, значит IPv6 обязан быть закрыт явно ---
#
# До сих пор про IPv6 не было ни одного правила — только предпочтение IPv4 в
# gai.conf. Но предпочтение это не запрет: на ноде с рабочим IPv6 политика
# ip6tables FORWARD по умолчанию ACCEPT, а kill-switch описан только для IPv4.
# То есть весь разбор «клиент может выйти только через awg+» к IPv6 не относился
# вообще. Для бота то же самое: правило uidrange выбирает IPv4-таблицу 100 и к
# IPv6-маршруту отношения не имеет, поэтому запрос к Telegram по IPv6 ушёл бы
# напрямую — причём не только в аварии, а всегда.
#
# Сейчас это скорее закрытие дыры на будущее, чем исправление наблюдаемой утечки:
# клиентские туннели IPv4-only, и IPv6-трафику внутри них взяться неоткуда. Но
# зависеть это должно от правил, а не от того, что адрес некому выдать.
# || true на каждом правиле: set -e активен, а ip6tables на ноде без модуля
# ip6_tables падает уже на первом вызове. Оборвать из-за этого всю пересборку
# нельзя — барьер останется поднятым и клиенты окажутся отрезаны совсем.
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1; then
    ip6tables -A FORWARD -i awg0 -m comment --comment "awg-cascade-killsw6" -j DROP || true
    ip6tables -A FORWARD -o awg0 -m comment --comment "awg-cascade-killsw6" -j DROP || true
    if [ -n "$C3" ]; then
        ip6tables -A FORWARD -i "$C3" -m comment --comment "awg-cascade-killsw6" -j DROP || true
        ip6tables -A FORWARD -o "$C3" -m comment --comment "awg-cascade-killsw6" -j DROP || true
    fi
    # Бот: REJECT, а не DROP — быстрый отказ, чтобы getaddrinfo сразу перешёл на
    # IPv4, а не ждал таймаута.
    BOT_UID6=$(id -u "${BOT_USER:-awgbot}" 2>/dev/null || echo "")
    [ -n "$BOT_UID6" ] && ip6tables -A OUTPUT -m owner --uid-owner "$BOT_UID6"         -m comment --comment "awg-cascade-bot6" -j REJECT 2>/dev/null || true
fi

# Барьер снимаем ТОЛЬКО если полон весь набор, включая helper'ы.
if [ "$HELPERS_OK" = "1" ]; then
    APPLIED=1
else
    echo "awg-cascade-iptables: набор правил неполон — барьер оставлен" >&2
    exit 1
fi

# Persist. Барьер в rules.v4 не попадает: сохраняем ПОСЛЕ его снятия.
guard_down
# Сохраняем ПОСЛЕ снятия барьера и только при полном наборе: иначе временный
# DROP уехал бы в rules.v4 и восстанавливался при загрузке как постоянный.
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
