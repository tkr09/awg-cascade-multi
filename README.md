# AWG Cascade Multi

Полноценный multi-exit AmneziaWG-каскад с балансировкой по пингу, kill-switch,
watchdog, и Telegram-ботом для управления.

## Архитектура

```
Клиент (amnezia-client) ──AWG (obfuscated)──> RU (entry)
                                                 │
                              ┌─── awg1 ─AWG──> NL exit ──→ интернет
                              ├─── awg2 ─AWG──> PL exit ──→ интернет (или WARP)
                              └─── awgN ─AWG──> ... ──→ интернет
                       ECMP по пингу (веса автоматические)
```

## Ключевые свойства

- **Multi-exit с failover**: один exit умер → трафик ECMP-балансится по живым
- **Веса по пингу**: `weight = round(min_ping_alive / this_ping × 10)`
- **Kill-switch by design**: `FORWARD -i awg0 ! -o awg+ -j DROP` — клиенты не утекают в eth0
- **Watchdog** на systemd: ping 5s, hysteresis 3/2, reconnect aged handshake, пересчёт весов 5мин
- **Опциональный WARP** per-exit (toggle через бот, с GeoIP)
- **Per-peer policy**: pin клиента на конкретный exit или Auto (ECMP)
- **Telegram bot** + **ntfy.sh** alerts через emergency eth0

## Версия

**v1.0-default-preset** — обфускация AmneziaWG Default preset (Jc/Jmin/Jmax + S1-S4 + H1-H4 + I1).
Использует `amneziawg-tools v1.0.20210914` из ppa:amnezia/ppa.

## Установка

### RU (entry)

```bash
curl -fsSL https://raw.githubusercontent.com/tkr09/awg-cascade-multi/main/setup.sh | sudo bash
```

Скрипт спросит:
- Public IP / UDP port / client subnet
- Telegram bot token + chat_id
- ntfy topic
- Имя первого peer'а

### Exits

Через бот в Telegram: `🌍 Exits` → `➕ Добавить exit` → IP + ssh-auth.

## Структура репо

```
setup.sh                        # установка на RU
setup-exit.sh                   # установка на exit (вызывается ботом)
exit-side/
  awg-cascade-exit-warp.sh      # WARP toggle helper для exit
watchdog/
  awg-cascade-watchdog.sh       # monitoring + ECMP routing
  awg-cascade-watchdog-postboot.sh
  awg-cascade-route.sh          # перестройка ECMP table 100
  awg-cascade-iprule.sh         # ip rule (uidrange + fwmark)
  awg-cascade-peer-add.sh       # создать peer (от бота)
  awg-cascade-peer-remove.sh
  awg-cascade-exit-add-ru.sh    # подцепить новый exit (от бота)
  awg-cascade-exit-remove.sh
bot/
  bot.py
  common.py
  handlers/
    main_menu.py
    exits.py
    peers.py
    settings.py
systemd/
  awg-cascade-watchdog.service
  awg-cascade-postboot.service
  awg-cascade-bot.service
```

## Routing

| Кто | Куда | Через | Зачем |
|---|---|---|---|
| Клиенты awg0 | интернет | ECMP awg1..N (table 100, L4 hash) | Балансировка |
| Pinned peer | конкретный exit | table 100+idx | По выбору юзера |
| Бот → SSH:22 | direct eth0 | priority 998 | Обход NL-блокировки :22 |
| Бот → Telegram | через exits | uidrange → table 100 | RU IP не светится |
| Watchdog → ntfy.sh | direct eth0 | `--interface eth0` | Алертит даже когда каскад down |
| WARP on exit | warp0 | iptables MARK 0x10 → table 200 | Маскировка через Cloudflare |

## Команды на RU

```bash
systemctl status awg-cascade-watchdog awg-cascade-bot
journalctl -u awg-cascade-watchdog -f
journalctl -u awg-cascade-bot -f
jq . /etc/awg-cascade/state.json
awg show
ip rule
ip route show table 100
```

## License

MIT
