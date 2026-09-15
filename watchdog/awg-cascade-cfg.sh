#!/bin/bash
# =============================================================================
# AWG Cascade Multi — безопасное чтение /etc/awg-cascade/config.
#
# ЗАЧЕМ. Config принадлежит пользователю бота (бот его читает), а root-скрипты
# подключали его через `source`. Это означало прямую цепочку: захват процесса или
# учётной записи бота → правка config → вызов ЛЮБОГО разрешённого helper'а →
# выполнение произвольного кода от root. Ограничение списка команд в sudoers эту
# цепочку не закрывает вообще: helper'ы разрешены, а код приезжает не через
# аргументы, а через файл, который они послушно исполняют.
#
# Здесь config РАЗБИРАЕТСЯ, а не исполняется. Любая строка, не являющаяся
# присваиванием KEY=VALUE, игнорируется; подстановки, подоболочки и вызовы
# функций просто не имеют где выполниться, потому что eval нигде нет.
#
# Привилегированные пути не входят в schema. Значения НЕ исполняются.
# Значения НЕ фильтруются по символам — на этапе разбора они безвредны, а
# отбраковка ломала бы легитимные URL и токены. Вместо этого проверяются те
# немногие ключи, которые дальше подставляются в команды: имена интерфейсов,
# имя пользователя, подсети. Ключ, не прошедший проверку, отбрасывается — тогда
# вызывающий скрипт увидит пустое значение и остановится сам, что лучше, чем
# подставить в iptables строку вида "awg0; что-нибудь ещё".
#
# Использование (вместо `. /etc/awg-cascade/config`):
#   . /usr/local/sbin/awg-cascade-cfg.sh && awgc_load_config
# =============================================================================

awgc_load_config() {
    local f="${1:-/etc/awg-cascade/config}" line key val
    local -A parsed=()
    # Нечитаемый config — это ошибка, а не «ничего не задано»: скрипты с
    # set -e раньше обрывались на source и должны обрываться и теперь.
    [ -r "$f" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        # Комментарии, пустые строки и всё, что не присваивание
        case "$line" in
            ''|'#'*) continue ;;
            *=*)     ;;
            *) echo "config: invalid assignment" >&2; return 1 ;;
        esac

        key=${line%%=*}
        val=${line#*=}

        # Application paths are deliberately absent: PARAMS/CFG/WG_DIR etc.
        case "$key" in
            RU_PUBLIC_IP|AWG0_PORT|CLIENT_NET|CLIENT_NET_PREFIX|SERVER_IP|MAIN_IFACE|BOT_ENABLED|TG_TOKEN|TG_CHAT_ID|NTFY_URL|NTFY_TOPIC|BOT_USER|FIRST_PEER_VER|EXIT_PROTO|CLIENT3_IFACE|CLIENT3_PORT|CLIENT3_NET|CLIENT3_NET_PREFIX|CLIENT3_SERVER_IP|HC_PING_URL|DISK_ALERT_PCT|RAM_ALERT_PCT|LOAD_ALERT_MULT|SSH_ALERT|TRAFFIC_RETENTION_DAYS|AUTO_REBOOT|AUTO_REBOOT_HOUR|BACKUP_KEEP|RESERVE_TTL|MAX_INDEX|PAD_RANGE|REKEY_AFTER|REKEY_TIMEOUT|REJECT_AFTER|KEEPALIVE_TO|MAX_HS|NTFY_TIMEOUT|NTFY_RETRIES|NTFY_FALLBACK|EGRESS_CHECK_URL|RES_COOLDOWN|REBOOT_POLICY|PROBE_WORKERS|PROBE_DEADLINE|S1|S2|S3|S4|H1|H2|H3|H4|I1|I1_PROFILE) ;;
            *) echo "config: unsupported key $key" >&2; return 1 ;;
        esac

        # Ключ обязан быть валидным именем переменной И НЕ БЫТЬ переменной,
        # влияющей на поведение интерпретатора.
        #
        # Проверки имени мало, и это была дыра в первой версии парсера: `PATH`
        # — совершенно валидное имя, оно проходило фильтр, и `printf -v PATH`
        # подменял пути поиска для всех последующих root-команд скрипта. То
        # есть выполнение кода от root возвращалось тем же путём, ради закрытия
        # которого парсер и писался, только вместо `source` через PATH.
        #
        # Только ВЕРХНИЙ регистр: все ключи этого проекта такие, а строчные
        # имена в shell почти всегда служебные.
        case "$key" in
            ''|[!A-Z]*)      continue ;;
            *[!A-Z0-9_]*)    continue ;;
            BASH_*|LD_*)     continue ;;
        esac
        case "$key" in
            PATH|IFS|ENV|SHELL|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|             PROMPT_COMMAND|PS1|PS2|PS3|PS4|HOME|TMPDIR|TMP|TEMP|PWD|OLDPWD)
                echo "config: ключ $key игнорируется (влияет на интерпретатор)" >&2
                continue ;;
        esac

        # Снимаем ОДНУ пару обрамляющих кавычек — ровно то, что делал бы source
        # для простого присваивания. Внутренние кавычки оставляем как есть.
        case "$val" in
            \"*\") val=${val#\"}; val=${val%\"} ;;
            \'*\') val=${val#\'}; val=${val%\'} ;;
        esac

        # Ключи, которые дальше уходят в команды: строгая форма или ничего.
        case "$key" in
            BOT_USER)
                [[ "$val" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
                # root отдельно: имя проходит проверку символов, но означает, что
                # правило uidrange и chown начнут работать по root вместо бота.
                [ "$val" != "root" ] || return 1 ;;
            MAIN_IFACE|CLIENT3_IFACE)
                [[ -z "$val" && "$key" = CLIENT3_IFACE ]] || [[ "$val" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,14}$ ]] || return 1 ;;
            CLIENT_NET|CLIENT3_NET)
                case "$val" in *[!0-9./]*) return 1 ;; esac ;;
            CLIENT_NET_PREFIX|SERVER_IP|CLIENT3_SERVER_IP|RU_PUBLIC_IP)
                case "$val" in *[!0-9.]*) return 1 ;; esac ;;
            TG_CHAT_ID) [[ "$val" =~ ^-?[0-9]+$ ]] || return 1 ;;
            AWG0_PORT|CLIENT3_PORT|AUTO_REBOOT|AUTO_REBOOT_HOUR)
                case "$val" in ''|*[!0-9]*) return 1 ;; esac ;;
        esac

        case "$key" in
            AWG0_PORT|CLIENT3_PORT) [ "$((10#$val))" -ge 1 ] && [ "$((10#$val))" -le 65535 ] || return 1 ;;
            BOT_ENABLED|AUTO_REBOOT) [[ "$val" = 0 || "$val" = 1 ]] || return 1 ;;
            AUTO_REBOOT_HOUR) [ "$((10#$val))" -le 23 ] || return 1 ;;
            MAX_INDEX) [[ "$val" =~ ^[1-9][0-9]?$ ]] || return 1 ;;
            RESERVE_TTL) [[ "$val" =~ ^[0-9]{3,5}$ ]] && [ "$val" -ge 300 ] && [ "$val" -le 86400 ] || return 1 ;;
            BACKUP_KEEP) [[ "$val" =~ ^[0-9]{1,3}$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 365 ] || return 1 ;;
        esac
        parsed["$key"]=$val
    done < "$f"
    # Nothing is assigned until the entire file has been parsed.
    for key in "${!parsed[@]}"; do
        printf -v "$key" '%s' "${parsed[$key]}"
    done
    return 0
}
