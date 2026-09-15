"""Regression tests; kernel tests run in a disposable network namespace."""
import base64
import importlib.util
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'watchdog'/('awg-cascade-'+name+'.py'))
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
c=module('control');fw=module('firewall');routing=module('routing')
KEY=base64.b64encode(bytes(range(32))).decode()
def peer(ip='10.20.0.2',name='peer1',pin='awg1'):
    return {'name':name,'ip':ip,'pubkey':KEY,'iface':'awg0','pinned_exit':pin}
class Validation(unittest.TestCase):
    @unittest.skipUnless(hasattr(signal, 'setitimer'), 'POSIX signals')
    def test_signal_interrupts_subprocess_wait(self):
        txn=module('transaction')
        def interrupt(signum, frame): raise txn.MutationInterrupted('test')
        previous=signal.signal(signal.SIGALRM, interrupt)
        proc=subprocess.Popen(['sleep','5'],stdout=subprocess.PIPE)
        try:
            signal.setitimer(signal.ITIMER_REAL, .1)
            with self.assertRaises(txn.MutationInterrupted): proc.communicate(timeout=2)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
            proc.kill();proc.communicate()
    def test_iproute_json_selectors(self):
        self.assertTrue(routing.same({'dst':'10.20.0.0','dstlen':24,'table':'main'}, {'dst':'10.20.0.0/24','table':'main'}))
        self.assertTrue(routing.same({'uid_start':999,'uid_end':999}, {'uidrange':'999-999'}))
        self.assertFalse(routing.same({'uid_start':998,'uid_end':999}, {'uidrange':'999-999'}))
    def test_valid_peer(self): self.assertEqual(c.validate_peers([peer()])[0]['name'],'peer1')
    def test_injection(self):
        for field,value in [('name','../key'),('iface','awg0\nCOMMIT'),('ip','999.1.1.1'),('pinned_exit','awg153'),('pubkey','x'*44)]:
            p=peer();p[field]=value
            with self.subTest(field=field),self.assertRaises((ValueError,TypeError)): c.validate_peers([p])
    def test_duplicate(self):
        with self.assertRaises(ValueError): c.validate_peers([peer(),peer()])
    def test_atomic_failure(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'state';p.write_text('old')
            with patch.object(c.os,'replace',side_effect=OSError('disk')),self.assertRaises(OSError):
                c.atomic_write(p,'new',uid=os.getuid() if hasattr(os,'getuid') else 0,gid=os.getgid() if hasattr(os,'getgid') else 0)
            self.assertEqual(p.read_text(),'old');self.assertEqual(len(list(Path(d).iterdir())),1)
    def test_pair_before_deny(self):
        a=peer();b=peer('10.21.0.2','peer2',None);b['iface']='wgc3';b['pubkey']=base64.b64encode(b'x'*32).decode();a['lan_allow']=[b['ip']]
        text=fw.build_rules([('awg0','10.20.0.0/24'),('wgc3','10.21.0.0/24')],[a,b],1001)
        self.assertLess(text.index('-s 10.20.0.2/32 -d 10.21.0.2/32 -o wgc3 -j ACCEPT'),text.index('-i awg0 -d 10.21.0.0/24 -j DROP'))
        self.assertNotIn('-F FORWARD',text)
    def test_ipv6(self):
        text=fw.build_rules([('awg0','10.20.0.0/24'),('wgc3','10.21.0.0/24')],[],1001,True)
        for iface in ('awg0','wgc3'):
            for direction in ('-i','-o'): self.assertIn(f'{direction} {iface} -j DROP',text)
@unittest.skipUnless(os.environ.get('AWGC_NETNS_TEST')=='1','requires disposable network namespace')
class Kernel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for iface in ('awg0','wgc3','awg1','awg2'):
            subprocess.run(['ip','link','add',iface,'type','dummy'],check=True)
            subprocess.run(['ip','link','set',iface,'up'],check=True)
        subprocess.run(['ip','address','add','10.20.0.1/24','dev','awg0'],check=True)
    def test_01_pins(self):
        a=peer();b=peer('10.20.0.3','peer2','awg2');b['pubkey']=base64.b64encode(b'x'*32).decode()
        routing.run('ip','route','replace','default','dev','awg2','table','100')
        routing.run('ip','rule','add','from','10.20.0.0/24','lookup','100','priority','1005')
        routing.pins([a,b]);routing.pins([a,b]);routing.pins([a,b])
        self.assertEqual(len([r for r in routing.rules() if r.get('priority')==999]),2)
        routing.run('ip','link','del','awg1')
        result=routing.run('ip','route','get','8.8.8.8','from',a['ip'],'iif','awg0',check=False)
        self.assertNotEqual(result.returncode,0,result.stdout)
        routing.pins([a,b]);self.assertIn('blackhole',routing.run('ip','route','show','table','101').stdout)
    def test_02_firewall(self):
        interfaces=[('awg0','10.20.0.0/24'),('wgc3','10.21.0.0/24')]
        fw.run('iptables','-A','FORWARD','-m','comment','--comment','foreign','-j','ACCEPT');fw.guard('iptables',interfaces,True)
        text=fw.build_rules(interfaces,[],1001)
        fw.run('iptables-restore','--noflush','--test',input=text);fw.run('iptables-restore','--noflush',input=text);fw.hooks('iptables')
        rules=fw.run('iptables','-S','FORWARD').stdout.splitlines()
        guards=[i for i,r in enumerate(rules) if fw.GUARD in r];hook=next(i for i,r in enumerate(rules) if 'awg-cascade-managed' in r)
        self.assertTrue(all(i<hook for i in guards),rules)
        fw.remove_legacy('iptables');self.assertIn('foreign',fw.run('iptables','-S','FORWARD').stdout)
        fw.guard('iptables',interfaces,False);self.assertNotIn(fw.GUARD,fw.run('iptables','-S','FORWARD').stdout)
    def test_03_base_rules_idempotent(self):
        for _ in range(3):
            routing.ensure({'priority':1008,'uidrange':'999-999','action':'prohibit'}, 'uidrange','999-999','prohibit','priority','1008')
            routing.ensure({'priority':997,'dst':'10.20.0.0/24','table':'main'}, 'to','10.20.0.0/24','lookup','main','priority','997')
        self.assertEqual(len([r for r in routing.rules() if r.get('priority')==1008]),1)
        self.assertEqual(len([r for r in routing.rules() if r.get('priority')==997]),1)
if __name__=='__main__': unittest.main(verbosity=2)
