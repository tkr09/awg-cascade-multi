#!/usr/bin/env python3
"""Two-sided AWG parameter changes: prepare, apply, verify, commit or rollback."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location('control', Path(__file__).with_name('awg-cascade-control.py'))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
BASE = Path('/etc/awg-cascade')
WG = Path('/etc/amnezia/amneziawg')
JOURNAL = Path('/var/lib/awg-cascade/awg3-pending.json')

# This constant code is delivered over authenticated SSH stdin with JSON data.
# No key, PSK or header-protection material appears in a process argument.
REMOTE = r'''
import base64, fcntl, json, os, pathlib, re, subprocess, tempfile
p = PAYLOAD
iface = p['iface']
if not re.fullmatch(r'(awg[1-9][0-9]?|awg-in(?:-[2-9]|-[1-9][0-9])?)', iface): raise ValueError('iface')
operation = p['operation']
if not re.fullmatch(r'[a-f0-9]{32}', operation): raise ValueError('operation')
root = pathlib.Path('/var/lib/awg-cascade/awg3')
root.mkdir(parents=True, exist_ok=True, mode=0o700)
lock = open(root / (iface + '.lock'), 'a')
fcntl.flock(lock, fcntl.LOCK_EX)
conf = pathlib.Path('/etc/amnezia/amneziawg') / (iface + '.conf')
journal = root / (iface + '.json')
def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30).stdout
def write(path, text):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f: f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
        d = os.open(path.parent, os.O_DIRECTORY)
        try: os.fsync(d)
        finally: os.close(d)
    finally:
        if os.path.exists(name): os.unlink(name)
def load():
    saved = json.loads(journal.read_text())
    if saved['operation'] != operation: raise ValueError('other pending operation')
    return saved
mode = p['mode']
if mode == 'prepare':
    if journal.exists(): load()
    else: write(journal, json.dumps({'operation': operation, 'conf': conf.read_text(), 'runtime': run('awg','showconf',iface)}))
elif mode == 'apply':
    saved = load()
    allowed = {'HeaderProtectionKey','ContentPaddingAddition','RekeyAfterTime','RekeyTimeout','RejectAfterTime','KeepaliveTimeout','MaxHandshakeAttempts','S1','S2','S3','S4'}
    changes = p['changes']
    if not set(changes) <= allowed: raise ValueError('unknown parameter')
    for key, value in changes.items():
        if value is None: continue
        if key == 'HeaderProtectionKey':
            if len(base64.b64decode(value, validate=True)) != 32: raise ValueError('key')
        elif not re.fullmatch(r'[0-9]+(?:-[0-9]+)?', str(value)): raise ValueError('value')
    lines = [line for line in saved['conf'].splitlines() if line.partition('=')[0].strip() not in changes]
    pos = next(i for i,line in enumerate(lines) if line.strip() == '[Interface]') + 1
    lines[pos:pos] = [key + ' = ' + str(value) for key,value in changes.items() if value is not None]
    write(conf, '\n'.join(lines) + '\n')
    if p['restart']:
        run('awg-quick','down',iface); run('awg-quick','up',iface)
    else:
        stripped = run('awg-quick','strip',iface)
        fd,name = tempfile.mkstemp(dir=root)
        try:
            with os.fdopen(fd,'w') as f: f.write(stripped)
            run('awg','syncconf',iface,name)
        finally: os.unlink(name)
    runtime = run('awg','showconf',iface)
    if changes.get('HeaderProtectionKey') and 'HeaderProtectionKey = ' + changes['HeaderProtectionKey'] not in runtime:
        raise ValueError('header protection not active')
elif mode == 'rollback':
    if journal.exists():
        saved = load(); write(conf,saved['conf'])
        # Restart is needed to remove parameters introduced by the failed change.
        if subprocess.run(['ip','link','show','dev',iface],capture_output=True).returncode == 0: run('awg-quick','down',iface)
        run('awg-quick','up',iface)
        journal.unlink()
elif mode == 'commit':
    if journal.exists(): load(); journal.unlink()
else: raise ValueError('mode')
print('{"ok":true}')
'''


def call(node, mode, remote):
    payload = {'iface': node['remote_iface'] if remote else node['iface'], 'operation': node['operation'],
               'mode': mode, 'changes': node['changes'], 'restart': node['restart']}
    if remote:
        args = ['ssh', '-F', '/dev/null', '-i', str(BASE / 'ssh/id_ed25519'), '-o', 'IdentitiesOnly=yes',
                '-o', 'IdentityAgent=none', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'UserKnownHostsFile=' + str(BASE / 'ssh/known_hosts'), '-o', 'ConnectTimeout=10',
                'root@' + node['ip'], "python3 -c 'import sys,json; p=json.load(sys.stdin); exec(p[\"source\"],{\"PAYLOAD\":p[\"payload\"]})'"]
        data = json.dumps({'source': REMOTE, 'payload': payload})
    else:
        args = ['/usr/bin/python3', '-I', '-c', 'import sys,json; p=json.load(sys.stdin); exec(p["source"],{"PAYLOAD":p["payload"]})']
        data = json.dumps({'source': REMOTE, 'payload': payload})
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=90)
    if result.returncode or not json.loads(result.stdout).get('ok'):
        raise RuntimeError(('exit' if remote else 'RU') + ': ' + mode + ' failed')


def iface_identity(iface):
    """
    Публичный ключ интерфейса — устойчивый признак «это тот же туннель».

    Возвращает ПАРУ (источник, ключ): 'runtime', 'conf' либо (None, '') —
    идентичность установить не удалось.

    Источников два намеренно. Первая версия этой проверки спрашивала только
    работающий интерфейс и при любой ошибке отдавала пустую строку — а вызывающая
    сторона считала пустоту доказательством того, что туннель ПЕРЕСОЗДАН.
    Получалось наоборот: интерфейс отсутствовал именно потому, что операция
    не доигралась (`awg-quick down` прошёл, `up` упал), и восстановление
    отменялось ровно тогда, когда было нужнее всего (R02 аудита v2.8.5).

    Конфиг годится как второй источник, потому что `PrivateKey` не входит в
    список изменяемых параметров: наша собственная правка его не трогает, а вот
    переиспользование индекса под другой exit заменяет файл целиком вместе с
    ключом — то есть подмену туннеля этот источник всё так же ловит.
    """
    result = subprocess.run(['awg','show',iface,'public-key'],capture_output=True,text=True,timeout=10)
    key = result.stdout.strip()
    if result.returncode == 0 and key:
        return 'runtime', key
    try: lines = (WG / (iface + '.conf')).read_text().splitlines()
    except OSError: return None, ''
    for line in lines:
        name, sep, value = line.partition('=')
        if not sep or name.strip() != 'PrivateKey': continue
        derived = subprocess.run(['awg','pubkey'],input=value.strip(),capture_output=True,text=True,timeout=10)
        if derived.returncode == 0 and derived.stdout.strip():
            return 'conf', derived.stdout.strip()
        break
    return None, ''


def recovery():
    """
    Доиграть прерванную операцию. Возвращает 'done', 'stale' или 'unknown'.

    Исход обязан быть различим вызывающей стороной: 'stale' и 'unknown' значат,
    что на ДАЛЬНЕЙ стороне могли остаться незавершённые изменения, и объявлять
    операцию восстановленной нельзя.
    """
    if not JOURNAL.exists(): return 'done'
    node = json.loads(JOURNAL.read_text())
    # Сверяем ИДЕНТИЧНОСТЬ, а не имя интерфейса.
    #
    # Индексы exit'ов переиспользуются: awg2 после удаления одного exit'а и
    # добавления другого — это уже иной туннель с другими ключами. Восстановление
    # по имени накатило бы сохранённый конфиг поверх чужого интерфейса и
    # разрушило бы связь с новым exit'ом (A02 аудита v2.7.6).
    #
    # Но «ключ не совпал» и «ключ не удалось узнать» — РАЗНЫЕ исходы, и раньше
    # они сходились в один (R02 аудита v2.8.5). Отсюда три ветки, а не две.
    expected = node.get('iface_pubkey')
    source, current = iface_identity(node['iface'])
    if source is None:
        # Ни интерфейса, ни читаемого конфига. Журнал НЕ откладываем: он и есть
        # то, что блокирует дальнейшие мутации состава exit'ов, а операция
        # осталась недоигранной. Следующий вызов повторит попытку.
        print('awg3: идентичность %s не установлена (нет ни интерфейса, ни конфига) — '
              'журнал оставляю, восстановление не выполнено' % node['iface'], file=sys.stderr)
        return 'unknown'
    if not expected:
        # Журнал старого формата. Проверять не с чем, но и промолчать нельзя.
        print('awg3: журнал без iface_pubkey — восстанавливаю по имени %s, '
              'подмену туннеля здесь проверить нечем' % node['iface'], file=sys.stderr)
    elif current != expected:
        # Журнал при этом не удаляем молча: откладываем в сторону как улику и
        # перестаём блокировать им дальнейшую работу — операция, которую он
        # описывает, применять уже не к чему.
        stale = JOURNAL.with_name('awg3-stale-%d.json' % int(time.time()))
        JOURNAL.rename(stale)
        print('awg3: журнал описывает другой туннель (%s пересоздан, ключ взят из %s) — '
              'не трогаю, сохранён как %s. На %s могли остаться незавершённые '
              'изменения — разберите вручную' % (node['iface'], source, stale, node['ip']),
              file=sys.stderr)
        return 'stale'
    action = 'commit' if node.get('committed') else 'rollback'
    # If SSH fails the journal stays. A subsequent command retries recovery.
    call(node, action, True)
    call(node, action, False)
    JOURNAL.unlink()
    return 'done'


def main():
    if os.geteuid() != 0: raise PermissionError('root required')
    iface, action = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'status'
    if iface != 'all': c.identifier(iface, c.EXIT)
    if action not in ('status', 'on', 'off', 'reroll-s', 'recover'): raise ValueError('action')
    state = c.validate_state(json.loads((BASE / 'state.json').read_text()))
    if action == 'status':
        for node in state['exits']:
            if iface in ('all', node['interface']):
                result = subprocess.run(['awg','show',node['interface'],'latest-handshakes'],capture_output=True,text=True,timeout=10)
                print(node['interface'], node['name'], 'pending=' + str(JOURNAL.exists()), result.stdout.strip())
        return
    if iface == 'all': raise ValueError('one interface per mutation')
    with c.locked('/run/awg-cascade-mutation.lock'), c.locked('/run/awg-cascade-awg3.lock'):
        outcome = recovery()
        if action == 'recover':
            print(json.dumps({'ok': outcome == 'done', 'recovery': outcome}))
            if outcome != 'done': sys.exit(1)
            return
        # 'stale' пропускаем намеренно: журнал отложен, блокировать им нечего.
        # А вот 'unknown' — непроигранная операция, и записывать поверх неё
        # новый журнал нельзя: это стёрло бы единственный след незавершённого.
        if outcome == 'unknown': raise RuntimeError('есть незавершённая операция — сначала `recover`')
        node = next(n for n in state['exits'] if n['interface'] == iface)
        cfg = (WG / (iface + '.conf')).read_text()
        params = {l.partition('=')[0].strip(): l.partition('=')[2].strip() for l in cfg.splitlines() if '=' in l}
        changes = {}
        extras = ['HeaderProtectionKey','ContentPaddingAddition','RekeyAfterTime','RekeyTimeout','RejectAfterTime','KeepaliveTimeout','MaxHandshakeAttempts']
        if action == 'off': changes = dict.fromkeys(extras)
        if action in ('on','reroll-s'):
            for key in ('S1','S2','S3','S4'):
                if int(params[key]) < 12 or action == 'reroll-s':
                    if action == 'on' and '--fix-s' not in sys.argv[3:]: raise ValueError('S below 12; use --fix-s')
                    changes[key] = 12 + secrets.randbelow(29)
        if action == 'on':
            import base64
            changes.update(dict(zip(extras, [base64.b64encode(secrets.token_bytes(32)).decode(), '50-100','100-140','4-7','170-200','8-13','15-20'])))
        # Идентичность фиксируем ДО начала операции. Если установить её нечем,
        # операцию не начинаем вовсе: без неё восстановление после сбоя не
        # сможет отличить «тот же туннель» от «на этом индексе теперь другой
        # exit» и будет вынуждено гадать.
        source, pubkey = iface_identity(iface)
        if source is None: raise RuntimeError('идентичность ' + iface + ' не установлена — операцию не начинаю')
        record = {'operation': secrets.token_hex(16), 'iface': iface, 'remote_iface': node.get('exit_iface','awg-in'),
                  'ip': node['ip'], 'changes': changes, 'restart': action == 'off',
                  'iface_pubkey': pubkey}
        JOURNAL.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        c.atomic_write(JOURNAL,json.dumps(record),mode=0o600)
        try:
            call(record,'prepare',False); call(record,'prepare',True)
            before = subprocess.check_output(['awg','show',iface,'latest-handshakes'],text=True,timeout=10)
            previous = max([int(l.split()[1]) for l in before.splitlines()] or [0])
            call(record,'apply',True); call(record,'apply',False)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                data = subprocess.run(['ping','-I',iface,'-c','1','-W','2',node['exit_tunnel_ip']],capture_output=True,timeout=5)
                hs = subprocess.check_output(['awg','show',iface,'latest-handshakes'],text=True,timeout=10)
                latest = max([int(l.split()[1]) for l in hs.splitlines()] or [0])
                if data.returncode == 0 and latest > previous: break
                time.sleep(2)
            else: raise TimeoutError('no fresh handshake and data-plane response')
            record['committed'] = True
            c.atomic_write(JOURNAL,json.dumps(record),mode=0o600)
            # Исход commit'а больше не игнорируется: журнал, оставшийся после
            # него, значит, что дальняя сторона не подтвердила завершение.
            outcome = recovery()
            if outcome != 'done': raise RuntimeError('commit не завершён (' + outcome + ') — журнал остался')
            print(json.dumps({'ok':True,'interface':iface,'mode':action,'traffic_verified':True}))
        except BaseException:
            if recovery() != 'done':
                print('awg3: автоматическое восстановление не завершено — см. сообщение выше',file=sys.stderr)
            raise


if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('AWG change failed: ' + type(exc).__name__ + '; pending journal retained if recovery could not finish',file=sys.stderr)
        sys.exit(1)
