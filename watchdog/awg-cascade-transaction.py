#!/usr/bin/env python3
"""Serialized local mutations with durable file/runtime rollback journal.

The journal is root-only and never printed: it contains private key material.
A failed recovery blocks subsequent mutations instead of losing the evidence.
"""
from __future__ import annotations
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location('control', Path(__file__).with_name('awg-cascade-control.py'))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
JOURNAL = Path('/var/lib/awg-cascade/transaction')
HELPERS = {'peer-add', 'peer-remove', 'peer-rotate', 'exit-add-ru', 'exit-remove', 'client3'}
# Операции, меняющие СОСТАВ exit'ов. Только они переиспользуют индексы, и
# только им опасен незавершённый AWG3.
EXIT_COMPOSITION = {'exit-add-ru', 'exit-remove'}
AWG3_PENDING = Path('/var/lib/awg-cascade/awg3-pending.json')
WG = Path('/etc/amnezia/amneziawg')
BASE = Path('/etc/awg-cascade')


class MutationInterrupted(Exception):
    """Do not use InterruptedError: selectors treats it as a retryable EINTR."""


def command(*args, check=True, **kwargs):
    result = subprocess.run(args, capture_output=True, timeout=45, **kwargs)
    if check and result.returncode: raise RuntimeError('runtime operation failed: ' + args[0])
    return result


def managed_files():
    files = [BASE / n for n in ('state.json', 'peers.json', 'config', 'awg2_params')]
    files += list(WG.glob('*.conf')) + list((BASE / 'peers').glob('*.conf')) + list((BASE / 'exits').glob('*.keys'))
    return sorted(p for p in files if p.exists())


def snapshot(operation):
    JOURNAL.mkdir(parents=True, mode=0o700)
    manifest = {'operation': operation, 'created': time.time(), 'files': {}, 'runtime': {}, 'enabled': {}}
    for i, path in enumerate(managed_files()):
        if path.is_symlink(): raise ValueError('symlink refused')
        st = path.stat()
        name = f'file-{i}'
        c.atomic_write(JOURNAL / name, path.read_bytes(), mode=0o600)
        manifest['files'][str(path)] = [name, st.st_mode & 0o777, st.st_uid, st.st_gid]
    live = command('awg', 'show', 'interfaces').stdout.decode().split()
    for iface in live:
        c.identifier(iface, c.IFACE)
        # Only project interfaces with managed configs belong in this journal.
        if not (WG / (iface + '.conf')).exists(): continue
        name = 'runtime-' + iface
        c.atomic_write(JOURNAL / name, command('awg', 'showconf', iface).stdout, mode=0o600)
        manifest['runtime'][iface] = name
    for path in WG.glob('*.conf'):
        manifest['enabled'][path.stem] = command('systemctl', 'is-enabled', 'awg-quick@' + path.stem, check=False).returncode == 0
    c.atomic_write(JOURNAL / 'journal.json', json.dumps(manifest), mode=0o600)
    return manifest


def recover():
    c.recover_peer_edit()
    path = JOURNAL / 'journal.json'
    if not path.exists():
        # Incomplete snapshot cannot have executed a mutation.
        if JOURNAL.exists(): shutil.rmtree(JOURNAL)
        return
    manifest = json.loads(path.read_text())
    if manifest.get('committed'):
        shutil.rmtree(JOURNAL)
        return
    before = manifest['files']
    live = command('awg', 'show', 'interfaces').stdout.decode().split()
    managed_ifaces = {p.stem for p in WG.glob('*.conf')}
    for iface in live:
        if iface in managed_ifaces and iface not in manifest['runtime']:
            c.identifier(iface, c.IFACE)
            command('awg-quick', 'down', iface)
    for conf in WG.glob('*.conf'):
        if str(conf) not in before:
            command('systemctl', 'disable', 'awg-quick@' + conf.stem)
    for path in managed_files():
        if str(path) not in before: path.unlink()
    for name, (backup, mode, uid, gid) in before.items():
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        c.atomic_write(path, (JOURNAL / backup).read_bytes(), mode, uid, gid)
    for iface, backup in manifest['runtime'].items():
        if command('ip', 'link', 'show', 'dev', iface, check=False).returncode:
            command('awg-quick', 'up', iface)
        command('awg', 'setconf', iface, str(JOURNAL / backup))
    for iface, enabled in manifest['enabled'].items():
        command('systemctl', 'enable' if enabled else 'disable', 'awg-quick@' + iface)
    command('/usr/local/sbin/awg-cascade-iprule.sh')
    command('/usr/local/sbin/awg-cascade-iptables.sh')
    shutil.rmtree(JOURNAL)


