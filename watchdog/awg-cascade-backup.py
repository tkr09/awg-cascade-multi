#!/usr/bin/env python3
"""Validate a locked snapshot, then compress outside the mutation lock."""
import contextlib
import datetime
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile

spec=importlib.util.spec_from_file_location('control',Path(__file__).with_name('awg-cascade-control.py'))
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)


def sections(path):
    result=[]
    for line in path.read_text().splitlines():
        line=line.strip()
        if not line or line.startswith('#'): continue
        if line.startswith('['): result.append({'section':line});continue
        key,sep,value=line.partition('=')
        if not sep or not result: raise ValueError('invalid tunnel config')
        result[-1][key.strip()]=value.strip()
    return result


def pubkey(private):
    c.key32(private)
    result=subprocess.run(['awg','pubkey'],input=private,text=True,capture_output=True,timeout=5,check=True)
    return c.key32(result.stdout.strip())


def verify(root):
    base=root/'etc/awg-cascade';wg=root/'etc/amnezia/amneziawg'
    peers=c.validate_peers(json.loads((base/'peers.json').read_text()))
    state=c.validate_state(json.loads((base/'state.json').read_text()))
    for peer in peers:
        server=sections(wg/(peer.get('iface','awg0')+'.conf'))
        client=sections(base/'peers'/(peer['name']+'.conf'))
        matches=[p for p in server if p.get('PublicKey')==peer['pubkey']]
        if len(matches)!=1 or len(client)!=2: raise ValueError('peer config mismatch')
        entry=matches[0]
        if pubkey(client[0]['PrivateKey'])!=peer['pubkey']: raise ValueError('client key mismatch')
        if pubkey(server[0]['PrivateKey'])!=client[1]['PublicKey']: raise ValueError('server key mismatch')
        if entry.get('PresharedKey')!=client[1].get('PresharedKey'): raise ValueError('PSK mismatch')
        if entry['AllowedIPs']!=peer['ip']+'/32': raise ValueError('AllowedIPs mismatch')
        if str(ipaddress.ip_interface(client[0]['Address']).ip)!=peer['ip']: raise ValueError('address mismatch')
    for node in state['exits']:
        server=sections(wg/(node['interface']+'.conf'))
        if str(ipaddress.ip_interface(server[0]['Address']).ip)!=node['ru_tunnel_ip']: raise ValueError('exit address mismatch')
        if node.get('exit_pubkey') and not any(p.get('PublicKey')==node['exit_pubkey'] for p in server): raise ValueError('exit key mismatch')
    return len(peers),len(state['exits'])


def main():
    if os.geteuid()!=0: raise PermissionError('root required')
    os.umask(0o077)
    now=datetime.datetime.now(datetime.timezone.utc)
    dst=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/root')/('awg-cascade-backup-'+socket.gethostname()+'-'+now.strftime('%Y%m%d-%H%M%S-%f')+'.tar.gz')
    if dst.is_symlink(): raise ValueError('destination symlink')
    dst.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='awgc-backup-') as directory:
        snapshot=Path(directory)
        with c.locked('/run/awg-cascade-mutation.lock',120),c.locked('/etc/awg-cascade/state.lock',120):
            if Path('/var/lib/awg-cascade/transaction/journal.json').exists() or Path('/var/lib/awg-cascade/awg3-pending.json').exists() or Path('/var/lib/awg-cascade/peer-edit-pending.json').exists():
                raise ValueError('pending transaction; recover before backup')
            for source in (Path('/etc/awg-cascade'),Path('/etc/amnezia/amneziawg')):
                if source.is_symlink() or any(p.is_symlink() for p in source.rglob('*')): raise ValueError('symlink in backup source')
                shutil.copytree(source,snapshot/source.relative_to('/'),ignore=shutil.ignore_patterns('*.lock','.pending-*','backup-manifest.json'))
            for name in ('rules.v4','rules.v6'):
                source=Path('/etc/iptables')/name
                if source.exists():
                    (snapshot/'etc/iptables').mkdir(parents=True,exist_ok=True)
                    shutil.copy2(source,snapshot/'etc/iptables'/name)
        peers,exits=verify(snapshot)
        hashes={p.relative_to(snapshot).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in snapshot.rglob('*') if p.is_file()}
        manifest={'hostname':socket.gethostname(),'created':now.isoformat(),'consistent':True,'validation':'keys-psk-addresses','peers':peers,'exits':exits,'sha256':hashes}
        (snapshot/'etc/awg-cascade/backup-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        fd,name=tempfile.mkstemp(prefix='.'+dst.name+'.',dir=dst.parent);os.close(fd)
        try:
            with tarfile.open(name,'w:gz') as archive:
                archive.add(snapshot/'etc',arcname='etc')
            with tarfile.open(name,'r:gz') as archive:
                for member in archive.getmembers():
                    if member.isfile():
                        data=archive.extractfile(member).read()
                        if member.name in hashes and hashlib.sha256(data).hexdigest()!=hashes[member.name]: raise ValueError('archive checksum mismatch')
            with open(name,'rb') as stream: os.fsync(stream.fileno())
            os.replace(name,dst)
        finally:
            with contextlib.suppress(FileNotFoundError): os.unlink(name)
    if len(sys.argv)==1:
        # Три архива, а не четырнадцать. Бэкап на самой ноде — не хранилище, а
        # материал для быстрого отката: копию забирают на машину владельца перед
        # каждой раскаткой, и глубина там своя. Держать здесь две недели значило
        # бы две недели хранить приватные ключи клиентов лишний раз.
        #
        # Exit'ы сюда не относятся вовсе: их бэкапов нет и не планируется —
        # exit проще поставить заново, невосстановимы только клиентские ключи,
        # а они существуют только на RU. Решение владельца от 23.09.2026.
        keep=3
        for line in Path('/etc/awg-cascade/config').read_text().splitlines():
            if line.startswith('BACKUP_KEEP='): keep=int(line.partition('=')[2].strip('"\''))
        c.integer(keep,1,365)
        old=sorted(Path('/root').glob('awg-cascade-backup-'+socket.gethostname()+'-*.tar.gz'),key=lambda p:p.stat().st_mtime,reverse=True)
        for path in old[keep:]: path.unlink()
    print('Verified backup: '+str(dst))


if __name__=='__main__':
    try: main()
    except Exception as exc:
        print('Backup failed: '+type(exc).__name__+'; previous backups preserved',file=sys.stderr);sys.exit(1)
