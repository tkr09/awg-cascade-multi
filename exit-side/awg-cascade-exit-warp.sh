#!/bin/bash
# =============================================================================
# AWG Cascade Exit — WARP manager (interface-aware, multi-RU safe)
#
# Cloudflare WARP toggle для exit-сервера. Когда WARP включён для конкретного
# cascade-интерфейса (awg-in / awg-in-2 / ...), трафик приходящий из этого
# интерфейса уходит наружу через warp0 (Cloudflare), а не через eth0.
#
# Один exit может обслуживать НЕСКОЛЬКО RU (awg-in для RU-1, awg-in-2 для RU-2).
# WARP управляется НЕЗАВИСИМО для каждого: своя fwmark + ip rule. warp0 общий
# (один wgcf-аккаунт на сервер): поднимается на первом 'on', опускается на
# последнем 'off'. Так RU-2 не ломает WARP у RU-1 и наоборот.
#
# Команды (вызываются ботом по SSH):  <cmd> [iface]
#   install   — wgcf + warp0.conf (shared) + mark-rule для iface
#   on        — поднять warp0 (если ещё не поднят) + routing для iface
#   off       — убрать routing для iface; warp0 down если больше никто не юзает
#   status    — JSON статус для iface
#   rekey     — пересоздать WARP-аккаунт (новый exit IP) — влияет на все iface
#   uninstall — убрать routing для iface; полный снос если iface не осталось
#   restore   — восстановить WARP после загрузки по сохранённому состоянию
#               (вызывается юнитом awg-cascade-warp-restore.service)
#
# iface по умолчанию = awg-in (обратная совместимость со старым ботом).
# Stdout всегда JSON.
# =============================================================================

set -euo pipefail
umask 077
# Serialize shared warp0 mutations; restore children each acquire this lock.
if [ "${1:-status}" != restore ]; then
    exec 9>/run/awg-cascade-warp.lock
    flock -w 30 -x 9 || exit 1
fi
WGCF_VERSION=2.2.27
WGCF_BIN=/usr/local/bin/wgcf
WARP_DIR=/etc/awg-cascade-exit
WARP_CONF=/etc/amnezia/amneziawg/warp0.conf
WARP_LOG=$WARP_DIR/warp.log
TABLE=200          # общая table → warp0 (все марки сюда)

mkdir -p $WARP_DIR

log() { echo "$(date -Iseconds) [${IFACE:-?}] $*" >> $WARP_LOG; }

die() {
    log "ERROR: $1"
    jq -n --arg e "$1" '{ok:false, error:$e}'
    exit 1
}

# ─── iface → mark / priority ──────────────────────────────────────────────────
# awg-in → idx 1 → mark 0x10, prio 990
# awg-in-2 → idx 2 → mark 0x11, prio 991
# awg-in-N → idx N → mark 0x(0f+N), prio 989+N
IFACE="${2:-awg-in}"
case "$IFACE" in
    awg-in)   IDX=1 ;;
    awg-in-*) IDX="${IFACE##*-}" ;;
    *) die "bad iface: $IFACE (ожидается awg-in или awg-in-N)" ;;
esac
[[ "$IDX" =~ ^[0-9]+$ ]] || die "bad iface index: $IFACE"
[ "$IDX" -ge 1 ] && [ "$IDX" -le 99 ] || die "iface index outside 1..99"
MARK=$(printf '0x%x' $((0x10 + IDX - 1)))
RULE_PRIO=$((990 + IDX - 1))
WARP_STATE="$WARP_DIR/warp-$IFACE.state"

# Сколько cascade-интерфейсов сейчас маркируются в warp (т.е. WARP on)
count_active_marks() {
    iptables -t mangle -S PREROUTING 2>/dev/null \
        | grep -cE '\-i awg-in(-[0-9]+)? .*MARK' || true
}

