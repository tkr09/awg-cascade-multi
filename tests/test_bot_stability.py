import asyncio
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'bot'))
import common
import asyncssh

class HostKeys(unittest.TestCase):
    def test_markers_hashes_and_missing_newline(self):
        with tempfile.TemporaryDirectory() as d,patch.object(common,'KNOWN_HOSTS_PATH',Path(d)/'known_hosts'):
            key=asyncssh.generate_private_key('ssh-ed25519').convert_to_public()
            pub=key.export_public_key().decode().strip()
            common.KNOWN_HOSTS_PATH.write_text('@revoked [192.0.2.1]:2222 '+pub)
            self.assertTrue(common.host_key_known('192.0.2.1',2222))
            with self.assertRaises(ValueError): common._host_key_remember('192.0.2.1',2222,key)
            common.KNOWN_HOSTS_PATH.write_text('192.0.2.2 '+pub)
            common._host_key_remember('192.0.2.3',22,key)
            self.assertEqual(len(common.KNOWN_HOSTS_PATH.read_text().splitlines()),2)
            self.assertTrue(common.host_key_known('192.0.2.2'))
            self.assertTrue(common.host_key_known('192.0.2.3'))
    def test_write_failure_does_not_accept_unpinned_host(self):
        with tempfile.TemporaryDirectory() as d,patch.object(common,'KNOWN_HOSTS_PATH',Path(d)/'known_hosts'):
            key=asyncssh.generate_private_key('ssh-ed25519').convert_to_public()
            with patch.object(common,'_write_known_hosts',side_effect=OSError('disk')),self.assertRaises(OSError):
                common._host_key_remember('192.0.2.1',22,key)

class AsyncOperations(unittest.IsolatedAsyncioTestCase):
    async def test_timeout_kills_process_group(self):
        start=time.monotonic()
        _,error,rc=await common.local_run('/bin/sh','-c','sleep 60 & wait',timeout=0.1)
        self.assertEqual(rc,-1);self.assertIn('Timeout',error);self.assertLess(time.monotonic()-start,3)
    async def test_broker_concurrent_edits_do_not_block_loop(self):
        root=Path(__file__).resolve().parents[1]
        source=str(root/'watchdog/awg-cascade-control.py')
        script='import importlib.util,sys,pathlib,os; s=importlib.util.spec_from_file_location("c",sys.argv[1]); c=importlib.util.module_from_spec(s); s.loader.exec_module(c); c.BASE=pathlib.Path(sys.argv[2]); c.bot_gid=lambda: os.getgid(); c.edit_data("peers")'
        create=asyncio.create_subprocess_exec
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'peers.json'
            p.write_text(json.dumps([{'name':'test','ip':'10.20.0.2','iface':'awg0','pubkey':base64.b64encode(b'x'*32).decode(),'note':'0'}]))
            async def spawn(*args,**kwargs): return await create(sys.executable,'-c',script,source,d,**kwargs)
            async def increment():
                async with common.peers_locked() as peers:
                    await asyncio.sleep(0.01)
                    peers[0]['note']=str(int(peers[0]['note'])+1)
            ticks=0
            async def ticker():
                nonlocal ticks
                for _ in range(20): await asyncio.sleep(0.005);ticks+=1
            with patch.object(common.asyncio,'create_subprocess_exec',side_effect=spawn):
                await asyncio.gather(*(increment() for _ in range(8)),ticker())
            self.assertEqual(json.loads(p.read_text())[0]['note'],'8');self.assertEqual(ticks,20)

if __name__=='__main__': unittest.main(verbosity=2)
