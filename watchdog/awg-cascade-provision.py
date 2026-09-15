#!/usr/bin/env python3
"""One resumable provisioning engine for CLI and bot; SSH key must already work."""
import hashlib
import importlib.util
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import time

spec=importlib.util.spec_from_file_location('control',Path(__file__).with_name('awg-cascade-control.py'))
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
BASE=Path('/etc/awg-cascade')
SCRIPTS=Path('/opt/awg-cascade-bot/scripts')


def run(args, data=None, timeout=45):
    result=subprocess.run(args,input=data,capture_output=True,timeout=timeout)
    if result.returncode: raise RuntimeError('operation failed: '+Path(args[0]).name)
    return result.stdout.decode().strip()


def exit_reboot(ssh, record):
    """
    Перезагрузить свежепровизиненный exit в новое ядро.

    setup-exit.sh привёл образ в порядок вместе с ядром, но работает exit до сих
    пор на старом. Перезагрузка делается здесь, а не внутри setup-exit.sh: тот
    запускается по SSH и обязан вернуть JSON — ребут оборвал бы вывод, и
    успешный провижининг выглядел бы как упавший.

    Ограничения — по разбору F21 аудита v2.5.2, каждое по своему сценарию:

      • SHARED EXIT НЕ ТРОГАЕМ. На сервере может жить туннель другой RU с живыми
        клиентами. «Клиентов ещё нет» верно только для нашего нового туннеля.
      • Цель загрузки проверяется на самом exit'е (reboot.py): installed-модуль
        именно для того ядра, которое поднимет grub.
      • Возвращение — по СМЕНЕ boot_id, а не по «SSH отвечает»: отвечать может и
        не перезагрузившийся сервер.
      • Восстановление туннеля — по handshake'у НОВЕЕ момента перезагрузки.
        Старый handshake остаётся в выводе awg и подтвердил бы восстановление,
        которого не было.

    Возвращает строку статуса; она попадает в JSON результата. Неудача меняет
    результат операции, а не прячется в предупреждении.
    """
    if run(ssh+['test -f /var/run/reboot-required && echo yes || echo no'])!='yes':
        return 'not-needed'
    if int(run(ssh+['ls -1 /etc/amnezia/amneziawg/awg-in*.conf 2>/dev/null | wc -l']) or '0')>1:
        return 'skipped: shared exit, перезагрузка только по согласованию всех RU'
    try:
        target=json.loads(run(ssh+['python3 -I /usr/local/sbin/awg-cascade-reboot.py']))['boot_kernel']
    except Exception:
        return 'skipped: цель загрузки не подтверждена, перезагрузка запрещена'
    before=run(ssh+['cat /proc/sys/kernel/random/boot_id'])
    moment=int(time.time())
    subprocess.run(ssh+['systemctl reboot'],capture_output=True,timeout=30)
    returned=False
    deadline=time.time()+300
    while time.time()<deadline:
        time.sleep(10)
        try: returned=run(ssh+['cat /proc/sys/kernel/random/boot_id'],timeout=20)!=before
        except Exception: continue
        if returned: break
    if not returned:
        return 'failed: exit не вернулся после перезагрузки за 5 минут'
    iface='awg'+str(record['exit_index'])
    deadline=time.time()+180
    while time.time()<deadline:
        probe=subprocess.run(['awg','show',iface,'latest-handshakes'],capture_output=True,timeout=15)
        stamps=[int(f[1]) for f in (l.split() for l in probe.stdout.decode().splitlines()) if len(f)>1]
        if stamps and max(stamps)>moment:
            return 'done: ядро '+target
        time.sleep(10)
    return 'failed: туннель не восстановился после перезагрузки'


