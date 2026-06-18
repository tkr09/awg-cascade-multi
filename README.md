# AWG Cascade Multi

Полноценный multi-exit AmneziaWG **2.0** каскад с балансировкой по пингу,
kill-switch, watchdog, drift-guard и Telegram-ботом для управления.
Поддерживает несколько RU-точек входа на общих exit-серверах (shared exits).

## Архитектура

```
Клиент (amnezia-client) ──AWG 2.0 (obfuscated)──> RU (entry, awg0)
                                                     │
                                  ┌─── awg1 ─AWG──> NL exit ──→ интернет
                                  ├─── awg2 ─AWG──> FI exit ──→ интернет (или WARP)
                                  └─── awgN ─AWG──> PL exit ──→ ...
                           ECMP по пингу (веса автоматические)
```

Несколько RU могут делить одни exit-серверы: на exit поднимается `awg-in`
(первый RU) + `awg-in-2`/`-N` (остальные), каждый со своим портом и /30-туннелем.
WARP на shared-exit управляется per-interface (RU не мешают друг другу).

## Ключевые свойства

- **AmneziaWG 2.0 обфускация**: Jc/Jmin/Jmax + random S1-S4 + ranged H1-H4 + I1
  (CPS-decoy под DNS-ответ iCloud). Параметры уникальны на установку.
- **Multi-exit с failover**: exit умер → трафик ECMP-балансится по живым.
- **Веса по пингу**: `weight = round(min_ping_alive / this_ping × 10)`.
- **Kill-switch by design**: `FORWARD -i awg0 ! -o awg+ -j DROP` — клиенты не утекают в eth0.
- **Watchdog** (systemd): ping 10s, hysteresis 3/2, reconnect зависшего handshake,
  пересчёт весов 5мин, self-heal ip-rules, сэмплинг трафика per-peer.
- **Опциональный WARP** per-exit (toggle через бот, с GeoIP), multi-RU safe.
- **Per-peer policy**: pin клиента на конкретный exit или Auto (ECMP);
  per-peer inter-client LAN-доступ (whitelist src→dst, иначе default-deny).
- **Telegram bot**: peers (add/remove/rotate/QR/.conf/pin/LAN), exits (add/WARP/ping),
  🩺 диагностика ноды, 📈 графики трафика (unicode-спарклайн).
- **Алертинг** через ntfy.sh (emergency egress по eth0): exit down/up, bot-egress,
  disk/RAM/load, SSH-login (pam_exec).
- **Drift-guard**: `awg-cascade-sync.sh` идемпотентно приводит код/конфиг ноды
  к git-тегу (re-deploy скриптов/юнитов/sudoers + вычистка орфанов), version-stamp.

## Версия

**v2.0.25** — AmneziaWG 2.0 (amnezia-client-совместимый формат: Jc/Jmin/Jmax +
S1-S4 + ranged H1-H4 + I1). Ставит `amneziawg` + `amneziawg-dkms` из `ppa:amnezia/ppa`.

История значимых изменений — в git-тегах (`git tag`), каждый тег с описанием.

## Установка

### RU (entry)

```bash
curl -fsSL https://raw.githubusercontent.com/tkr09/awg-cascade-multi/main/install.sh \
  | sudo REF=v2.0.25 bash
```

`install.sh` клонирует репо на нужном теге и запускает `setup.sh`, который спросит:
Public IP / UDP port / client subnet, Telegram bot token + chat_id, ntfy topic,
имя первого peer'а. Повторный запуск на уже настроенной ноде безопасен —
Phase 5 (серверный ключ/awg0.conf) под гардом идемпотентности.

### Exits

Через бот: `🌍 Exits` → `➕ Добавить exit` → IP + ssh-auth (пароль root или
заранее добавленный ключ). Или CLI на RU: `awg-cascade-bootstrap-exit.sh <IP> <NAME>`.

## Обновление живых нод