def terminate_child(proc):
    if proc.poll() is not None: return
    with contextlib.suppress(ProcessLookupError): os.killpg(proc.pid, signal.SIGTERM)
    try: proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError): os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)


def main():
    if os.geteuid() != 0: raise PermissionError('root required')
    operation = sys.argv[1] if len(sys.argv) > 1 else ''
    if operation not in HELPERS | {'recover'}: raise ValueError('operation refused')
    os.umask(0o077)
    with c.locked('/run/awg-cascade-mutation.lock', timeout=30) as mutation_fd, c.locked(BASE / 'state.lock', timeout=30) as state_fd:
        recover()
        if operation == 'recover': return 0
        # Незавершённый AWG3 запрещает менять состав exit'ов.
        #
        # Его журнал привязан к интерфейсу, а индексы переиспользуются: удалить
        # exit и завести новый с тем же индексом — значит подставить под чужое
        # восстановление свежий туннель. Свой журнал движок восстанавливает сам,
        # а этот — чужой, и раньше он просто не учитывался (A02 аудита v2.7.6).
        if operation in EXIT_COMPOSITION and AWG3_PENDING.exists():
            raise RuntimeError(
                'незавершённая операция AWG3 — менять состав exit’ов нельзя. '
                'Сначала: awg-cascade-awg3.sh <iface> recover')
        c.validate_state(json.loads((BASE / 'state.json').read_text()))
        c.validate_peers(json.loads((BASE / 'peers.json').read_text()))
        manifest = snapshot(operation)
        env = dict(os.environ, AWGC_TRANSACTION='1')
        proc = None
        def interrupted(signum, frame): raise MutationInterrupted('mutation interrupted')
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(signum, interrupted)
        try:
            # Parent owns state.lock. Child helpers must never acquire it again.
            # Retain locks in the bounded child after parent SIGKILL. Recovery
            # cannot race a still-running orphan helper writing the same files.
            proc = subprocess.Popen(['/usr/bin/timeout', '--kill-after=5', '120', '/bin/bash', '/usr/local/sbin/awg-cascade-' + operation + '.sh', *sys.argv[2:]],
                                    env=env, stdin=sys.stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True, pass_fds=(mutation_fd, state_fd))
            out, err = proc.communicate(timeout=130)
            if proc.returncode: raise RuntimeError('helper failed; restoring previous state')
            c.validate_state(json.loads((BASE / 'state.json').read_text()))
            c.validate_peers(json.loads((BASE / 'peers.json').read_text()))
            # Fsync every changed file before the durable commit marker.
            for path in managed_files():
                with path.open('rb') as stream: os.fsync(stream.fileno())
            manifest['committed'] = True
            c.atomic_write(JOURNAL / 'journal.json', json.dumps(manifest), mode=0o600)
            shutil.rmtree(JOURNAL)
            sys.stdout.buffer.write(out)
            sys.stderr.buffer.write(err)
            return 0
        except BaseException:
            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(signum, signal.SIG_IGN)
            if proc is not None: terminate_child(proc)
            recover()
            raise


if __name__ == '__main__':
    try: sys.exit(main())
    except BaseException as exc:
        if isinstance(exc, SystemExit): raise
        # Текст показываем только для СВОИХ отказов: их формулируем мы, и
        # секретов в них нет. У прочих исключений сообщение способно тащить
        # пути и данные библиотек, поэтому остаётся только тип.
        #
        # Раньше тип печатался всегда, и отказ «сначала заверши AWG3» доходил
        # до оператора как «Mutation failed: RuntimeError» — узнать из этого,
        # что делать, было неоткуда.
        ours = isinstance(exc, (ValueError, RuntimeError, PermissionError))
        detail = str(exc) if ours and str(exc) else ''
        print('Мутация не выполнена: ' + (detail or type(exc).__name__)
              + ('' if detail else '; проверьте журнал транзакции перед повтором'),
              file=sys.stderr)
        sys.exit(1)