# Получаем внешний IP через warp0
detect_warp_ip() {
    local result
    result=$(curl -4 -fsS --interface warp0 --max-time 6 --connect-timeout 3 https://www.cloudflare.com/cdn-cgi/trace) || return 1
    printf '%s\n' "$result" | grep -qE '^warp=(on|plus)$' || return 1
    printf '%s\n' "$result" | awk -F= '/^ip=/{print $2}' | python3 -c 'import sys,ipaddress; print(ipaddress.IPv4Address(sys.stdin.read().strip()))'
}
warp_guard() {
    iptables -w 30 -C FORWARD -i "$IFACE" -m comment --comment awgc-warp-guard -j DROP 2>/dev/null \
        || iptables -w 30 -I FORWARD 1 -i "$IFACE" -m comment --comment awgc-warp-guard -j DROP
}
warp_unguard() {
    while iptables -w 30 -C FORWARD -i "$IFACE" -m comment --comment awgc-warp-guard -j DROP 2>/dev/null; do
        iptables -w 30 -D FORWARD -i "$IFACE" -m comment --comment awgc-warp-guard -j DROP || return 1
    done
}
warp_killswitch() {
    iptables -w 30 -C FORWARD -i "$IFACE" ! -o warp0 -m comment --comment awgc-warp-killswitch -j DROP 2>/dev/null \
        || iptables -w 30 -I FORWARD 1 -i "$IFACE" ! -o warp0 -m comment --comment awgc-warp-killswitch -j DROP
}
warp_unprotect() {
    while iptables -w 30 -C FORWARD -i "$IFACE" ! -o warp0 -m comment --comment awgc-warp-killswitch -j DROP 2>/dev/null; do
        iptables -w 30 -D FORWARD -i "$IFACE" ! -o warp0 -m comment --comment awgc-warp-killswitch -j DROP || return 1
    done
}
persist_warp() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/.rules.v4.awgc-warp
    mv /etc/iptables/.rules.v4.awgc-warp /etc/iptables/rules.v4
}

# ─── install (shared warp0 + per-iface mark rule) ─────────────────────────────

cmd_install() {
    log "INSTALL begin"

    # 1. wgcf (если ещё нет) — shared
    if [ ! -x "$WGCF_BIN" ]; then
        local arch wa
        arch=$(uname -m)
        case "$arch" in
            x86_64)  wa="amd64" ;;
            aarch64) wa="arm64" ;;
            armv7l)  wa="armv7" ;;
            *) die "unsupported arch $arch" ;;
        esac
        curl -fsSL -o "$WGCF_BIN" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wa}" \
            || die "download wgcf failed"
        chmod +x "$WGCF_BIN"
        log "  wgcf $WGCF_VERSION installed"
    fi

    # 2-5. warp0.conf — создаём только если ещё нет (shared между всеми iface)
    if [ ! -f "$WARP_CONF" ]; then
        cd $WARP_DIR
        if [ ! -f wgcf-account.toml ]; then
            log "  registering WARP account..."
            printf 'yes\n' | $WGCF_BIN register >/dev/null 2>&1 || die "wgcf register failed"
        fi
        [ -f wgcf-account.toml ] || die "wgcf-account.toml missing"
        $WGCF_BIN generate >/dev/null 2>&1 || die "wgcf generate failed"
        [ -f wgcf-profile.conf ] || die "wgcf-profile.conf not generated"

        local endpoint_ip privkey pubkey address
        endpoint_ip=$(getent ahostsv4 engage.cloudflareclient.com 2>/dev/null | awk 'NR==1{print $1}')
        [ -z "$endpoint_ip" ] && endpoint_ip="162.159.193.10"
        privkey=$(awk -F' = ' '/^PrivateKey/{print $2}' wgcf-profile.conf)
        pubkey=$(awk  -F' = ' '/^PublicKey/{print $2}'  wgcf-profile.conf)
        address=$(awk -F' = ' '/^Address/{print $2}'    wgcf-profile.conf | head -1)

        cat > "$WARP_CONF" <<EOF
[Interface]
PrivateKey = $privkey
Address = $address
MTU = 1280
Table = off

[Peer]
PublicKey = $pubkey
AllowedIPs = 0.0.0.0/0
Endpoint = ${endpoint_ip}:2408
PersistentKeepalive = 25
EOF
        chmod 600 "$WARP_CONF"
        log "  warp0.conf created"
    fi

    # Installation prepares shared NAT/MSS. Only on may mark client traffic.
    iptables -t nat -C POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -o warp0 -j MASQUERADE
    iptables -t mangle -C FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    if [ ! -f "$WARP_STATE" ]; then
        jq -n --arg t "$(date -Iseconds)" \
            '{installed:true, running:false, installed_at:$t}' > "$WARP_STATE"
    fi
    install_restore_unit
    log "INSTALL OK"
    jq -n '{ok:true, installed:true}'
}

# ─── on ───────────────────────────────────────────────────────────────────────

