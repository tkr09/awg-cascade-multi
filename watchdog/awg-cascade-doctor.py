#!/usr/bin/env python3
"""Machine-readable health report without private config/key contents."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
spec=importlib.util.spec_from_file_location('routing',Path(__file__).with_name('awg-cascade-routing.py'))
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
base=Path('/etc/awg-cascade')
checks=[]
def record(name,ok,detail=''): checks.append({'check':name,'ok':bool(ok),'detail':detail})
try:
    peers=r.control.validate_peers(json.loads((base/'peers.json').read_text()))
    state=r.control.validate_state(json.loads((base/'state.json').read_text()))
    record('state schema',True,f'{len(peers)} peers, {len(state["exits"])} exits')
    for name in ('config','state.json','peers.json'):
        path=base/name;st=path.stat()
        record('ownership '+name,not path.is_symlink() and st.st_uid==0 and not st.st_mode&0o022)
    record('protected parent',base.stat().st_uid==0 and not base.stat().st_mode&0o022)
    for name in ('activation-pending',): record(name,not (base/name).exists())
    for name in ('transaction/journal.json','awg3-pending.json','peer-edit-pending.json'): record(name,not (Path('/var/lib/awg-cascade')/name).exists())
    rules=r.rules()
    for peer in peers:
        if peer.get('pinned_exit'):
            record('pin guard '+peer['name'],any(r.same(rule,{'priority':1000,'src':peer['ip'],'action':'prohibit'}) for rule in rules))
    for binary in ('iptables','ip6tables'):
        result=subprocess.run([binary,'-S','FORWARD'],capture_output=True,text=True,timeout=10)
        record(binary+' rebuild guard',result.returncode==0 and 'awgc-rebuild-guard' not in result.stdout)
        record(binary+' managed hook','awg-cascade-managed' in result.stdout)
    record('watchdog',subprocess.run(['systemctl','is-active','--quiet','awg-cascade-watchdog'],timeout=10).returncode==0)
except Exception as exc: record('diagnostic execution',False,type(exc).__name__)
report={'ok':all(c['ok'] for c in checks),'checks':checks}
print(json.dumps(report,ensure_ascii=False,indent=2))
sys.exit(0 if report['ok'] else 1)
