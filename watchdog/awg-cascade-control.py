#!/usr/bin/env python3
"""Privileged data boundary. Standard library only; never evaluates input.

The bot may edit state/peer data through a locked stdin protocol. Paths,
commands and file ownership are fixed here, not supplied by config or JSON.
Pure validation functions are also exercised on non-Linux development hosts.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

BASE = Path('/etc/awg-cascade')
MAX_PAYLOAD = 4 * 1024 * 1024
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,31}\Z')
IFACE = re.compile(r'[A-Za-z][A-Za-z0-9_-]{0,14}\Z')
EXIT = re.compile(r'awg[1-9][0-9]?\Z')


def identifier(value, pattern=NAME):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError('invalid identifier')
    return value


def ipv4(value):
    return str(ipaddress.IPv4Address(value))


def integer(value, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError('integer outside allowed range')
    return value


def key32(value):
    if not isinstance(value, str) or len(value) != 44:
        raise ValueError('invalid AWG key')
    if len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError('invalid AWG key')
    return value


def single_line(value, limit=4096):
    if not isinstance(value, str) or len(value) > limit or any(ord(c) < 32 for c in value):
        raise ValueError('invalid single-line value')
    return value


def validate_peers(peers):
    if not isinstance(peers, list) or len(peers) > 4096:
        raise ValueError('invalid peer list')
    names, ips, keys = set(), set(), set()
    for peer in peers:
        name = identifier(peer['name'])
        addr = ipv4(peer['ip'])
        key = key32(peer['pubkey'])
        identifier(peer.get('iface', 'awg0'), IFACE)
        if peer.get('pinned_exit') is not None:
            identifier(peer['pinned_exit'], EXIT)
        targets = peer.get('lan_allow', []) or []
        if not isinstance(targets, list) or len(targets) > 4096 or len(set(targets)) != len(targets):
            raise ValueError('invalid LAN allow list')
        for dst in targets: ipv4(dst)
        if name in names or addr in ips or key in keys:
            raise ValueError('duplicate peer name, address or key')
        names.add(name); ips.add(addr); keys.add(key)
    return peers


def validate_state(state):
    if not isinstance(state, dict) or not isinstance(state.get('exits'), list):
        raise ValueError('invalid state')
    indices, interfaces, subnets = set(), set(), set()
    for node in state['exits']:
        index = integer(node['index'], 1, 99)
        iface = identifier(node['interface'], EXIT)
        if iface != f'awg{index}':
            raise ValueError('exit interface/index mismatch')
        identifier(node['name'])
        identifier(node.get('exit_iface', 'awg-in'), IFACE)
        if node.get('exit_pubkey'): key32(node['exit_pubkey'])
        ipv4(node['ip']); integer(node['port'], 1, 65535)
        if not isinstance(node['enabled'], bool):
            raise ValueError('enabled must be boolean')
        integer(node.get('weight', 1), 1, 256)
        if node.get('status') not in ('up', 'down', 'unknown', 'disabled'):
            raise ValueError('invalid exit status')
        network = ipaddress.ip_network(ipv4(node['ru_tunnel_ip']) + '/30', strict=False)
        if ipaddress.ip_address(ipv4(node['exit_tunnel_ip'])) not in network:
            raise ValueError('tunnel address mismatch')
        if index in indices or iface in interfaces or str(network) in subnets:
            raise ValueError('duplicate exit resource')
        indices.add(index); interfaces.add(iface); subnets.add(str(network))
    for lease in state.get('exit_reservations', []):
        integer(lease['index'], 1, 99)
        single_line(lease['token'], 256)
        integer(lease['at'], 0, 2**53)
    return state


def validate_exit(data):
    integer(data['exit_index'], 1, 99)
    identifier(data['name'])
    single_line(data.get('reserve_token', ''), 256)
    for key in ('ru_privkey', 'ru_pubkey', 'ru_psk'):
        key32(data[key])
    info = data['exit_info']
    key32(info['exit_pubkey']); ipv4(info['exit_public_ip'])
    integer(info['exit_port'], 1, 65535)
    ru, ex = ipv4(info['ru_tunnel_ip']), ipv4(info['exit_tunnel_ip'])
    net = ipaddress.ip_network(ru + '/30', strict=False)
    if ipaddress.ip_address(ex) not in net or ru == ex:
        raise ValueError('invalid tunnel subnet')
    if not re.fullmatch(r'awg-in(?:-[2-9]|-[1-9][0-9])?', info.get('exit_iface', 'awg-in')):
        raise ValueError('invalid exit interface')
    for value in info.get('h_params', {}).values():
        if not re.fullmatch(r'[0-9]+(?:-[0-9]+)?', str(value)):
            raise ValueError('invalid H parameter')
    for value in info.get('s_params', {}).values():
        integer(value, 0, 1280)
    for value in info.get('i_params', {}).values():
        single_line(value)
    return data


def atomic_write(path, data, mode=0o640, uid=0, gid=0):
    """Same-filesystem rename, restrictive creation mode, flush before publish."""
    path = Path(path)
    if path.is_symlink():
        raise ValueError('symlink target refused')
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode) if hasattr(os, 'fchmod') else os.chmod(tmp, mode)
            if hasattr(os, 'fchown'):
                os.fchown(stream.fileno(), uid, gid)
            stream.write(data if isinstance(data, bytes) else data.encode())
            stream.flush(); os.fsync(stream.fileno())
        os.replace(tmp, path)
        if os.name == 'posix':
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(parent)
            finally: os.close(parent)
    finally:
        with contextlib.suppress(FileNotFoundError): os.unlink(tmp)


@contextlib.contextmanager
def locked(path, timeout=30):
    import fcntl
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline: raise TimeoutError('lock deadline exceeded')
                time.sleep(0.05)
        yield fd
    finally:
        os.close(fd)


def read_payload(stream=sys.stdin, *, single=True):
    line = stream.readline(MAX_PAYLOAD + 1) if single else stream.read(MAX_PAYLOAD + 1)
    if not line or len(line.encode()) > MAX_PAYLOAD:
        raise ValueError('missing or excessive payload')
    return json.loads(line)


def bot_gid():
    import grp
    cfg = (BASE / 'config').read_text()
    name = next((l.split('=', 1)[1].strip('"\'') for l in cfg.splitlines() if l.startswith('BOT_USER=')), 'awgbot')
    identifier(name, re.compile(r'[a-z_][a-z0-9_-]{0,31}\Z'))
    if name == 'root': raise ValueError('root is not a bot account')
    return grp.getgrnam(name).gr_gid


def apply_peer_policy():
    for helper in ('iprule', 'iptables'):
        subprocess.run(['/usr/local/sbin/awg-cascade-' + helper + '.sh'],
                       check=True, capture_output=True, timeout=90)


def recover_peer_edit():
    journal = Path('/var/lib/awg-cascade/peer-edit-pending.json')
    if not journal.exists(): return
    saved = json.loads(journal.read_text())
    peers = validate_peers(saved['new'] if saved.get('committed') else saved['old'])
    atomic_write(BASE / 'peers.json', json.dumps(peers, ensure_ascii=False, indent=2) + '\n', gid=bot_gid())
    apply_peer_policy()
    journal.unlink()


def edit_data(kind):
    """Lock owned by this root process for the complete read/edit/write exchange."""
    import select
    path = BASE / {'state': 'state.json', 'peers': 'peers.json'}[kind]
    validate = validate_state if kind == 'state' else validate_peers
    with locked(BASE / 'state.lock'):
        recover_peer_edit()
        current = json.loads(path.read_text())
        validate(current)
        print(json.dumps(current, separators=(',', ':')), flush=True)
        if not select.select([sys.stdin], [], [], 30)[0]:
            raise TimeoutError('client did not commit data')
        updated = read_payload()
        validate(updated)
        # Data broker exposes metadata only; identities/keys require a transaction.
        allowed = {'name', 'note', 'enabled', 'weight', 'warp_state', 'warp_exit_ip', 'warp_exit_geo'} if kind == 'state' else {'note', 'pinned_exit', 'lan_allow'}
        old_rows = current['exits'] if kind == 'state' else current
        new_rows = updated['exits'] if kind == 'state' else updated
        if len(old_rows) != len(new_rows): raise ValueError('membership requires helper')
        for old, new in zip(old_rows, new_rows):
            if {k:v for k,v in old.items() if k not in allowed} != {k:v for k,v in new.items() if k not in allowed}:
                raise ValueError('immutable identity field changed')
        if kind == 'state' and {k:v for k,v in current.items() if k != 'exits'} != {k:v for k,v in updated.items() if k != 'exits'}:
            raise ValueError('immutable state metadata changed')
        if kind == 'state':
            updated['last_update'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        runtime_change = kind == 'peers' and any(
            (old.get('pinned_exit'), old.get('lan_allow')) != (new.get('pinned_exit'), new.get('lan_allow'))
            for old, new in zip(current, updated))
        if runtime_change:
            exits = {n['interface'] for n in validate_state(json.loads((BASE / 'state.json').read_text()))['exits']}
            ips = {p['ip'] for p in updated}
            for peer in updated:
                if peer.get('pinned_exit') and peer['pinned_exit'] not in exits: raise ValueError('unknown pinned exit')
                if any(ip not in ips or ip == peer['ip'] for ip in peer.get('lan_allow', []) or []): raise ValueError('unknown LAN target')
        journal = Path('/var/lib/awg-cascade/peer-edit-pending.json')
        if runtime_change:
            journal.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_write(journal, json.dumps({'old': current, 'new': updated}), mode=0o600)
        try:
            atomic_write(path, json.dumps(updated, ensure_ascii=False, indent=2) + '\n', gid=bot_gid())
            if runtime_change:
                apply_peer_policy()
                atomic_write(journal, json.dumps({'old': current, 'new': updated, 'committed': True}), mode=0o600)
                journal.unlink()
        except BaseException:
            if runtime_change: recover_peer_edit()
            raise
        print('{"ok":true}', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['edit-state', 'edit-peers', 'validate-exit', 'validate-state', 'validate-peers'])
    args = parser.parse_args()
    if args.command.startswith('edit-'):
        if os.geteuid() != 0: raise PermissionError('root required')
        edit_data(args.command.removeprefix('edit-'))
    else:
        validator = {'validate-exit': validate_exit, 'validate-state': validate_state, 'validate-peers': validate_peers}[args.command]
        validator(read_payload(single=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, TimeoutError) as exc:
        print(json.dumps({'ok': False, 'error': type(exc).__name__ + ': validation or storage failed'}), file=sys.stderr)
        sys.exit(1)