cmd_on() {
    warp_guard || die "cannot guard WARP transition"
    if [ ! -f "$WARP_CONF" ]; then cmd_install >/dev/null; fi
    if ! ip link show warp0 >/dev/null 2>&1; then awg-quick up warp0 >/dev/null 2>&1 || die "warp0 up failed"; fi
    warp_killswitch || die "persistent kill-switch failed"
    persist_warp || die "kill-switch persistence failed"
    # A terminal rule protects against loss of the shared device/default route.
    ip rule show priority 1200 | grep -q "fwmark $MARK.*prohibit" \
        || ip rule add fwmark "$MARK" prohibit priority 1200 || die "terminal rule failed"
    ip route replace default dev warp0 table "$TABLE" || die "route failed"
    iptables -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark "$MARK" 2>/dev/null \
        || iptables -t mangle -A PREROUTING -i "$IFACE" -j MARK --set-mark "$MARK" || die "mark failed"
    ip rule show priority "$RULE_PRIO" | grep -q "fwmark $MARK.*lookup $TABLE" \
        || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$RULE_PRIO" || die "policy rule failed"
    install_restore_unit || die "restore unit failed"
    local exit_ip tmp
    exit_ip=$(detect_warp_ip) || die "WARP data plane not verified; guard retained"
    tmp=$(mktemp "$WARP_DIR/.state.XXXXXX")
    jq -n --arg ip "$exit_ip" --arg t "$(date -Iseconds)" '{installed:true,running:true,exit_ip:$ip,on_at:$t}' > "$tmp" || die "state render failed"
    mv "$tmp" "$WARP_STATE" || die "state commit failed"
    warp_unguard || die "guard release failed"
    persist_warp || { warp_guard; die "firewall persistence failed"; }
    jq -n --arg ip "$exit_ip" '{ok:true,warp_state:"on",exit_ip:$ip}'
}

# ─── off ──────────────────────────────────────────────────────────────────────

cmd_off() {
    warp_guard

    # ─── Снимаем routing ТОЛЬКО для этого iface ──────────────────────────────
    #
    # Раньше обе команды глушились через `2>/dev/null || true`, после чего
    # безусловно писалось running:false и возвращался успех. «Правила нет» и
    # «команда не отработала» — разные исходы, а считались одинаково удачными.
    #
    # Цена ошибки несимметрична: если MARK уцелел, трафик интерфейса продолжает
    # уходить в table $TABLE, то есть через WARP, — при том что состояние уже
    # объявлено выключенным. Владелец видит «off» и не понимает, почему адрес
    # чужой (A09 аудита v2.7.6).
    # Циклы ОГРАНИЧЕНЫ числом попыток. Дубликаты правил возможны, поэтому
    # удаляем «пока есть», но команда может вернуть ноль и не удалить ничего —
    # тогда условие цикла истинно вечно. Поймано тестом с подставным iptables:
    # первая версия этой правки уходила в бесконечный цикл ровно на том
    # сценарии, ради которого писалась.
    local errs="" tries
    tries=0
    while ip rule show priority "$RULE_PRIO" 2>/dev/null | grep -q "fwmark $MARK.*lookup $TABLE"; do
        tries=$((tries + 1))
        [ "$tries" -le 8 ] || { errs="$errs ip-rule-не-снимается"; break; }
        ip rule del fwmark $MARK lookup $TABLE || { errs="$errs ip-rule"; break; }
    done
    tries=0
    while iptables -w 30 -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -le 8 ] || { errs="$errs mangle-mark-не-снимается"; break; }
        iptables -w 30 -t mangle -D PREROUTING -i "$IFACE" -j MARK --set-mark $MARK \
            || { errs="$errs mangle-mark"; break; }
    done

    # Проверяем ФАКТ, а не то, что команды вернули ноль: селекторов быть не
    # должно ни одного.
    ip rule show priority "$RULE_PRIO" 2>/dev/null | grep -q "fwmark $MARK.*lookup $TABLE" \
        && errs="$errs правило-осталось"
    iptables -w 30 -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null \
        && errs="$errs маркировка-осталась"

    if [ -n "$errs" ]; then
        # Guard НЕ снимаем и состояние НЕ переписываем: WARP фактически остался
        # включённым, и объявлять обратное нельзя.
        log "OFF FAILED:${errs}"
        die "WARP не выключен, осталось:${errs} — состояние не менял"
    fi

    # Если больше НИ ОДИН iface не маркируется — опускаем общий warp0
    local remain
    remain=$(count_active_marks)
    if [ "${remain:-0}" -eq 0 ]; then
        awg-quick down warp0 2>/dev/null || true
        ip route flush table $TABLE 2>/dev/null || true
        log "OFF — warp0 down (никто больше не использует)"
    else
        log "OFF — warp0 оставлен (ещё $remain iface используют WARP)"
    fi

    jq -n --arg t "$(date -Iseconds)" \
        '{installed:true, running:false, off_at:$t}' > $WARP_STATE
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    warp_unprotect
    warp_unguard
    persist_warp
    jq -n '{ok:true, warp_state:"off"}'
}

