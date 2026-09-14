#!/usr/bin/env python3
"""
Проверка того, что продублированные в разных файлах блоки не разошлись.

Заведено по следам реальных расхождений в этом проекте, а не «на всякий случай».
Каждая проверка ниже соответствует дефекту, который уже случался на живых нодах:

  1. Канон sudoers существует в ДВУХ местах — setup.sh создаёт файл, а
     awg-cascade-sync.sh приводит его к своему варианту и стирает всё лишнее.
     Правка только в одном из них живёт ровно до первого синка.

  2. Блок обновления пакетов образа продублирован в setup.sh и setup-exit.sh.

  3. Комплект provisioning-скриптов кладут в $BOT_DIR/scripts оба файла. Уже
     расходился: fail2ban был в sync.sh и отсутствовал в setup.sh, из-за чего
     свежепоставленная RU отдавала на новый exit комплект без fail2ban.

Запуск: python3 .github/check-duplication.py  (из корня репозитория)
Код 0 — всё сошлось, 1 — есть расхождение.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def fail(msg: str) -> None:
    # ::error:: — аннотация GitHub Actions; в локальном запуске просто текст.
    print("::error::" + msg)


def sudoers_rules(text: str) -> list[str]:
    return sorted(
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("$BOT_USER ALL=")
    )


def upgrade_block(text: str) -> str | None:
    m = re.search(
        r"# ─── Привести образ к актуальному состоянию.*?\nfi\n", text, re.S
    )
    return m.group(0) if m else None


def main() -> int:
    bad = 0
    setup = read("setup.sh")
    setup_exit = read("setup-exit.sh")
    sync = read("watchdog/awg-cascade-sync.sh")

    # ─── 1. sudoers ──────────────────────────────────────────────────────────
    a, b = sudoers_rules(setup), sudoers_rules(sync)
    if a != b:
        fail("канон sudoers в setup.sh и awg-cascade-sync.sh разошёлся")
        print("  setup.sh:", a)
        print("  sync.sh: ", b)
        bad = 1
    elif not a:
        fail("канон sudoers не найден ни в одном из файлов — проверка ослепла")
        bad = 1

    # ─── 2. блок обновления пакетов ──────────────────────────────────────────
    x, y = upgrade_block(setup), upgrade_block(setup_exit)
    if x is None or y is None:
        missing = [n for n, v in (("setup.sh", x), ("setup-exit.sh", y)) if v is None]
        fail("блок обновления пакетов образа не найден в: " + ", ".join(missing))
        bad = 1
    elif x != y:
        fail("блок обновления пакетов в setup.sh и setup-exit.sh разошёлся")
        bad = 1

    # ─── 3. комплект provisioning ────────────────────────────────────────────
    want = {
        "setup-exit.sh",
        "awg2-params.sh",
        "awg-cascade-exit-warp.sh",
        "awg-cascade-ssh-harden.sh",
        "awg-cascade-fail2ban.sh",
    }
    for name, text in (("setup.sh", setup), ("awg-cascade-sync.sh", sync)):
        missing = sorted(n for n in want if "/scripts/" + n not in text)
        if missing:
            fail("%s не кладёт в $BOT_DIR/scripts: %s" % (name, ", ".join(missing)))
            bad = 1

    if not bad:
        print("дубли сошлись: sudoers, блок apt upgrade, комплект provisioning")
    return bad


if __name__ == "__main__":
    sys.exit(main())
