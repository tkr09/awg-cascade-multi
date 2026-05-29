#!/bin/bash
# =============================================================================
# AWG Cascade Multi v2.0 — генератор AmneziaWG 2.0 параметров
# Стиль идентичен тому что генерирует приложение Amnezia Client v2.0.
#
# Источаем (source) из setup.sh / setup-exit.sh.
# Выставляет переменные:
#   JC, JMIN, JMAX            — junk packets (fixed 5/10/50, как у amnezia)
#   S1, S2, S3, S4            — handshake padding RANDOMIZED per install
#   H1-H4                     — RANGED headers формат "min-max"
#   I1                        — единственный CPS decoy (DNS-iCloud lookalike)
#   AWG2_PARAMS_VERSION       — "2.0-amnezia-style"
#
# В отличие от Amnezia client app, I2-I5 НЕ пишем (awg setconf падает на
# пустых значениях).
# =============================================================================

AWG2_PARAMS_VERSION="2.0-amnezia-style"

# Junk packets — Jc варьируется 4..6 (наблюдено в реальных amnezia v2.0 конфигах)
JMIN=10; JMAX=50

# ─── Random helpers ──────────────────────────────────────────────────────────
_gen_uint32() {
    od -An -N4 -tu4 /dev/urandom | tr -d ' \n'
}

# random в диапазоне [min, max]
_rand_in() {
    local min=$1 max=$2
    local span=$((max - min + 1))
    local rnd=$(_gen_uint32)
    echo $((min + (rnd % span)))
}

# ─── Jc, S1-S4: random (как у amnezia client v2.0) ──────────────────────────
# Анализ 8 реальных конфигов amnezia v2.0:
#   Jc: 4..6
#   S1: 51..132 — широкий
#   S2: 19..145 — широкий, может быть < или > S1
#   S3: 17..53
#   S4: 2..16 — маленькие числа

JC=$(_rand_in 4 6)
S1=$(_rand_in 30 200)
S2=$(_rand_in 15 200)
S3=$(_rand_in 10 80)
S4=$(_rand_in 1  30)
# Минимальный sanity check — S1+56 не должно равняться S2 (требование amnezia)
[ $((S1 + 56)) -eq "$S2" ] && S2=$((S2 + 1))

# ─── H1-H4: ranged headers (sort-and-pair) ──────────────────────────────────
# КРИТИЧЕСКОЕ ПРАВИЛО amneziawg: H1.max < H2.min < H2.max < H3.min < H3.max < H4.min
# (strict monotonic increase, без overlap — иначе awg setconf падает).
#
# Подход: берём 8 рандомных точек в [400M, 2.147B], сортируем по возрастанию,
# группируем в пары (H1, H2, H3, H4). Это даёт естественное разнообразие
# которое наблюдается в реальных amnezia конфигах (где H1.min может быть как
# 400M так и 2.0B, ratio max/min разный, gaps между ranges разные).
#
# Защита: гарантируем минимальный gap = 1000 между парами чтобы strict-less-than
# работало при ну очень неудачной шутке RNG.

INT_MAX_SAFE=2147483600   # с зазором от 2147483647 для безопасности парсера
MIN_BOUND=400000000        # H1.min не ниже 400M (как в реальных конфигах)

_points=()
for _i in 1 2 3 4 5 6 7 8; do
    _points+=("$(_rand_in $MIN_BOUND $INT_MAX_SAFE)")
done

# Сортируем по возрастанию через builtin sort
_sorted=()
while IFS= read -r _p; do
    _sorted+=("$_p")
done < <(printf '%s\n' "${_points[@]}" | sort -n)

# Гарантируем монотонность с минимальным gap=1000 (нужно когда RNG выдал дубликаты)
for ((_i=1; _i<8; _i++)); do
    if [ "${_sorted[_i]}" -le "${_sorted[_i-1]}" ]; then
        _sorted[_i]=$(( ${_sorted[_i-1]} + 1000 ))
    fi
done

# Cap последней точки если ушли за INT_MAX_SAFE
[ "${_sorted[7]}" -gt "$INT_MAX_SAFE" ] && _sorted[7]=$INT_MAX_SAFE

H1="${_sorted[0]}-${_sorted[1]}"
H2="${_sorted[2]}-${_sorted[3]}"
H3="${_sorted[4]}-${_sorted[5]}"
H4="${_sorted[6]}-${_sorted[7]}"

# ─── I1: единственный CPS decoy (DNS-iCloud lookalike) ──────────────────────
# Amnezia client всегда использует именно этот шаблон с <r 2> prefix.
# I2-I5 у Amnezia пустые. Мы их НЕ пишем (awg setconf не любит пустые).
I1="<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"

# ─── Helper: запись блока параметров в awg-config ───────────────────────────
emit_v2_params_block() {
    echo "Jc = $JC"
    echo "Jmin = $JMIN"
    echo "Jmax = $JMAX"
    echo "S1 = $S1"
    echo "S2 = $S2"
    echo "S3 = $S3"
    echo "S4 = $S4"
    echo "H1 = $H1"
    echo "H2 = $H2"
    echo "H3 = $H3"
    echo "H4 = $H4"
    echo "I1 = $I1"
}
