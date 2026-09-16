"""Regression tests; kernel tests run in a disposable network namespace."""
import base64
import contextlib
import importlib.util
import io
import json
import os
import signal
from pathlib import Path
import stat
import subprocess
import sys
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
class Awg3Recovery(unittest.TestCase):
    """Три исхода сверки идентичности туннеля (R02 аудита v2.8.5).

    Отсутствующий интерфейс — не то же самое, что подменённый: в первом случае
    откат обязан состояться, во втором он разрушил бы чужой туннель.
    """
    def setUp(self):
        self.awg3=module('awg3')
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name)
        self.awg3.WG=self.root;self.awg3.JOURNAL=self.root/'awg3-pending.json'
        self.calls=[]
        self.awg3.call=lambda node,action,remote:self.calls.append((action,remote))
        self.awg3.JOURNAL.write_text(json.dumps({'iface':'awg2','ip':'198.51.100.7','iface_pubkey':'SAVED',
                                                 'operation':'a'*32,'changes':{},'restart':True,'remote_iface':'awg-in'}))
    def probe(self,runtime=None,derived=None):
        def run(args,**kw):
            if list(args[:2])==['awg','show']: return subprocess.CompletedProcess(args,0 if runtime else 1,runtime or '','')
            if list(args[:2])==['awg','pubkey']: return subprocess.CompletedProcess(args,0 if derived else 1,derived or '','')
            raise AssertionError(args)
        return patch.object(subprocess,'run',side_effect=run)
    def conf(self,key='PRIV'):
        (self.root/'awg2.conf').write_text('[Interface]\nPrivateKey = '+key+'\nListenPort = 51820\n')
    def test_runtime_match_rolls_back(self):
        with self.probe(runtime='SAVED'): self.assertEqual(self.awg3.recovery(),'done')
        self.assertEqual(self.calls,[('rollback',True),('rollback',False)])
        self.assertFalse(self.awg3.JOURNAL.exists())
    def test_missing_iface_falls_back_to_conf(self):
        # down прошёл, up не удался: интерфейса нет именно из-за нашей операции.
        self.conf()
        with self.probe(derived='SAVED'): self.assertEqual(self.awg3.recovery(),'done')
        self.assertEqual(self.calls,[('rollback',True),('rollback',False)])
    def test_replaced_iface_is_stale(self):
        with self.probe(runtime='OTHER'): self.assertEqual(self.awg3.recovery(),'stale')
        self.assertEqual(self.calls,[])
        self.assertFalse(self.awg3.JOURNAL.exists())
        self.assertTrue(list(self.root.glob('awg3-stale-*.json')))
    def test_reused_index_detected_while_down(self):
        # Индекс переиспользован под другой exit: конфиг заменён вместе с ключом.
        self.conf()
        with self.probe(derived='OTHER'): self.assertEqual(self.awg3.recovery(),'stale')
        self.assertEqual(self.calls,[])
    def test_unknown_identity_keeps_journal(self):
        with self.probe(): self.assertEqual(self.awg3.recovery(),'unknown')
        self.assertEqual(self.calls,[])
        self.assertTrue(self.awg3.JOURNAL.exists(),'журнал обязан остаться блокировать мутации')
@unittest.skipUnless(hasattr(os,'mkfifo'),'POSIX filesystem semantics')
class PermissionsKnownHosts(unittest.TestCase):
    """Приёмка R05 аудита v2.8.5: обычный файл чиним, всё прочее отвергаем БЫСТРО.

    Тест исполняет не копию, а сам фрагмент из permissions.sh — иначе он
    доказывал бы свойства текста, которого на ноде нет.
    """
    def setUp(self):
        src=(ROOT/'watchdog'/'awg-cascade-permissions.sh').read_text(encoding='utf-8').splitlines()
        start=next(i for i,l in enumerate(src) if l.startswith('python3 - ') and 'known_hosts' in l)
        end=next(i for i,l in enumerate(src[start:],start) if l.strip()=='PYEOF')
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        self.dir=Path(tmp.name)
        self.script=self.dir/'snippet.py'
        self.script.write_text('\n'.join(src[start+1:end]),encoding='utf-8')
    def probe(self,path):
        import getpass
        # Таймаут здесь — и есть проверка: до фикса FIFO вешал open навсегда.
        return subprocess.run([sys.executable,str(self.script),str(path),getpass.getuser()],
                              capture_output=True,text=True,timeout=10)
    def test_regular_file_is_fixed(self):
        target=self.dir/'known_hosts';target.write_text('host key\n');os.chmod(target,0o644)
        self.assertEqual(self.probe(target).returncode,0)
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode),0o600)
    def test_fifo_is_refused_without_hanging(self):
        target=self.dir/'fifo';os.mkfifo(target)
        result=self.probe(target)      # TimeoutExpired здесь = возврат дефекта
        self.assertEqual(result.returncode,1)
        self.assertIn('не обычный файл',result.stderr)
    def test_symlink_is_refused(self):
        victim=self.dir/'victim';victim.write_text('x');os.chmod(victim,0o644)
        target=self.dir/'link';os.symlink(victim,target)
        self.assertEqual(self.probe(target).returncode,1)
        self.assertEqual(stat.S_IMODE(os.stat(victim).st_mode),0o644,'цель ссылки не трогаем')
    def test_hardlink_is_refused(self):
        victim=self.dir/'victim';victim.write_text('x')
        target=self.dir/'hard';os.link(victim,target)
        result=self.probe(target)
        self.assertEqual(result.returncode,1)
        self.assertIn('жёстких ссылок',result.stderr)
class ProvisionFinish(unittest.TestCase):
    """Завершающие шаги provisioning не выдаются за полный успех (R06 аудита v2.8.5)."""
    def run_finish(self,proto,stamp,reboot):
        pr=module('provision')
        pr.apply_exit_proto=lambda iface:proto
        pr.write_version_stamp=lambda ssh:stamp
        pr.exit_reboot=lambda ssh,record:reboot
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        path=Path(tmp.name)/'record.json';path.write_text('{}')
        code=0;out=io.StringIO()
        with contextlib.redirect_stdout(out):
            try: pr.finish([],{'exit_index':2},path)
            except SystemExit as exc: code=exc.code
        return json.loads(out.getvalue()),code,path.exists()
    def test_version_stamp_failure_is_not_success(self):
        result,code,record=self.run_finish('on','failed: не записан','not-needed')
        self.assertEqual(code,2,result)
        self.assertEqual(result['incomplete'],['version_stamp'])
        self.assertFalse(record,'журнал операции всё равно удаляется: exit добавлен')
    def test_skipped_is_not_a_failure(self):
        result,code,_=self.run_finish('on','skipped: у самой RU нет version-stamp','not-needed')
        self.assertEqual(code,0);self.assertEqual(result['incomplete'],[])
    def test_all_steps_reported(self):
        result,code,_=self.run_finish('failed: остался на 2.0','failed: не записан','failed: не поднялся')
        self.assertEqual(code,2)
        self.assertEqual(result['incomplete'],['proto','reboot','version_stamp'])
    def test_clean_run_stays_quiet(self):
        result,code,_=self.run_finish('on','v2.8.6 abc123','done: ядро 6.8.0-139-generic')
        self.assertEqual(code,0);self.assertEqual(result['incomplete'],[]);self.assertTrue(result['ok'])
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