# ─── status ──────────────────────────────────────────────────────────────────

cmd_status() {
    local installed=false running=false exit_ip=""
    [ -f "$WARP_CONF" ] && installed=true
    # running ДЛЯ ЭТОГО iface = warp0 поднят И есть mark-rule этого iface
    if ip link show warp0 >/dev/null 2>&1 && \
       iptables -t mangle -C PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null &&
       ip rule show priority "$RULE_PRIO" | grep -q "fwmark $MARK.*lookup $TABLE" &&
       ip route show table "$TABLE" | grep -q '^default dev warp0' &&
       ! iptables -w 30 -C FORWARD -i "$IFACE" -m comment --comment awgc-warp-guard -j DROP 2>/dev/null &&
       exit_ip=$(detect_warp_ip); then
        running=true
    fi
    jq -n --argjson i "$installed" --argjson r "$running" --arg ip "$exit_ip" \
        '{ok:true, installed:$i, running:$r, exit_ip:$ip, warp_state: (if $r then "on" else "off" end)}'
}

# ─── rekey (влияет на общий warp0 → меняет exit IP для ВСЕХ iface) ────────────

REKEY_DIR="$WARP_DIR/rekey-pending"
recover_rekey() {
    if [ -f "$REKEY_DIR/committed" ]; then rm -rf -- "$REKEY_DIR"; return 0; fi
    [ -f "$REKEY_DIR/ready" ] || return 0
    awg-quick down warp0 2>/dev/null || true
    for f in wgcf-account.toml wgcf-profile.conf; do
        if [ -f "$REKEY_DIR/$f" ]; then cp -p "$REKEY_DIR/$f" "$WARP_DIR/$f"; else rm -f "$WARP_DIR/$f"; fi
    done
    if [ -f "$REKEY_DIR/warp0.conf" ]; then cp -p "$REKEY_DIR/warp0.conf" "$WARP_CONF"; else rm -f "$WARP_CONF"; fi
    if [ -f "$REKEY_DIR/was-up" ]; then
        awg-quick up warp0 >/dev/null 2>&1 || die "rekey rollback: warp0 up failed"
        ip route replace default dev warp0 table "$TABLE" || die "rekey rollback: route failed"
    fi
    touch "$REKEY_DIR/committed"; sync -f "$REKEY_DIR"
    rm -rf -- "$REKEY_DIR"
    log "REKEY previous configuration recovered"
}
cmd_rekey() {
    # Ready journals were recovered before dispatch; discard partial snapshots.
    if [ -d "$REKEY_DIR" ]; then rm -rf -- "$REKEY_DIR"; fi
    mkdir -p "$REKEY_DIR"
    chmod 700 "$REKEY_DIR"
    for f in wgcf-account.toml wgcf-profile.conf; do
        [ ! -f "$WARP_DIR/$f" ] || cp -p "$WARP_DIR/$f" "$REKEY_DIR/$f"
    done
    [ ! -f "$WARP_CONF" ] || cp -p "$WARP_CONF" "$REKEY_DIR/warp0.conf"
    if ip link show warp0 >/dev/null 2>&1; then touch "$REKEY_DIR/was-up"; fi
    sync -f "$REKEY_DIR"
    touch "$REKEY_DIR/ready"
    sync -f "$REKEY_DIR"
    awg-quick down warp0 2>/dev/null || true
    rm -f "$WARP_DIR/wgcf-account.toml" "$WARP_DIR/wgcf-profile.conf" "$WARP_CONF"
    cmd_install >/dev/null
    if [ -f "$REKEY_DIR/was-up" ]; then
        awg-quick up warp0 >/dev/null 2>&1 || die "rekey warp0 up failed"
        ip route replace default dev warp0 table "$TABLE" || die "rekey route failed"
        detect_warp_ip >/dev/null || die "rekey data plane failed; rollback pending"
    fi
    touch "$REKEY_DIR/committed"; sync -f "$REKEY_DIR"
    rm -rf -- "$REKEY_DIR"
    log "REKEY committed"
    cmd_status
}

# ─── uninstall (per-iface; полный снос если iface не осталось) ─────────────────