def main():
    if os.geteuid()!=0 or len(sys.argv)!=3: raise ValueError('usage: provision IP NAME')
    ip=c.ipv4(sys.argv[1]);name=c.identifier(sys.argv[2]);os.umask(0o077)
    ssh=['ssh','-F','/dev/null','-i',str(BASE/'ssh/id_ed25519'),'-o','IdentitiesOnly=yes','-o','IdentityAgent=none',
         '-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(BASE/'ssh/known_hosts'),
         '-o','ConnectTimeout=10','root@'+ip]
    with c.locked('/run/awg-cascade-provision.lock',30):
        run(ssh+['true'])
        record_path=BASE/'exits'/('.provision-'+hashlib.sha256((ip+' '+name).encode()).hexdigest()+'.json')
        state=c.validate_state(json.loads((BASE/'state.json').read_text()))
        if record_path.exists():
            record=json.loads(record_path.read_text())
            # A lost final response must not create a second exit.
            if any(n['index']==record['exit_index'] and n['ip']==ip for n in state['exits']):
                record_path.unlink();print(json.dumps({'ok':True,'index':record['exit_index'],'resumed':True}));return
        else:
            if any(n['ip']==ip or n['name']==name for n in state['exits']): raise ValueError('exit already exists')
            lease=run(['/usr/local/sbin/awg-cascade-exit-reserve.sh','acquire','provision:'+name]).split()
            try:
                private=run(['awg','genkey']);public=run(['awg','pubkey'],private.encode());psk=run(['awg','genpsk'])
                record={'exit_index':int(lease[0]),'reserve_token':lease[1],'name':name,'ip':ip,'ru_privkey':c.key32(private),'ru_pubkey':c.key32(public),'ru_psk':c.key32(psk)}
                c.atomic_write(record_path,json.dumps(record),mode=0o600)
            except BaseException:
                run(['/usr/local/sbin/awg-cascade-exit-reserve.sh','release',lease[1]]);raise
        if 'exit_info' not in record:
            if 'stage' not in record:
                record['stage']=run(ssh+['umask 077; mktemp -d /root/awgc-provision.XXXXXXXX'])
                if not re.fullmatch(r'/root/awgc-provision\.[A-Za-z0-9]+',record['stage']): raise ValueError('invalid staging directory')
                c.atomic_write(record_path,json.dumps(record),mode=0o600)
            buffer=io.BytesIO()
            with tarfile.open(fileobj=buffer,mode='w') as archive:
                for script in ('setup-exit.sh','awg2-params.sh','awg-cascade-exit-warp.sh','awg-cascade-ssh-harden.sh','awg-cascade-fail2ban.sh','awg-cascade-cfg.sh','awg-cascade-autoreboot.sh','awg-cascade-reboot.py'):
                    path=SCRIPTS/script
                    if path.is_symlink() or path.stat().st_uid!=0: raise ValueError('untrusted provisioning code')
                    archive.add(path,arcname=script)
            run(ssh+['tar -xf - -C '+record['stage']],buffer.getvalue())
            config={l.partition('=')[0]:l.partition('=')[2].strip('"\'') for l in (BASE/'config').read_text().splitlines() if '=' in l and not l.startswith('#')}
            used=','.join(str(ipaddress.ip_network(n['ru_tunnel_ip']+'/30',strict=False)) for n in state['exits'])
            env={'BATCH':'1','TERM':'xterm','EXIT_INDEX':str(record['exit_index']),'RU_PUBLIC_IP':c.ipv4(config['RU_PUBLIC_IP']),
                 'RU_TUNNEL_OCTET':str(100+record['exit_index']),'RU_USED_TUNNELS':used,'RU_PUBKEY':record['ru_pubkey'],'RU_PSK':record['ru_psk']}
            launcher="python3 -c 'import sys,json,os; p=json.load(sys.stdin); os.environ.update(p[\"env\"]); os.execv(\"/bin/bash\",[\"bash\",p[\"script\"]])'"
            raw=run(ssh+[launcher],json.dumps({'env':env,'script':record['stage']+'/setup-exit.sh'}).encode(),timeout=2700)
            record['exit_info']=json.loads(raw)
            c.validate_exit(record)
            c.atomic_write(record_path,json.dumps(record),mode=0o600)
        result=run(['/usr/local/sbin/awg-cascade-exit-add-ru.sh','-'],json.dumps(record).encode(),timeout=180)
        if not json.loads(result).get('ok'): raise RuntimeError('RU commit failed')
        # Stage is a validated directory created by mktemp for this operation only.
        if re.fullmatch(r'/root/awgc-provision\.[A-Za-z0-9]+',record.get('stage','')):
            run(ssh+['rm -rf -- '+record['stage']])
        record_path.unlink()
        reboot=exit_reboot(ssh,record)
        print(json.dumps({'ok':True,'index':record['exit_index'],'interface':'awg'+str(record['exit_index']),'reboot':reboot}))
        # Код 2, а не 1: exit добавлен и работает, не завершилась только
        # перезагрузка. Повторять провижининг не нужно и вредно — вызывающая
        # сторона обязана различать эти два исхода.
        if reboot.startswith('failed'): sys.exit(2)


if __name__=='__main__':
    try: main()
    except Exception as exc:
        print('Provisioning incomplete: '+type(exc).__name__+'; retry with the same IP/name to resume the saved operation',file=sys.stderr);sys.exit(1)
