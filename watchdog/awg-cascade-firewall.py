#!/usr/bin/env python3
"""Own chains only; fail-closed guards cover the entire IPv4/IPv6 transition."""
from __future__ import annotations
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

spec = importlib.util.spec_from_file_location('awgc_control', Path(__file__).with_name('awg-cascade-control.py'))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
GUARD = 'awgc-rebuild-guard'
CHAINS = {'filter': ['AWGC-FORWARD', 'AWGC-OUTPUT'], 'mangle': ['AWGC-MARK', 'AWGC-MSS'], 'nat': ['AWGC-NAT']}
HOOKS = {'filter': [('FORWARD', 'AWGC-FORWARD'), ('OUTPUT', 'AWGC-OUTPUT')],
         'mangle': [('PREROUTING', 'AWGC-MARK'), ('FORWARD', 'AWGC-MSS')],
         'nat': [('POSTROUTING', 'AWGC-NAT')]}


def run(*args, input=None, check=True):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=45)
    if check and result.returncode:
        raise RuntimeError('command failed: ' + ' '.join(args[:3]))
    return result


def read_config(path=Path('/etc/awg-cascade/config')):
    import pwd
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'): continue
        name, sep, value = line.partition('=')
        if not sep: raise ValueError('invalid config assignment')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'": value = value[1:-1]
        values[name] = value
    interfaces = [('awg0', str(ipaddress.IPv4Network(values['CLIENT_NET'])))]
    if values.get('CLIENT3_IFACE'):
        iface = control.identifier(values['CLIENT3_IFACE'], control.IFACE)
        if iface.startswith('awg'): raise ValueError('client3 overlaps exit interface mask')
        interfaces.append((iface, str(ipaddress.IPv4Network(values['CLIENT3_NET']))))
    user = control.identifier(values.get('BOT_USER', 'awgbot'))
    if user == 'root': raise ValueError('root bot refused')
    return interfaces, pwd.getpwnam(user).pw_uid


def build_rules(interfaces, peers, uid, ipv6=False):
    """Pure renderer; all variable tokens validated before reaching restore."""
    control.validate_peers(peers)
    for iface, network in interfaces:
        control.identifier(iface, control.IFACE); ipaddress.IPv4Network(network)
    control.integer(uid, 1, 2**31-1)
    rules = {'filter': [], 'mangle': [], 'nat': []}
    def add(table, chain, *args):
        rules[table].append('-A ' + chain + ' ' + ' '.join(args))
    if ipv6:
        for iface, _ in interfaces:
            add('filter', 'AWGC-FORWARD', '-i', iface, '-j DROP')
            add('filter', 'AWGC-FORWARD', '-o', iface, '-j DROP')
        add('filter', 'AWGC-OUTPUT', '-m owner --uid-owner', str(uid), '-j REJECT')
        return render(rules, ipv6=True)
    nets = [network for _, network in interfaces]
    known = {p['ip']: p for p in peers}
    ifaces = {i for i, _ in interfaces}
    for peer in peers:
        iface = peer.get('iface', 'awg0')
        if iface not in ifaces: raise ValueError('peer references missing client interface')
        for target in peer.get('lan_allow', []) or []:
            if target not in known: continue
            add('filter', 'AWGC-FORWARD', '-i', iface, '-s', peer['ip'] + '/32', '-d', target + '/32', '-o', known[target].get('iface', 'awg0'), '-j ACCEPT')
            add('filter', 'AWGC-FORWARD', '-i', known[target].get('iface', 'awg0'), '-s', target + '/32', '-d', peer['ip'] + '/32', '-o', iface, '-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT')
    for iface, net in interfaces:
        for dst in nets:
            add('filter', 'AWGC-FORWARD', '-i', iface, '-d', dst, '-j DROP')
            add('mangle', 'AWGC-MARK', '-i', iface, '-d', dst, '-j RETURN')
        add('filter', 'AWGC-FORWARD', '-i', iface, '-o awg+ -j ACCEPT')
        add('filter', 'AWGC-FORWARD', '-i awg+ -o', iface, '-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT')
        add('filter', 'AWGC-FORWARD', '-i', iface, '-j DROP')
        add('mangle', 'AWGC-MARK', '-i', iface, '-j MARK --set-mark 0x1')
        add('nat', 'AWGC-NAT', '-s', net, '-o awg+ -j MASQUERADE')
    add('nat', 'AWGC-NAT', '-s 10.99.0.0/16 -o awg+ -j MASQUERADE')
    add('mangle', 'AWGC-MSS', '-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu')
    return render(rules)