cmd_uninstall() {
    cmd_off >/dev/null
    ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i "$IFACE" -j MARK --set-mark $MARK 2>/dev/null || true
    rm -f "$WARP_STATE"

    local remain
    remain=$(count_active_marks)
    if [ "${remain:-0}" -eq 0 ]; then
        awg-quick down warp0 2>/dev/null || true
        ip route flush table $TABLE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -o warp0 -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -D FORWARD -o warp0 -p tcp --tcp-flags SYN,RST SYN \
                 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        rm -f $WARP_CONF $WARP_DIR/wgcf-account.toml $WARP_DIR/wgcf-profile.conf
        # Восстанавливать больше нечего — юнит убираем вместе с остальным,
        # иначе он останется падать на каждой загрузке.
        systemctl disable --now awg-cascade-warp-restore.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/awg-cascade-warp-restore.service
        systemctl daemon-reload >/dev/null
        log "UNINSTALL — полный снос (последний iface)"
    else
        log "UNINSTALL — убран только $IFACE (ещё $remain используют warp0)"
    fi
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    jq -n '{ok:true}'
}

# ─── restore (загрузка) ───────────────────────────────────────────────────────
#
# ЗАЧЕМ. cmd_on создаёт только runtime-состояние: поднимает warp0, кладёт
# default в table 200 и ставит ip rule по fwmark. Сохранялись же лишь iptables и
# JSON-файл состояния, а ip rule и маршрут после перезагрузки исчезали. WARP при
# этом «оставался включённым» по всем показаниям — файл состояния говорит
# running:true, бот на RU показывает warp on — а трафик выходил с обычного IP
# exit'а. Расхождение желаемого и фактического, которое ничем не обнаруживалось.
#
# Восстанавливаем ЖЕЛАЕМОЕ состояние: для каждого интерфейса, у которого в
# state-файле running:true, повторяем ту же операцию on.
cmd_restore() {
    local f iface n=0 failed=0 waited deadline=$((SECONDS + 120))
    for f in "$WARP_DIR"/warp-*.state; do
        [ -e "$f" ] || continue
        jq -e '.running == true' "$f" >/dev/null 2>&1 || continue
        iface=$(basename "$f"); iface=${iface#warp-}; iface=${iface%.state}

        # Интерфейс поднимает awg-quick@, и на загрузке мы можем прийти раньше.
        # Ждём ограниченно, а не пропускаем молча: тихий пропуск здесь неотличим
        # от того самого дефекта, который мы чиним.
        waited=0
        while ! ip link show "$iface" >/dev/null 2>&1 && [ "$SECONDS" -lt "$deadline" ]; do
            sleep 2; waited=$(( waited + 2 ))
        done
        if ! ip link show "$iface" >/dev/null 2>&1; then
            log "RESTORE: $iface не появился за ${waited}s — WARP для него НЕ восстановлен"
            failed=$(( failed + 1 ))
            continue
        fi

        if [ "$SECONDS" -lt "$deadline" ] && timeout "$((deadline - SECONDS))" "$0" on "$iface" >/dev/null 2>&1; then
            n=$(( n + 1 )); log "RESTORE: $iface восстановлен"
        else
            failed=$(( failed + 1 )); log "RESTORE: $iface НЕ восстановлен (on вернул ошибку)"
        fi
    done
    log "RESTORE: восстановлено $n, не удалось $failed"
    jq -n --argjson n "$n" --argjson f "$failed" '{ok: ($f == 0), restored: $n, failed: $f}'
    [ "$failed" -eq 0 ]
}

# Юнит генерируем здесь, а не кладём файлом в systemd/ репозитория: тот каталог
# целиком разворачивается на RU, где этого скрипта нет и юнит только падал бы.
install_restore_unit() {
    cat > /etc/systemd/system/awg-cascade-warp-restore.service <<UNIT
[Unit]
Description=AWG Cascade Exit — восстановление WARP после загрузки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/awg-cascade-exit-warp.sh restore
# Интерфейсы поднимает awg-quick@, скрипт ждёт их появления сам (до 60с на
# интерфейс), поэтому таймаут юнита должен быть заведомо больше.
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null
    systemctl enable awg-cascade-warp-restore.service >/dev/null
    log "restore-юнит установлен и включён"
}

# ─── dispatch ────────────────────────────────────────────────────────────────

# Interrupted rekey restores the old keys before accepting another command.
if [ -f "$REKEY_DIR/ready" ]; then
    if [ "${1:-status}" = restore ]; then "$0" recover-rekey >/dev/null; else recover_rekey; fi
fi
case "${1:-status}" in
    recover-rekey) jq -n '{ok:true, recovered:true}' ;;
    install)   cmd_install ;;
    restore)   cmd_restore ;;
    on)        cmd_on ;;
    off)       cmd_off ;;
    status)    cmd_status ;;
    rekey)     cmd_rekey ;;
    uninstall) cmd_uninstall ;;
    *) jq -n --arg cmd "${1:-}" '{ok:false, error: "unknown command: " + $cmd}'; exit 1 ;;
esac
