#!/bin/bash
# =============================================================================
# AWG Cascade Multi — Bootstrap installer
#
# Скачивает репо в /opt/awg-cascade-src и запускает setup.sh оттуда (нужно для
# доступа к bot/, watchdog/, systemd/ файлам которые setup.sh деплоит).
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/tkr09/awg-cascade-multi/main/install.sh | sudo bash
#
# Опции через env:
#   REF=v2.3.1            — конкретная версия (по умолчанию — последний тег)
#   REPO_URL=...          — альтернативный fork
#   SRC=/opt/...          — где разместить исходники (по умолчанию /opt/awg-cascade-src)
# =============================================================================

set -e

[ "$EUID" -ne 0 ] && { echo "Запусти от root (sudo)"; exit 1; }

REPO_URL="${REPO_URL:-https://github.com/tkr09/awg-cascade-multi.git}"
# По умолчанию — ПОСЛЕДНИЙ ТЕГ, а не main.
#
# Боевую ноду нельзя ставить с ветки: в main лежит код, который ещё не проходил
# релиз, и `curl | bash` без REF молча ставил именно его. Тег — это то, что
# раскатано на действующих нодах и проверено. main остаётся доступен явно:
# REF=main для отладки.
REF="${REF:-}"
SRC="${SRC:-/opt/awg-cascade-src}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   AWG Cascade Multi — bootstrap                       ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Репо:     ${BOLD}$REPO_URL${NC}"
echo -e "  Версия:   ${BOLD}${REF:-последний тег}${NC}"
echo -e "  Куда:     ${BOLD}$SRC${NC}"
echo ""

# git нужен для clone
if ! command -v git >/dev/null 2>&1; then
    echo -e "${YELLOW}[i]${NC} git не найден — ставлю..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl ca-certificates >/dev/null
fi

# Клон или обновление
if [ -d "$SRC/.git" ]; then
    echo -e "${YELLOW}[i]${NC} Источник уже есть в $SRC — обновляю..."
    git -C "$SRC" fetch --tags --quiet
else
    echo -e "${YELLOW}[i]${NC} Клонирую репо..."
    git clone --quiet "$REPO_URL" "$SRC"
fi

# Последний тег определяем ПОСЛЕ клона: до него репозитория ещё нет.
if [ -z "$REF" ]; then
    REF=$(git -C "$SRC" describe --tags --abbrev=0 2>/dev/null || echo main)
    echo -e "${YELLOW}[i]${NC} REF не задан — беру последний тег: ${BOLD}$REF${NC}"
fi
git -C "$SRC" checkout --quiet "$REF" || {
    echo -e "${RED}[✗]${NC} версия '$REF' не найдена в репозитории"; exit 1; }
# Если REF — ветка, её ещё надо подтянуть. Для тега pull не нужен и вреден.
if git -C "$SRC" symbolic-ref -q HEAD >/dev/null 2>&1; then
    git -C "$SRC" pull --ff-only --quiet 2>/dev/null || true
fi

# Permissions для исполняемых скриптов
chmod +x "$SRC/setup.sh" "$SRC/setup-exit.sh" 2>/dev/null || true
chmod +x "$SRC"/watchdog/*.sh 2>/dev/null || true
chmod +x "$SRC/awg2-params.sh" 2>/dev/null || true

CURRENT_REF=$(git -C "$SRC" describe --tags --always 2>/dev/null || echo "$REF")
echo -e "${GREEN}[✓]${NC} Исходники готовы (версия: ${BOLD}$CURRENT_REF${NC})"
echo ""
echo -e "${BOLD}>>> Запускаю setup.sh${NC}"
echo ""

exec bash "$SRC/setup.sh"
