#!/usr/bin/env python3
"""Bounded parallel probes. Unstarted/expired work is unknown, not a failed ping."""
import concurrent.futures
import json
import re
import subprocess
import time
from pathlib import Path


def probe(iface):
    start = time.monotonic()
    try:
        p = subprocess.run(['ping','-I',iface,'-c','1','-W','2','1.1.1.1'],capture_output=True,text=True,timeout=3)
        match = re.search(r'time[=<]([0-9.]+)',p.stdout)
        if p.returncode == 0 and match: return int(float(match[1]))
        p = subprocess.run(['curl','--interface',iface,'-fsS','-o','/dev/null','--max-time','2','--connect-timeout','2','https://1.1.1.1/'],capture_output=True,timeout=3)
        return int((time.monotonic()-start)*1000) if p.returncode == 0 else -1
    except subprocess.TimeoutExpired: return -1


def main():
    state = json.loads(Path('/etc/awg-cascade/state.json').read_text())
    ifaces = [n['interface'] for n in state['exits'] if n['enabled']]
    if len(ifaces) > 99 or any(not re.fullmatch(r'awg[1-9][0-9]?',i) for i in ifaces): raise ValueError('interfaces')
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=16)
    jobs = {pool.submit(probe,i):i for i in ifaces}
    try:
        for job in concurrent.futures.as_completed(jobs,timeout=42): print(jobs[job],job.result(),flush=True)
    finally:
        for job,iface in jobs.items():
            if not job.done(): print(iface,-2,flush=True); job.cancel()
        pool.shutdown(wait=True,cancel_futures=True)


if __name__ == '__main__': main()