def render(rules, ipv6=False):
    text = []
    for table in (['filter'] if ipv6 else ['filter', 'mangle', 'nat']):
        text.append('*' + table)
        for chain in CHAINS[table]:
            text.extend([':' + chain + ' - [0:0]', '-F ' + chain])
        text.extend(rules[table]); text.append('COMMIT')
    return '\n'.join(text) + '\n'


def guard(binary, interfaces, install):
    for iface, _ in interfaces:
        for direction in (['-i', '-o'] if binary == 'ip6tables' else ['-i']):
            args = [direction, iface, '-m', 'comment', '--comment', GUARD, '-j', 'DROP']
            if install:
                if run(binary, '-w', '30', '-C', 'FORWARD', *args, check=False).returncode:
                    run(binary, '-w', '30', '-I', 'FORWARD', '1', *args)
            else:
                while not run(binary, '-w', '30', '-C', 'FORWARD', *args, check=False).returncode:
                    run(binary, '-w', '30', '-D', 'FORWARD', *args)


def hooks(binary, ipv6=False):
    for table in (['filter'] if ipv6 else ['filter', 'mangle', 'nat']):
        for source, target in HOOKS[table]:
            args = ['-m', 'comment', '--comment', 'awg-cascade-managed', '-j', target]
            # Guards are active. Reinsert at the front to precede foreign ACCEPT.
            while not run(binary, '-w', '30', '-t', table, '-C', source, *args, check=False).returncode:
                run(binary, '-w', '30', '-t', table, '-D', source, *args)
            existing = run(binary, '-w', '30', '-t', table, '-S', source).stdout.splitlines()
            position = 1 + sum(GUARD in line for line in existing)
            run(binary, '-w', '30', '-t', table, '-I', source, str(position), *args)


def remove_legacy(binary, ipv6=False):
    for table in (['filter'] if ipv6 else ['filter', 'mangle', 'nat']):
        for line in run(binary, '-w', '30', '-t', table, '-S').stdout.splitlines():
            tokens = shlex.split(line)
            if not tokens or tokens[0] != '-A' or '--comment' not in tokens: continue
            comment = tokens[tokens.index('--comment') + 1]
            if (comment.startswith('awg-cascade') or comment.startswith('awg-lan')) and comment != 'awg-cascade-managed':
                run(binary, '-w', '30', '-t', table, '-D', *tokens[1:])


def ipv6_required():
    proc = Path('/proc/sys/net/ipv6/conf')
    if not proc.exists(): return False
    return any((entry / 'disable_ipv6').read_text().strip() != '1' for entry in proc.iterdir() if (entry / 'disable_ipv6').exists())


def apply():
    if os.geteuid() != 0: raise PermissionError('root required')
    with control.locked('/run/awg-cascade-fw.lock', timeout=30):
        interfaces, uid = read_config()
        peers = json.loads(Path('/etc/awg-cascade/peers.json').read_text())
        v4 = build_rules(interfaces, peers, uid)
        use6 = ipv6_required()
        v6 = build_rules(interfaces, peers, uid, True) if use6 else ''
        guard('iptables', interfaces, True)
        if use6: guard('ip6tables', interfaces, True)
        # Any failure from this point leaves guards; no helper can mask it.
        run('iptables-restore', '-w', '30', '--noflush', '--test', input=v4)
        if use6: run('ip6tables-restore', '-w', '30', '--noflush', '--test', input=v6)
        run('iptables-restore', '-w', '30', '--noflush', input=v4)
        if use6: run('ip6tables-restore', '-w', '30', '--noflush', input=v6)
        hooks('iptables')
        if use6: hooks('ip6tables', True)
        remove_legacy('iptables')
        if use6: remove_legacy('ip6tables', True)
        Path('/etc/iptables').mkdir(mode=0o755, exist_ok=True)
        for binary, filename in [('iptables', 'rules.v4')] + ([('ip6tables', 'rules.v6')] if use6 else []):
            saved = run(binary + '-save').stdout
            saved = '\n'.join(line for line in saved.splitlines() if GUARD not in line) + '\n'
            control.atomic_write(Path('/etc/iptables') / filename, saved, mode=0o600)
        if use6: guard('ip6tables', interfaces, False)
        guard('iptables', interfaces, False)
        print(json.dumps({'ok': True, 'ipv6_blocked': use6, 'interfaces': [i for i, _ in interfaces]}))


if __name__ == '__main__':
    try: apply()
    except Exception as exc:
        print('firewall apply failed; rebuild guard retained: ' + str(exc), file=sys.stderr)
        sys.exit(1)