**Только через drift-guard, НЕ повторным `setup.sh`:**

```bash
sudo awg-cascade-sync.sh --check v2.0.25   # показать дрейф
sudo awg-cascade-sync.sh v2.0.25           # привести ноду к тегу
```

(При смене логики самого `sync.sh` нужны два прогона: 1-й ставит новый sync, 2-й им работает.)

## Структура репо

```
install.sh            # bootstrap: clone репо на REF → exec setup.sh
setup.sh              # установка на RU (entry)
setup-exit.sh         # установка на exit (вызывается ботом/bootstrap)
awg2-params.sh        # генератор AWG 2.0 параметров (S1-S4, ranged H1-H4, I1)
install-unattended.sh # включить unattended-upgrades на существующей ноде
exit-side/
  awg-cascade-exit-warp.sh      # WARP toggle (interface-aware, multi-RU safe)
watchdog/
  awg-cascade-watchdog.sh           # monitoring + ECMP + self-heal + traffic sampling
  awg-cascade-watchdog-postboot.sh  # postboot verify + recovery
  awg-cascade-iprule.sh             # ip rule (uidrange + fwmark → table 100)
  awg-cascade-interclient.sh        # per-peer inter-client LAN whitelist
  awg-cascade-peer-add.sh / -remove.sh / -rotate.sh
  awg-cascade-exit-add-ru.sh / -remove.sh
  awg-cascade-bootstrap-exit.sh     # CLI: первый exit без живого бота
  awg-cascade-selftest.sh           # активная диагностика ноды (для 🩺 в боте)
  awg-cascade-sync.sh               # drift-guard / re-deploy из репо
  awg-cascade-traffic-sample.sh     # сэмплинг трафика per-peer в CSV
  awg-cascade-alert.sh              # ntfy + cooldown/дедуп
  awg-cascade-ssh-alert.sh          # SSH-login алерт (pam_exec)
  awg-cascade-backup.sh             # бэкап /etc/awg-cascade + ключи в tar.gz
bot/
  bot.py                # aiogram polling + resilience (retry/backoff)
  common.py             # config/state IO, SSH, форматтеры, helpers
  requirements.txt
  handlers/
    main_menu.py        # статус + 🩺 диагностика
    exits.py            # exits: add/WARP/ping/note/rename/remove
    peers.py            # peers: add/remove/rotate/QR/.conf/pin/LAN/📈 трафик
    settings.py
systemd/
  awg-cascade-watchdog.service / -bot.service / -postboot.service
  awg-cascade-alert@.service       # OnFailure-алерты
  awg-cascade.logrotate
```

(Юниты `awg-cascade-iptables.service` и `-iprule.service` генерируются `setup.sh` inline.)

## Routing

| Кто | Куда | Через | Зачем |
|---|---|---|---|
| Клиенты awg0 | интернет | ECMP awg1..N (table 100, L4 hash) | Балансировка |
| Pinned peer | конкретный exit | table 100+idx | По выбору юзера |
| Peer↔peer (LAN) | внутр. устройства | RETURN до MARK (whitelist) | Доступ к роутерам/админкам |
| Бот → SSH:22 | direct eth0 | priority 998 | Обход блокировки :22 у хостеров |
| Бот → Telegram | через exits | uidrange → table 100 | RU IP не светится |
| Watchdog → ntfy.sh | direct eth0 | `--interface eth0` | Алертит даже когда каскад down |
| WARP on exit | warp0 | iptables MARK → table 200 | Маскировка через Cloudflare |

## Команды на RU

```bash
systemctl status awg-cascade-watchdog awg-cascade-bot
journalctl -u awg-cascade-watchdog -f
awg-cascade-selftest.sh            # быстрая диагностика всей ноды
awg-cascade-sync.sh --check        # проверить дрейф от репо
jq . /etc/awg-cascade/state.json
awg show; ip rule; ip route show table 100
```

## License

MIT
