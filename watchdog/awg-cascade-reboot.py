#!/usr/bin/env python3
"""Verify the configured boot target and its installed AWG module before reboot."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

def check():
    defaults=Path('/etc/default/grub').read_text()
    selected=re.search(r'^GRUB_DEFAULT=(.*)$',defaults,re.M)
    if selected and selected[1].strip('"\'')!='0': raise ValueError('выбран не первый пункт GRUB — нужна ручная проверка')
    environment=subprocess.check_output(['grub-editenv','/boot/grub/grubenv','list'],text=True,timeout=10)
    if any(line.startswith('next_entry=') and line.partition('=')[2] for line in environment.splitlines()):
        raise ValueError('в GRUB задана одноразовая загрузка — нужна ручная проверка')
    grub=Path('/boot/grub/grub.cfg').read_text()
    kernel=re.search(r'^\s*linux(?:efi)?\s+\S*vmlinuz-([^\s]+)',grub,re.M)
    if not kernel: raise ValueError('не удалось определить ядро следующей загрузки')
    target=kernel[1]
    module=subprocess.check_output(['modinfo','-k',target,'-n','amneziawg'],text=True,timeout=15).strip()
    if not Path(module).is_file(): raise ValueError('файла модуля для этого ядра нет')
    dkms=subprocess.run(['dkms','status','-m','amneziawg','-k',target],capture_output=True,text=True,timeout=15)
    if dkms.returncode or not re.search(r', '+re.escape(target)+r', [^\n]+: installed\s*$',dkms.stdout,re.M):
        raise ValueError('DKMS: модуль не installed для целевого ядра')
    return target

def main():
    if os.geteuid()!=0 or sys.argv[1:] not in ([],['--scheduled']): raise ValueError('arguments/root')
    if sys.argv[1:]==['--scheduled']:
        config=Path('/etc/awg-cascade/config')
        if not config.exists(): config=Path('/etc/awg-cascade-exit/autoreboot')
        values={line.partition('=')[0]:line.partition('=')[2].strip().strip('"\'') for line in config.read_text().splitlines() if '=' in line and not line.startswith('#')}
        if values.get('AUTO_REBOOT')!='1' or values.get('REBOOT_POLICY')!='scheduled':
            raise ValueError('плановая перезагрузка больше не включена')
        if not Path('/var/run/reboot-required').exists(): return
    target=check()
    if sys.argv[1:]==['--scheduled']:
        if len(list(Path('/etc/amnezia/amneziawg').glob('awg-in*.conf')))>1:
            raise ValueError('shared exit: перезагрузка только по согласованию всех RU')
        if Path('/etc/awg-cascade/activation-pending').exists() or Path('/var/lib/awg-cascade/transaction/journal.json').exists() or Path('/var/lib/awg-cascade/awg3-pending.json').exists() or Path('/var/lib/awg-cascade/peer-edit-pending.json').exists():
            raise ValueError('есть незавершённые изменения — перезагрузка отложена')
        if Path('/etc/awg-cascade/state.json').exists():
            subprocess.run(['/usr/local/sbin/awg-cascade-backup.sh'],check=True,timeout=180)
        subprocess.run(['systemctl','reboot'],check=True,timeout=15)
    else: print(json.dumps({'ok':True,'boot_kernel':target,'module_installed':True}))

if __name__=='__main__':
    try: main()
    except Exception as exc:
        print('Перезагрузка не одобрена: '+str(exc),file=sys.stderr);sys.exit(1)
