#!/usr/bin/env python3
"""Reconcile owned policy rules without exposing pinned peers to ECMP."""
from __future__ import annotations
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

spec = importlib.util.spec_from_file_location('awgc_firewall', Path(__file__).with_name('awg-cascade-firewall.py'))
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)
control = fw.control


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=15)
    if check and result.returncode:
        raise RuntimeError('routing command failed: ' + ' '.join(args[:4]))
    return result


def rules():
    return json.loads(run('ip', '-j', '-4', 'rule', 'show').stdout)


def same(rule, expected):
    for key, value in expected.items():
        actual = rule.get(key)
        if key in ('src', 'dst'):
            length = rule.get(key + 'len', 32)
            actual = str(actual).removesuffix('/32')
            if length != 32 and '/' not in actual: actual += '/' + str(length)
        if key == 'uidrange' and 'uid_start' in rule:
            actual = f"{rule['uid_start']}-{rule['uid_end']}"
        if key == 'table': actual = str(actual)
        if key == 'fwmark': actual = str(actual).split('/')[0]
        if actual != value: return False
    return True


def ensure(expected, *tokens):
    matching = [r for r in rules() if same(r, expected)]
    if not matching:
        run('ip', '-4', 'rule', 'add', *tokens)
    # Delete duplicates by complete selector, retaining one rule throughout.
    for _ in matching[1:]:
        run('ip', '-4', 'rule', 'del', *tokens)


def pins(peers):
    control.validate_peers(peers)
    desired = {p['ip']: 100 + int(p['pinned_exit'][3:]) for p in peers if p.get('pinned_exit')}
    # Terminal per-source guard survives interface deletion and table flush.
    for addr in desired:
        ensure({'priority': 1000, 'src': addr, 'action': 'prohibit'},
               'from', addr + '/32', 'prohibit', 'priority', '1000')
    for addr, table in desired.items():
        iface = 'awg' + str(table - 100)
        if run('ip', 'link', 'show', 'dev', iface, check=False).returncode == 0:
            run('ip', '-4', 'route', 'replace', 'default', 'dev', iface, 'table', str(table))
        else:
            run('ip', '-4', 'route', 'replace', 'blackhole', 'default', 'table', str(table))
    # All guards precede removals. Failure leaves protection and is retried.
    for rule in rules():
        addr = str(rule.get('src', '')).removesuffix('/32')
        table = str(rule.get('table', ''))
        if rule.get('priority') == 999 and table.isdigit() and 101 <= int(table) <= 199:
            if desired.get(addr) != int(table):
                control.ipv4(addr)
                run('ip', '-4', 'rule', 'del', 'from', addr + '/32', 'lookup', table, 'priority', '999')
    for addr, table in desired.items():
        ensure({'priority': 999, 'src': addr, 'table': str(table)},
               'from', addr + '/32', 'lookup', str(table), 'priority', '999')
    for rule in rules():
        addr = str(rule.get('src', '')).removesuffix('/32')
        if rule.get('priority') == 1000 and rule.get('action') == 'prohibit' and addr not in desired:
            control.ipv4(addr)
            run('ip', '-4', 'rule', 'del', 'from', addr + '/32', 'prohibit', 'priority', '1000')


def apply(peers_only=False):
    if os.geteuid() != 0: raise PermissionError('root required')
    with control.locked('/run/awg-cascade-routing.lock'):
        peers = json.loads(Path('/etc/awg-cascade/peers.json').read_text())
        if not peers_only:
            interfaces, uid = fw.read_config()
            uidrange = f'{uid}-{uid}'
            # Empty ECMP tables must never fall through to the public RU route.
            ensure({'priority': 1007, 'fwmark': '0x1', 'action': 'prohibit'},
                   'fwmark', '0x1', 'prohibit', 'priority', '1007')
            ensure({'priority': 1008, 'uidrange': uidrange, 'action': 'prohibit'},
                   'uidrange', uidrange, 'prohibit', 'priority', '1008')
            for _, network in interfaces:
                ensure({'priority': 997, 'dst': network, 'table': 'main'},
                       'to', network, 'lookup', 'main', 'priority', '997')
            ensure({'priority': 998, 'uidrange': uidrange, 'ipproto': 'tcp', 'dport': 22, 'table': 'main'},
                   'ipproto', 'tcp', 'dport', '22', 'uidrange', uidrange, 'lookup', 'main', 'priority', '998')
            ensure({'priority': 1005, 'fwmark': '0x1', 'table': '100'},
                   'fwmark', '0x1', 'lookup', '100', 'priority', '1005')
            ensure({'priority': 1006, 'uidrange': uidrange, 'table': '100'},
                   'uidrange', uidrange, 'lookup', '100', 'priority', '1006')
            pins(peers)
            # Exact legacy selectors: never flush the slot containing pin guards.
            for rule in rules():
                if same(rule, {'priority': 1000, 'fwmark': '0x1', 'table': '100'}):
                    run('ip', '-4', 'rule', 'del', 'fwmark', '0x1', 'lookup', '100', 'priority', '1000')
                if same(rule, {'priority': 1001, 'uidrange': uidrange, 'table': '100'}):
                    run('ip', '-4', 'rule', 'del', 'uidrange', uidrange, 'lookup', '100', 'priority', '1001')
        else:
            pins(peers)


if __name__ == '__main__':
    try:
        if sys.argv[1:] not in ([], ['--peers']): raise ValueError('invalid arguments')
        apply(sys.argv[1:] == ['--peers'])
    except Exception as exc:
        print('policy reconciliation failed: ' + str(exc), file=sys.stderr)
        sys.exit(1)
