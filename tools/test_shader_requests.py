"""Exercise the real worker and Git publication protocol against disposable repositories.
No Codex API calls or production pushes. The command fixtures retain invocation evidence.
"""
import base64
import importlib.util
import json
import os
import fcntl
import socket
from unittest.mock import patch
from pathlib import Path
import select
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'HolodeckCore/Sources/HolodeckCore/Resources/shader_requests.py'
spec = importlib.util.spec_from_file_location('shader_requests', SCRIPT)
worker_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker_module)


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1280, 720, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\x44\x88\xcc' * 1280) * 720)) + chunk(b'IEND', b'')


CODEX = r'''#!/usr/bin/env python3
import json, sys
from pathlib import Path
args=sys.argv[1:]
def value(flag): return args[args.index(flag)+1]
schema_path=Path(value('--output-schema')); directory=schema_path.parent
schema=json.loads(schema_path.read_text()); prompt=sys.stdin.read()
record={'args':args,'prompt':prompt}
with (directory/'invocations.jsonl').open('a') as log: log.write(json.dumps(record)+'\n')
for i,arg in enumerate(args):
    if arg=='--image': assert Path(args[i+1]).is_file()
assert args[-2:]==['--','-']
if 'status' in schema['properties']:
    assert value('--sandbox')=='workspace-write'
    count_file=directory/'implementation-count'
    count=int(count_file.read_text())+1 if count_file.exists() else 1
    count_file.write_text(str(count))
    request=json.loads((directory/'request.json').read_text()); mode=request['prompt']
    sid='beta' if mode=='named' else 'alpha'
    if (directory/'repair.json').exists() and mode=='edit':mode='unchanged'
    kind='edited'; changed=mode!='unchanged'; status='completed'; question=''
    if mode=='ambiguous' and not (directory/'answer.json').exists():
        status='needsClarification'; changed=False; question='Edit Alpha or create a new shader?'
    elif (directory/'repair.json').exists() and mode=='new':
        sid='gamma';kind='new';Path('shaders/gamma/body.metal').write_text('REPAIRED\n')
    elif mode=='new' or not Path('shaders/alpha/body.metal').exists():
        sid='gamma';kind='new'
        Path('shaders/gamma').mkdir(exist_ok=True)
        Path('shaders/gamma/body.metal').write_text('NEW\n')
        meta=json.loads(Path('shaders/beta/metadata.json').read_text());meta['id']=sid;meta['discovery']={'tags':['fluid'],'moods':['calm'],'motion':'steady'}
        Path('shaders/gamma/metadata.json').write_text(json.dumps(meta))
        index=json.loads(Path('index.json').read_text());
        if sid not in index['shaders']: index['shaders'].append(sid)
        Path('index.json').write_text(json.dumps(index))
    elif changed:
        Path(f'shaders/{sid}/body.metal').write_text('EDIT\n')
        if mode=='helper': Path('shared/common.metal').write_text('HELPER\n')
        if mode=='repair' and count==1: Path(f'shaders/{sid}/body.metal').write_text('BAD\n')
    if status=='completed':
        index=json.loads(Path('index.json').read_text())
        if sid not in index['shaders']:index['shaders'].append(sid);Path('index.json').write_text(json.dumps(index))
    output={'status':status,'outputKind':kind,'shaderID':sid,'changed':changed,'summary':'No change necessary' if not changed else 'Implement request','approximations':['Audio approximated by time'] if mode=='approximate' else [],'question':question,'options':['Edit','Create'] if question else []}
    print(json.dumps({'type':'thread.started','thread_id':'00000000-0000-0000-0000-000000000042'}),flush=True)
else:
    assert value('--sandbox')=='read-only'
    assert 'resume' not in args
    failed = directory/'failed-review'
    fail_once=(directory/'request.json').exists() and json.loads((directory/'request.json').read_text())['prompt']=='visual-repair' and not failed.exists()
    if fail_once: failed.write_text('failed')
    output={'passed':not fail_once,'reason':'Fixture image and source review passed','evidenceDigest':schema['properties']['evidenceDigest']['enum'][0]}
Path(value('--output-last-message')).write_text(json.dumps(output))
'''
CHECKER_PIN = {'repository':'hbmartin/HolodeckShaderCheck','version':'1.0.0','interfaceVersion':1,'sourceCommit':'a'*40,'sha256':'b'*64}
TOOL = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
if args == ['--version']:
    print('holodeck-shader-tool 1.1.0'); raise SystemExit(0)
if args[:2] == ['library', 'artifact-info']:
    print(json.dumps(CHECKER_PIN)); raise SystemExit(0)
if args[:2] == ['library', 'info']:
    print(json.dumps({'interfaceVersion':1,'checkerVersion':'1.0.0'})); raise SystemExit(0)
if args[:2] == ['library', 'validate']:
    assert ('--compile' in args or '--gpu-only' in args) and '--python' in args
    fixture = Path('.fixture-validation.json')
    config = json.loads(fixture.read_text()) if fixture.exists() else {}
    if config.get('fail') or (config.get('outage') and Path(config['outage']).exists()): raise SystemExit(1)
    if config.get('signalIfEdited') and 'EDIT' in Path('shaders/alpha/body.metal').read_text(): os.kill(os.getpid(),signal.SIGTERM)
    if config.get('writeIgnoredOutput'): Path('ignored/host-output').write_text(str(time.time_ns()))
    if any('BAD' in p.read_text() for p in Path('shaders').glob('*/body.metal')): raise SystemExit(1)
    raise SystemExit(0)
Path(sys.argv[3]).write_bytes((Path(__file__).parent/'frame.png').read_bytes())
'''
TOOL = TOOL.replace('CHECKER_PIN',repr(CHECKER_PIN))
LIBRARY = '''import sys\nfrom pathlib import Path\nif any('BAD' in p.read_text() for p in Path('shaders').glob('*/body.metal')): sys.exit(1)\n'''


class ShaderRequestWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.remote = self.base/'origin.git'
        self.git(self.base, 'init', '--bare', self.remote)
        self.root = self.base/'checkout'
        self.git(self.base, 'clone', self.remote, self.root)
        self.git(self.root, 'checkout', '-b', 'main')
        self.git(self.root, 'config', 'user.name', 'Request Tests')
        self.git(self.root, 'config', 'user.email', 'request-tests@example.invalid')
        (self.root/'shared').mkdir()
        for part in ('common','fragment'): (self.root/f'shared/{part}.metal').write_text(part.upper()+'\n')
        for sid in ('alpha','beta'):
            (self.root/f'shaders/{sid}').mkdir(parents=True)
            (self.root/f'shaders/{sid}/body.metal').write_text(sid.upper()+'\n')
            (self.root/f'shaders/{sid}/metadata.json').write_text(json.dumps({'id':sid,'shared':['common','fragment']}))
        (self.root/'index.json').write_text(json.dumps({'defaultShaderID':'alpha','shaders':['alpha','beta'],'collections':[]}))
        (self.root/'shader_checker.lock.json').write_text(json.dumps(CHECKER_PIN))
        (self.root/'tools').mkdir()
        (self.root/'tools/library.py').write_text(LIBRARY)
        (self.root/'tools/test_authoring.py').write_text('import unittest\nclass Tests(unittest.TestCase):\n def test_authoring(self): self.assertTrue(True)\n')
        (self.root/'authoring.json').write_text(json.dumps({"schemaVersion":1,"sourceRequirements":{"shaders/alpha/body.metal":["Author"]},"upstreamRequirements":{"source":{"license":"MIT"}},"regressionProfiles":[]}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Baseline');self.git(self.root,'push','-u','origin','main')
        self.base_sha=self.git(self.root,'rev-parse','HEAD').strip()
        self.codex=self.base/'codex'; self.codex.write_text(CODEX); self.codex.chmod(0o755)
        self.tool=self.base/'tool';self.tool.write_text(TOOL);self.tool.chmod(0o755)
        (self.base/'frame.png').write_bytes(png())
        self.config={'repository':str(self.root),'git':shutil.which('git'),'python':sys.executable,'codex':str(self.codex),'shaderTool':str(self.tool),'model':'fixture','reasoning':'high','enabled':True}
        self.config_path=self.base/'config.json';self.config_path.write_text(json.dumps(self.config))
        self.job=self.base/'job';self.job.mkdir()
        self.request={'id':str(uuid.uuid4()),'purpose':'creative','origin':'manual','prompt':'edit','context':{'shaderID':'alpha','source':'COMMON\nALPHA\nFRAGMENT\n','sourceHash':'captured-old-version','screenshot':base64.b64encode(png()).decode()}}
        self.save_request()

    @staticmethod
    def git(cwd,*args):
        result=subprocess.run(['git',*[str(a) for a in args]],cwd=cwd,capture_output=True,text=True,check=True)
        return result.stdout

    def save_request(self): (self.job/'request.json').write_text(json.dumps(self.request))

    def run_worker(self, callback=None, accept=True, mode="run"):
        process=subprocess.Popen([sys.executable,'-u',str(SCRIPT),mode,str(self.config_path),str(self.job)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1'))
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        events=[]
        # TextIO buffering requires readline rather than select for every buffered JSONL event.
        while True:
            line=process.stdout.readline()
            if not line: break
            event=json.loads(line);events.append(event)
            if callback: callback(event)
            if event['event']=='preparePublication':
                process.stdin.write(json.dumps({'ok':accept})+'\n');process.stdin.flush()
        code=process.wait(timeout=30)
        stderr=process.stderr.read()
        process.stdin.close();process.stdout.close();process.stderr.close()
        if code==0: self.assertFalse(stderr,stderr)
        return code,events

    def result(self,events): return next(e['result'] for e in events if e['event']=='result')

    def invocations(self): return [json.loads(line) for line in (self.job/'invocations.jsonl').read_text().splitlines()]

    def test_edit_commit_push_and_idempotent_recovery(self):
        code,events=self.run_worker();self.assertEqual(code,0,events)
        result=self.result(events);self.assertEqual(result['outputKind'],'edited');self.assertEqual(result['shaderID'],'alpha')
        self.assertEqual(self.git(self.root,'rev-parse','origin/main').strip(),result['commitSHA'])
        self.assertIn(self.request['id'],self.git(self.root,'log','-1','--format=%B'))
        self.assertEqual(len([e for e in events if e['event']=='preparePublication']),1)
        count=len(self.invocations());code,again=self.run_worker();self.assertEqual(code,0,again)
        self.assertEqual(self.result(again)['commitSHA'],result['commitSHA']);self.assertEqual(len(self.invocations()),count)
        self.assertEqual(self.git(self.root,'rev-list','--count','origin/main').strip(),'2')

    def test_lost_result_journal_after_push_does_not_duplicate_commit(self):
        code,events=self.run_worker();self.assertEqual(code,0,events)
        (self.job/'worker-result.json').unlink()
        code,recovered=self.run_worker();self.assertEqual(code,0,recovered)
        self.assertEqual(self.result(recovered)['commitSHA'],self.result(events)['commitSHA'])
        self.assertEqual(self.git(self.root,'rev-list','--count','origin/main').strip(),'2')

    def test_new_named_approximate_and_unchanged(self):
        for mode in ('new','named','approximate','unchanged'):
            with self.subTest(mode=mode):
                self.git(self.root,'reset','--hard',self.base_sha);self.git(self.root,'push','--force','origin','main')
                shutil.rmtree(self.job);self.job.mkdir();self.request['prompt']=mode;self.save_request()
                code,events=self.run_worker();self.assertEqual(code,0,events);result=self.result(events)
                self.assertEqual(result['shaderID'],'gamma' if mode=='new' else 'beta' if mode=='named' else 'alpha')
                self.assertEqual(result['outputKind'],'new' if mode=='new' else 'edited')
                if mode=='approximate':self.assertTrue(result['approximations'])
                if mode=='unchanged':self.assertFalse(result['changed']);self.assertEqual(result['commitSHA'],self.base_sha)

    def test_clarification_parks_clean_then_resumes_explicit_session(self):
        self.request['prompt']='ambiguous';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertTrue(any(e['event']=='clarification' for e in events));self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')
        (self.job/'answer.json').write_text(json.dumps('Edit Alpha'))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        args=self.invocations()[1]['args'];self.assertEqual(args[args.index('resume')+1],'00000000-0000-0000-0000-000000000042')

    def test_compilation_failure_repairs_and_keeps_attempt_evidence(self):
        self.request['prompt']='repair';self.save_request();code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertTrue(any(e.get('stage')=='repairing' for e in events))
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'EDIT\n')
        self.assertEqual((self.job/'implementation-count').read_text(),'2')

    def test_helper_changes_review_every_affected_shader(self):
        self.request['prompt']='helper';self.save_request();code,events=self.run_worker();self.assertEqual(code,0,events)
        manifests=list((self.job/'evidence').glob('*/manifest.json'));self.assertEqual(len(manifests),1)
        evidence=json.loads(manifests[0].read_text());self.assertEqual({e['shaderID'] for e in evidence},{'alpha','beta'})
        self.assertEqual(len(evidence),12)
        reviews=[i for i in self.invocations() if 'read-only' in i['args']];self.assertEqual(len(reviews),2)
        self.assertTrue(all(i['args'].count('--image')==7 for i in reviews))

    def test_failed_preparation_never_pushes_and_discards_unpublished_work(self):
        code,events=self.run_worker(accept=False);self.assertNotEqual(code,0);self.assertTrue(any(e['event']=='failure' for e in events))
        self.assertEqual(self.git(self.root,'rev-parse','origin/main').strip(),self.base_sha)
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')
        self.assertFalse((self.job/'changes.patch').exists())

    def test_push_race_preserves_intervening_shader_and_reverifies(self):
        upstream=self.base/'upstream';self.git(self.base,'clone','-b','main',self.remote,upstream)
        self.git(upstream,'config','user.name','Upstream');self.git(upstream,'config','user.email','upstream@example.invalid')
        advances=[]
        def race(event):
            if event['event']=='preparePublication' and not advances:
                (upstream/'shaders/beta/body.metal').write_text('INTERVENING\n');self.git(upstream,'add','--all');self.git(upstream,'commit','-m','Intervening edit');self.git(upstream,'push','origin','main');advances.append(True)
        code,events=self.run_worker(race);self.assertEqual(code,0,events)
        self.assertEqual((self.root/'shaders/beta/body.metal').read_text(),'INTERVENING\n')
        self.assertEqual(len(list((self.job/'evidence').glob('*/manifest.json'))),2)
        self.assertTrue(any(e['event']=='discardPublication' for e in events))

    def test_boundary_rejects_other_bodies_logic_and_inconsistent_identity(self):
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
        outcome={'shaderID':'alpha','outputKind':'edited','changed':True}
        (self.root/'shaders/alpha/body.metal').write_text('EDIT\n')
        (self.root/'shaders/beta/body.metal').write_text('OTHER\n')
        with self.assertRaises(worker_module.CandidateError):worker.scope(outcome)
        self.git(self.root,'reset','--hard',self.base_sha)
        (self.root/'authoring.json').write_text(json.dumps({"schemaVersion":2,"sourceRequirements":{"shaders/alpha/body.metal":["Author"]},"upstreamRequirements":{"source":{"license":"MIT"}},"regressionProfiles":[]}))
        with self.assertRaisesRegex(worker_module.CandidateError,'schema'):worker.scope()
        self.git(self.root,'reset','--hard',self.base_sha)
        with self.assertRaisesRegex(worker_module.CandidateError,'identity'):worker.scope({'shaderID':'alpha','outputKind':'new','changed':True})
        (self.root/'tools/library.py').write_text('pass\n')
        with self.assertRaisesRegex(worker_module.CandidateError,'Forbidden'):worker.scope()

    def test_visual_repair_keeps_failed_frames_and_independent_verdicts(self):
        self.request['prompt']='visual-repair';self.save_request();code,events=self.run_worker();self.assertEqual(code,0,events)
        verdicts=[json.loads(p.read_text()) for p in (self.job/'evidence').glob('*/alpha/verdict.json')]
        self.assertEqual(len(verdicts),2);self.assertEqual([v['passed'] for v in verdicts],[False,True])
        self.assertEqual(len(list((self.job/'evidence').glob('*/alpha/*/*.png'))),12)

    def test_removed_context_is_recreated_under_unused_id(self):
        self.git(self.root,'rm','-r','shaders/alpha')
        (self.root/'index.json').write_text(json.dumps({'defaultShaderID':'beta','shaders':['beta'],'collections':[]}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Remove captured shader');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertEqual(code,0,events)
        result=self.result(events);self.assertEqual(result['shaderID'],'gamma');self.assertEqual(result['outputKind'],'new')
        self.assertFalse((self.root/'shaders/alpha').exists())

    def test_stale_performance_evidence_optimizes_latest_without_tv_update(self):
        self.request.update(purpose='performance',origin='automatic',performance={'sourceHash':'old','framesPerSecond':[20]*10,'gpuMilliseconds':[40],'device':'TV'})
        self.save_request()
        (self.root/'shaders/alpha/body.metal').write_text('INTERVENING LATEST\n');self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Latest version');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertEqual(code,0,events)
        first=self.invocations()[0]
        self.assertIn('captured-old-version',first['prompt'])
        evidence=json.loads(next((self.job/'evidence').glob('*/manifest.json')).read_text())
        before=next(e for e in evidence if e['variant']=='before')
        self.assertEqual(before['sourceHash'],worker_module.digest('COMMON\nINTERVENING LATEST\nFRAGMENT\n'))

    def test_data_only_attribution_update_is_allowed_but_not_weakened(self):
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
        (self.root/'authoring.json').write_text(json.dumps({"schemaVersion":1,"sourceRequirements":{"shaders/alpha/body.metal":["Author","New notice"]},"upstreamRequirements":{"source":{"license":"MIT"}},"regressionProfiles":[]}))
        worker.scope()
        (self.root/'authoring.json').write_text(json.dumps({"schemaVersion":1,"sourceRequirements":{"shaders/alpha/body.metal":[]},"upstreamRequirements":{"source":{"license":"MIT"}},"regressionProfiles":[]}))
        with self.assertRaisesRegex(worker_module.CandidateError,'weakened'):worker.scope()

    def test_activation_repair_keeps_new_classification_and_same_request(self):
        self.request['prompt']='new';self.save_request();code,events=self.run_worker();self.assertEqual(code,0,events)
        first=self.result(events)
        (self.job/'repair.json').write_text(json.dumps({'shaderID':'gamma','diagnostic':'Activation failed'}))
        code,repaired=self.run_worker();self.assertEqual(code,0,repaired)
        result=self.result(repaired);self.assertEqual(result['outputKind'],'new');self.assertEqual(result['shaderID'],'gamma')
        self.assertNotEqual(result['commitSHA'],first['commitSHA'])
        self.assertEqual(self.git(self.root,'log','--format=%B').count(self.request['id']),2)

    def test_unchanged_activation_repair_keeps_prior_change_without_empty_commit(self):
        code,events=self.run_worker();self.assertEqual(code,0,events);first=self.result(events)
        (self.job/'repair.json').write_text(json.dumps({'shaderID':'alpha','diagnostic':'Retry activation'}))
        code,repaired=self.run_worker();self.assertEqual(code,0,repaired)
        result=self.result(repaired);self.assertTrue(result['changed']);self.assertEqual(result['commitSHA'],first['commitSHA'])
        self.assertEqual(self.git(self.root,'rev-list','--count','origin/main').strip(),'2')

    def test_editing_unlisted_existing_shader_keeps_id_and_publishes_it(self):
        (self.root/'index.json').write_text(json.dumps({'defaultShaderID':'alpha','shaders':['alpha'],'collections':[]}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Unlist beta');self.git(self.root,'push','origin','main')
        self.request['prompt']='named';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        result=self.result(events);self.assertEqual(result['outputKind'],'edited');self.assertEqual(result['shaderID'],'beta')
        self.assertEqual(json.loads((self.root/'index.json').read_text())['shaders'],['alpha','beta'])

    def test_visual_source_hashes_preserve_exact_utf8_and_crlf_bytes(self):
        for name,value in [('shared/common.metal',b'COMMON\r\n'),('shaders/alpha/body.metal',b'ALPHA\r\n'),('shared/fragment.metal',b'FRAGMENT\r\n')]:
            (self.root/name).write_bytes(value)
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','CRLF source');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertEqual(code,0,events)
        evidence=json.loads(next((self.job/'evidence').glob('*/manifest.json')).read_text())
        before=next(e for e in evidence if e['shaderID']=='alpha' and e['variant']=='before')
        after=next(e for e in evidence if e['shaderID']=='alpha' and e['variant']=='after')
        self.assertEqual(before['sourceHash'],worker_module.digest(b'COMMON\r\nALPHA\r\nFRAGMENT\r\n'))
        source=b''.join((self.root/name).read_bytes() for name in ('shared/common.metal','shaders/alpha/body.metal','shared/fragment.metal'))
        self.assertEqual(after['sourceHash'],worker_module.digest(source))
        self.assertEqual(Path(after['path']).parent.joinpath('source.metal').read_bytes(),source)

    def test_external_dirty_checkout_is_preserved(self):
        (self.root/'shaders/alpha/body.metal').write_text('USER WORK\n')
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'USER WORK\n')

    def test_host_skips_all_local_hooks_without_changing_configuration(self):
        hooks=self.base/'configured-hooks';hooks.mkdir()
        for name in ('post-checkout','pre-commit','prepare-commit-msg','commit-msg','post-commit','pre-push'):
            hook=hooks/name
            hook.write_text('#!/bin/sh\ntouch "'+str(self.base/'hook-ran')+'"\nexit 1\n');hook.chmod(0o755)
        self.git(self.root,'config','core.hooksPath',str(hooks))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertFalse((self.base/'hook-ran').exists())
        self.assertEqual(self.git(self.root,'config','core.hooksPath').strip(),str(hooks))
        result=self.result(events)
        self.assertEqual(self.git(self.root,'show',result['commitSHA']+':shaders/alpha/body.metal'),'EDIT\n')
        self.assertTrue((self.job/'candidate-manifest.json').exists())

    def test_git_clean_filter_cannot_publish_different_bytes(self):
        (self.root/'.gitattributes').write_text('shaders/*/body.metal filter=request-fixture\n')
        self.git(self.root,'add','.gitattributes');self.git(self.root,'commit','-m','Filter declaration');self.git(self.root,'push','origin','main')
        baseline=self.git(self.root,'rev-parse','HEAD').strip()
        executable=self.base/'clean-filter'
        executable.write_text('#!'+sys.executable+'\nimport sys\nsys.stdout.write(sys.stdin.read().replace("EDIT", "FILTERED"))\n');executable.chmod(0o755)
        self.git(self.root,'config','filter.request-fixture.clean',str(executable))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertTrue(any('Committed tree differs' in e.get('message','') for e in events))
        self.assertEqual(self.git(self.root,'rev-parse','origin/main').strip(),baseline)
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')

    def test_staged_forbidden_file_and_new_source_manifest(self):
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
        before=worker.fingerprint()
        (self.root/'tools/library.py').write_text('pass\n');self.git(self.root,'add','tools/library.py')
        with self.assertRaisesRegex(worker_module.CandidateError,'Forbidden'):worker.scope()
        self.assertNotEqual(worker.fingerprint(),before)
        self.git(self.root,'reset','--hard',self.base_sha)
        self.request['prompt']='new';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        manifest=json.loads((self.job/'candidate-manifest.json').read_text())
        self.assertEqual(manifest['shaders/gamma/body.metal']['hash'],worker_module.digest(b'NEW\n'))

    def test_failed_activation_repair_cleans_owned_changes_and_preserves_publication(self):
        code,events=self.run_worker();self.assertEqual(code,0,events)
        previous=self.result(events)
        checkpoint=json.loads((self.job/'checkpoint.json').read_text());checkpoint.pop('attemptID')
        (self.job/'checkpoint.json').write_text(json.dumps(checkpoint))
        (self.job/'repair.json').write_text(json.dumps({'shaderID':'alpha','diagnostic':'Activation failure'}))
        self.codex.write_text('#!'+sys.executable+'\nfrom pathlib import Path\nPath("shaders/alpha/body.metal").write_text("UNPUBLISHED\\n")\nraise SystemExit(1)\n')
        code,failed=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')
        self.assertEqual(self.git(self.root,'rev-parse','origin/main').strip(),previous['commitSHA'])
        self.assertFalse((self.root/'.git/holodeck-request-owner.json').exists())
        self.assertEqual(json.loads((self.job/'worker-result.json').read_text()),previous)
        self.codex.write_text(CODEX)
        self.job=self.base/'next-request';self.job.mkdir()
        self.request['id']=str(uuid.uuid4());self.request['prompt']='named';self.save_request()
        code,next_events=self.run_worker();self.assertEqual(code,0,next_events)

    def test_activation_repair_lost_push_ack_recovers_without_duplicate_commit(self):
        self.request['prompt']='new';self.save_request();code,events=self.run_worker();self.assertEqual(code,0,events)
        previous=self.result(events)
        (self.job/'repair.json').write_text(json.dumps({'attemptID':str(uuid.uuid4()),'shaderID':'gamma','diagnostic':'Activation failure'}))
        original_git=self.config['git'];wrapper=self.base/'git-lost-ack'
        wrapper.write_text('#!'+sys.executable+'\nimport os,signal,subprocess,sys\nresult=subprocess.run(['+repr(original_git)+',*sys.argv[1:]])\nif "push" in sys.argv and result.returncode==0: os.kill(os.getppid(),signal.SIGKILL)\nraise SystemExit(result.returncode)\n');wrapper.chmod(0o755)
        self.config['git']=str(wrapper);self.config_path.write_text(json.dumps(self.config))
        code,interrupted=self.run_worker();self.assertNotEqual(code,0)
        current=self.git(self.root,'rev-parse','origin/main').strip();self.assertNotEqual(current,previous['commitSHA'])
        count=len(self.invocations())
        self.config['git']=original_git;self.config_path.write_text(json.dumps(self.config))
        code,recovered=self.run_worker();self.assertEqual(code,0,recovered)
        self.assertEqual(self.result(recovered)['commitSHA'],current)
        self.assertEqual(self.result(recovered)['outputKind'],'new')
        self.assertEqual(len(self.invocations()),count)
        self.assertEqual(self.git(self.root,'rev-list','--count','origin/main').strip(),'3')
        self.assertFalse((self.job/'repair.json').exists())

    def test_failed_pristine_baseline_does_not_invoke_codex_or_restore_patch(self):
        (self.root/'.fixture-validation.json').write_text(json.dumps({'fail':True}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Broken baseline');self.git(self.root,'push','origin','main')
        (self.job/'untracked.json').write_text(json.dumps({'shaders/gamma/body.metal':base64.b64encode(b'PARKED').decode()}))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertFalse((self.job/'invocations.jsonl').exists())
        self.assertFalse((self.root/'shaders/gamma/body.metal').exists())
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')

    def test_host_outage_after_baseline_is_operational_without_another_codex_call(self):
        outage=self.base/'host-outage'
        (self.root/'.fixture-validation.json').write_text(json.dumps({'outage':str(outage)}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Outage-aware fixture');self.git(self.root,'push','origin','main')
        self.codex.write_text(CODEX.replace("if status=='completed':", "Path("+repr(str(outage))+ ").touch()\n    if status=='completed':"))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual((self.job/'implementation-count').read_text(),'1')
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')
        self.assertTrue(any('Baseline or host validation failed' in e.get('message','') for e in events))

    def test_candidate_defects_continue_without_attempt_limit(self):
        self.codex.write_text(CODEX.replace("mode=='repair' and count==1", "mode=='repair' and count<5"))
        self.request['prompt']='repair';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual((self.job/'implementation-count').read_text(),'5')
        self.assertEqual(len([e for e in events if e.get('stage')=='repairing']),4)

    def test_new_bad_remote_baseline_fails_raced_request_without_reimplementation(self):
        upstream=self.base/'upstream';self.git(self.base,'clone','-b','main',self.remote,upstream)
        self.git(upstream,'config','user.name','Upstream');self.git(upstream,'config','user.email','upstream@example.invalid')
        advanced=[]
        def race(event):
            if event['event']=='preparePublication' and not advanced:
                (upstream/'.fixture-validation.json').write_text(json.dumps({'fail':True}))
                self.git(upstream,'add','--all');self.git(upstream,'commit','-m','Broken new baseline');self.git(upstream,'push','origin','main');advanced.append(True)
        code,events=self.run_worker(race);self.assertNotEqual(code,0)
        self.assertEqual((self.job/'implementation-count').read_text(),'1')
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')

    def test_render_host_outage_does_not_repair_shader_indefinitely(self):
        outage=self.base/'gpu-outage'
        self.tool.write_text(TOOL.replace("Path(sys.argv[3]).write_bytes", "if Path("+repr(str(outage))+").exists(): raise SystemExit(1)\nPath(sys.argv[3]).write_bytes"))
        self.codex.write_text(CODEX.replace("if status=='completed':", "Path("+repr(str(outage))+ ").touch()\n    if status=='completed':"))
        self.request['prompt']='new';self.save_request()
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual((self.job/'implementation-count').read_text(),'1')
        self.assertEqual(self.git(self.root,'status','--porcelain').strip(),'')
        self.assertTrue(any('Baseline rendering or host GPU failed' in e.get('message','') for e in events))

    def test_lost_ack_adopts_verified_commit_when_workspace_is_newer_main(self):
        code,events=self.run_worker();self.assertEqual(code,0,events);published=self.result(events)
        count=len(self.invocations());(self.job/'worker-result.json').unlink()
        (self.root/'shaders/beta/body.metal').write_text('NEWER MAIN\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Later unrelated shader');self.git(self.root,'push','origin','main')
        code,recovered=self.run_worker();self.assertEqual(code,0,recovered)
        self.assertEqual(self.result(recovered)['commitSHA'],published['commitSHA'])
        self.assertEqual((self.root/'shaders/beta/body.metal').read_text(),'NEWER MAIN\n')
        self.assertEqual(len(self.invocations()),count)


    def ignored_worker(self):
        (self.root/'.gitignore').write_text('ignored/\n')
        self.git(self.root,'add','.gitignore');self.git(self.root,'commit','-m','Ignore scratch')
        self.git(self.root,'push','origin','main')
        directory=self.root/'ignored';directory.mkdir()
        (directory/'original').write_bytes(b'original');(directory/'original').chmod(0o600)
        (directory/'deleted').write_bytes(b'keep')
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request
        worker.save(base=self.git(self.root,'rev-parse','HEAD').strip())
        worker_module.write(worker.owner,{'id':self.request['id'],'directory':str(self.job)})
        return worker

    def test_ignored_changes_and_special_files_are_untouched_across_restart(self):
        worker=self.ignored_worker();frozen=worker.fingerprint()
        (self.root/'ignored/original').write_bytes(b'modified')
        (self.root/'ignored/deleted').unlink()
        (self.root/'ignored/new').write_bytes(b'new data')
        (self.root/'ignored/link').symlink_to(self.base/'nonexistent')
        os.mkfifo(self.root/'ignored/pipe')
        nested=self.root/'ignored/dep';nested.mkdir();self.git(nested,'init')
        sock=socket.socket(socket.AF_UNIX);self.addCleanup(sock.close)
        sock.bind(str(self.root/'ignored/socket'))
        legacy=self.job/'ignored-baseline.json';legacy.write_text('unreadable legacy metadata')
        (self.job/'ignored-backup').mkdir();(self.job/'ignored-backup/evidence').write_bytes(b'retained')
        worker.scope();self.assertEqual(worker.fingerprint(),frozen)
        restarted=worker_module.Worker(self.config,self.job);restarted.request=self.request;restarted.clean()
        self.assertEqual((self.root/'ignored/original').read_bytes(),b'modified')
        self.assertFalse((self.root/'ignored/deleted').exists())
        self.assertEqual((self.root/'ignored/new').read_bytes(),b'new data')
        self.assertTrue((self.root/'ignored/link').is_symlink())
        self.assertTrue((self.root/'ignored/pipe').exists());self.assertTrue((self.root/'ignored/socket').exists())
        self.assertTrue((nested/'.git').is_dir());self.assertFalse(worker.owner.exists())
        self.assertEqual(legacy.read_text(),'unreadable legacy metadata')
        self.assertEqual((self.job/'ignored-backup/evidence').read_bytes(),b'retained')

    def test_parking_preserves_ignored_edits_and_candidate_patch(self):
        worker=self.ignored_worker()
        (self.root/'ignored/original').write_bytes(b'modified')
        (self.root/'shaders/alpha/body.metal').write_text('PARKED\n')
        worker.park()
        self.assertEqual((self.root/'ignored/original').read_bytes(),b'modified')
        worker.restore_patch()
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'PARKED\n')

    def test_ignored_agent_edits_survive_clarification_success_and_failure(self):
        self.ignored_worker()
        self.codex.write_text(CODEX.replace("count_file.write_text(str(count))", "count_file.write_text(str(count)); Path('ignored/original').write_text('agent data'); Path('ignored/deleted').unlink(missing_ok=True); Path('ignored/new').write_text('agent output')"))
        self.request['prompt']='ambiguous';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertTrue(any(e['event']=='clarification' for e in events))
        self.assertEqual((self.root/'ignored/original').read_text(),'agent data')
        (self.job/'answer.json').write_text(json.dumps({'answer':'Edit'}))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertFalse((self.root/'ignored/deleted').exists())
        self.assertEqual((self.root/'ignored/new').read_text(),'agent output')
        (self.job/'repair.json').write_text(json.dumps({'attemptID':'failure','shaderID':'alpha','diagnostic':'fixture'}))
        self.codex.write_text(self.codex.read_text().replace("if status=='completed':", "Path('ignored/original').write_text('failed attempt data'); raise SystemExit(1)\n    if status=='completed':"))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual((self.root/'ignored/original').read_text(),'failed attempt data')

    def test_host_ignored_outputs_do_not_trigger_shader_repair(self):
        self.ignored_worker()
        (self.root/'.fixture-validation.json').write_text(json.dumps({'writeIgnoredOutput':True}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Validator output fixture');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual((self.job/'implementation-count').read_text(),'1')
        self.assertTrue((self.root/'ignored/host-output').exists())

    def test_ignored_publication_input_cannot_be_published(self):
        (self.root/'.gitignore').write_text('shaders/gamma/\n')
        self.git(self.root,'add','.gitignore');self.git(self.root,'commit','-m','Ignored new shader');self.git(self.root,'push','origin','main')
        before=self.git(self.root,'rev-parse','origin/main')
        self.request['prompt']='new';self.save_request()
        self.codex.write_text(CODEX.replace("count_file.write_text(str(count))", "count_file.write_text(str(count))\n    if count>1: raise SystemExit(1)"))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertTrue(any('Publication input must be included' in e.get('text','') for e in events),events)
        self.assertFalse(any(e['event']=='preparePublication' for e in events))
        self.assertEqual(self.git(self.root,'rev-parse','origin/main'),before)

    def detached_setup_worker(self):
        (self.root/'setup-fixture.txt').write_text('setup')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Setup fixture');self.git(self.root,'push','origin','main')
        worker=worker_module.Worker(self.config,self.job)
        worker.checkout_identity.write_text('checkout-fixture')
        owner={'id':self.request['id'],'directory':str(self.job.resolve())};worker_module.write(worker.owner,owner)
        self.config['detachedOwner']={'requestID':self.request['id'],'directory':str(self.job),'repository':str(self.root),'checkoutID':'checkout-fixture'}
        worker.codex=lambda *args,**kwargs:{'imageDescription':'Fixture'}
        worker.require_checker()
        return worker,owner

    def test_detached_owner_retires_only_after_successful_setup(self):
        worker,owner=self.detached_setup_worker()
        worker.require_checker()
        with patch.object(worker_module,'run',return_value=subprocess.CompletedProcess([],0,json.dumps({'interfaceVersion':1,'checkerVersion':'1.0.0'}),'')):
            worker.preflight()
        self.assertFalse(worker.owner.exists())
        self.assertEqual(worker.checkout_identity.read_text(),'checkout-fixture')

    def test_detached_setup_rejects_dirty_foreign_and_failed_checks(self):
        worker,owner=self.detached_setup_worker()
        (self.root/'shaders/alpha/body.metal').write_text('dirty')
        with self.assertRaisesRegex(worker_module.OperationalError,'uncommitted'): worker.preflight()
        self.assertEqual(json.loads(worker.owner.read_text()),owner)
        self.git(self.root,'checkout','--','shaders/alpha/body.metal')
        self.config['detachedOwner']['checkoutID']='foreign'
        with self.assertRaisesRegex(worker_module.OperationalError,'owned checkout'): worker.preflight()
        self.config['detachedOwner']['checkoutID']='checkout-fixture'
        with patch.object(worker_module,'run',side_effect=worker_module.OperationalError('fixture tools failed')):
            with self.assertRaisesRegex(worker_module.OperationalError,'fixture tools failed'): worker.preflight()
        self.assertEqual(json.loads(worker.owner.read_text()),owner)
        with (worker.gitdir/'holodeck-requests.lock').open('w') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):worker.preflight()

    def test_detached_setup_rejects_copy_and_move_with_identical_identity(self):
        original,owner=self.detached_setup_worker()
        copied=self.base/'copied-checkout';shutil.copytree(self.root,copied)
        config=dict(self.config,repository=str(copied))
        copy=worker_module.Worker(config,self.job)
        with self.assertRaisesRegex(worker_module.OperationalError,'owned checkout'): copy.preflight()
        self.assertEqual(json.loads(copy.owner.read_text()),owner)
        self.assertEqual(json.loads(original.owner.read_text()),owner)
        self.assertEqual(copy.checkout_identity.read_text(),original.checkout_identity.read_text())
        moved=self.base/'moved-checkout';self.root.rename(moved)
        worker=worker_module.Worker(dict(self.config,repository=str(moved)),self.job)
        with self.assertRaisesRegex(worker_module.OperationalError,'owned checkout'): worker.preflight()
        self.assertEqual(json.loads(worker.owner.read_text()),owner)

    def test_detached_setup_accepts_canonical_alias_and_rejects_missing_proof(self):
        original,owner=self.detached_setup_worker()
        proof=self.config.pop('detachedOwner')
        with self.assertRaisesRegex(worker_module.OperationalError,'owned checkout'): original.preflight()
        self.assertEqual(json.loads(original.owner.read_text()),owner)
        alias=self.base/'checkout-alias';alias.symlink_to(self.root,target_is_directory=True)
        proof['repository']=str(alias);self.config['detachedOwner']=proof
        worker=worker_module.Worker(dict(self.config,repository=str(alias)),self.job)
        worker.codex=lambda *args,**kwargs:{'imageDescription':'Fixture'}
        worker.require_checker()
        with patch.object(worker_module,'run',return_value=subprocess.CompletedProcess([],0,json.dumps({'interfaceVersion':1,'checkerVersion':'1.0.0'}),'')):
            worker.preflight()
        self.assertFalse(original.owner.exists())

    def test_unrelated_crlf_checkout_is_supported_without_weakening_source_proof(self):
        (self.root/'notes.txt').write_bytes(b'notes\n')
        (self.root/'.gitattributes').write_text('notes.txt text eol=crlf\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Unrelated EOL rule');self.git(self.root,'push','origin','main')
        (self.root/'notes.txt').unlink();self.git(self.root,'checkout','--','notes.txt')
        self.assertEqual((self.root/'notes.txt').read_bytes(),b'notes\r\n')
        self.assertFalse(self.git(self.root,'status','--porcelain'))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual(self.git(self.root,'show','HEAD:notes.txt'),'notes\n')

    def test_unrelated_smudge_filter_and_ignored_executable_bits_are_supported(self):
        executable=self.base/'filter';executable.write_text('#!'+sys.executable+'\nimport sys\nsys.stdout.write(sys.stdin.read().replace("POINTER", "EXPANDED"))\n');executable.chmod(0o755)
        self.git(self.root,'config','filter.fixture.smudge',str(executable))
        self.git(self.root,'config','filter.fixture.clean','cat')
        (self.root/'unrelated.bin').write_text('POINTER\n')
        (self.root/'.gitattributes').write_text('unrelated.bin filter=fixture\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Unrelated filter');self.git(self.root,'push','origin','main')
        (self.root/'unrelated.bin').unlink();self.git(self.root,'checkout','--','unrelated.bin')
        # A real LFS clean filter maps expanded content back to its pointer.
        clean=self.base/'clean';clean.write_text('#!'+sys.executable+'\nimport sys\nsys.stdout.write(sys.stdin.read().replace("EXPANDED", "POINTER"))\n');clean.chmod(0o755)
        self.git(self.root,'config','filter.fixture.clean',str(clean))
        self.git(self.root,'config','core.fileMode','false');(self.root/'tools/library.py').chmod(0o654)
        self.assertFalse(self.git(self.root,'status','--porcelain'))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual((self.root/'unrelated.bin').read_text(),'EXPANDED\n')

    def test_source_checkout_conversion_and_submodules_fail_before_codex(self):
        (self.root/'.gitattributes').write_text('shared/*.metal text eol=crlf\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Unsupported source conversion');self.git(self.root,'push','origin','main')
        (self.root/'shared/common.metal').unlink();self.git(self.root,'checkout','--','shared/common.metal')
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertTrue(any('Publication input checkout bytes differ' in e.get('message','') for e in events))
        self.assertFalse((self.job/'invocations.jsonl').exists())
        (self.root/'.gitattributes').unlink();self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Remove conversion')
        self.git(self.root,'update-index','--add','--cacheinfo','160000,'+self.base_sha+',submodule')
        self.git(self.root,'commit','-m','Submodule');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertTrue(any('Submodules' in e.get('message','') for e in events))
        self.assertFalse((self.job/'invocations.jsonl').exists())

    def test_signalled_candidate_validator_repairs_after_baseline_succeeds(self):
        (self.root/'.fixture-validation.json').write_text(json.dumps({'signalIfEdited':True}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Signalled candidate fixture');self.git(self.root,'push','origin','main')
        self.codex.write_text(CODEX.replace("write_text('EDIT\\n')", "write_text('EDIT\\n' if count == 1 else 'FIXED\\n')"))
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual((self.job/'implementation-count').read_text(),'2')
        self.assertEqual(self.git(self.root,'show','HEAD:shaders/alpha/body.metal'),'FIXED\n')

    def test_candidate_timeout_repeats_same_operation_on_pristine_baseline(self):
        from unittest.mock import patch
        worker=self.ignored_worker()
        (self.root/'shaders/alpha/body.metal').write_text('EDIT\n')
        observed=[]
        def operation(command,*args,**kwargs):
            text=(self.root/'shaders/alpha/body.metal').read_text();observed.append(text)
            if text=='EDIT\n':raise subprocess.TimeoutExpired(command,600)
            return subprocess.CompletedProcess(command,0,'','')
        worker.require_checker()
        with patch.object(worker_module,'run',side_effect=operation):
            with self.assertRaises(worker_module.VerificationError) as failure:worker.technical()
            worker.classify_verification_failure(failure.exception)
        self.assertEqual(observed,['EDIT\n','ALPHA\n'])
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'EDIT\n')

    def test_required_previews_follow_source_changes_and_survive_result_recovery(self):
        self.request['prompt']='helper';self.save_request()
        code,events=self.run_worker();self.assertEqual(code,0,events)
        event=next(e for e in events if e['event']=='preparePublication')
        self.assertEqual(set(event['requiredPreviewShaderIDs']),{'alpha','beta'})
        code,events=self.run_worker();self.assertEqual(code,0,events)
        self.assertEqual(next(e for e in events if e['event']=='preparePublication')['requiredPreviewShaderIDs'],event['requiredPreviewShaderIDs'])

    def test_bootstrap_is_read_only_and_does_not_require_remote_or_codex(self):
        self.git(self.root,'remote','set-url','origin',str(self.base/'unavailable.git'))
        before=self.git(self.root,'rev-parse','HEAD')
        code,events=self.run_worker(mode='publication');self.assertEqual(code,0,events)
        self.assertTrue(any(e['event']=='publicationReady' for e in events))
        self.assertEqual(next(e for e in events if e['event']=='preparePublication')['requiredPreviewShaderIDs'],[])
        self.assertEqual(self.git(self.root,'rev-parse','HEAD'),before)
        self.assertFalse(self.git(self.root,'status','--porcelain'))
        self.assertFalse((self.job/'invocations.jsonl').exists())
        (self.root/'shaders/alpha/body.metal').write_text('dirty')
        code,events=self.run_worker(mode='publication');self.assertNotEqual(code,0)
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'dirty')

    def test_bootstrap_refuses_temporary_checkout_lease(self):
        entered=self.base/'lease-entered'
        wrapper=self.base/'blocked-publication.py'
        wrapper.write_text(f"""import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('worker',{str(SCRIPT)!r})
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)
original=worker.fcntl.flock
def gated(fd,operation):
    Path({str(entered)!r}).touch()
    original(fd,operation)
worker.fcntl.flock=gated
sys.argv=[{str(SCRIPT)!r},'publication',{str(self.config_path)!r},{str(self.job)!r}]
worker.main()
""")
        with (self.root/'.git/holodeck-requests.lock').open('w') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX)
            process=subprocess.Popen([sys.executable,'-B','-u',str(wrapper)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            deadline=time.monotonic()+5
            while not entered.exists() and process.poll() is None and time.monotonic()<deadline: time.sleep(.005)
            self.assertTrue(entered.exists())
            stdout,stderr=process.communicate('{"ok":true}\n',timeout=5)
            self.assertNotEqual(process.returncode,0,stdout+stderr)
            self.assertIn('Checkout is busy in another process',stdout)
            fcntl.flock(lease,fcntl.LOCK_UN)

    def test_clean_filter_cannot_hide_a_forbidden_workspace_edit(self):
        original=(self.root/'tools/library.py').read_text()
        executable=self.base/'hide-change'
        executable.write_text('#!'+sys.executable+'\nimport sys\nsys.stdin.read()\nsys.stdout.write('+repr(original)+')\n');executable.chmod(0o755)
        (self.root/'.gitattributes').write_text('tools/library.py filter=hide\n')
        self.git(self.root,'config','filter.hide.clean',str(executable))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Unrelated clean filter');self.git(self.root,'push','origin','main')
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request
        worker.save(base=self.git(self.root,'rev-parse','HEAD').strip())
        worker_module.write(worker.owner,{'id':self.request['id'],'directory':str(self.job)})
        worker_module.write(self.job/'baseline-workspace.json',worker.candidate_manifest())
        frozen=worker.fingerprint()
        (self.root/'tools/library.py').write_text('print("forbidden validation logic")\n')
        self.assertFalse(self.git(self.root,'diff','--name-only','HEAD'))
        with self.assertRaisesRegex(worker_module.CandidateError,'Forbidden'):worker.scope()
        self.assertNotEqual(worker.fingerprint(),frozen)
        worker.clean()
        self.assertEqual((self.root/'tools/library.py').read_text(),original)

    def test_clean_filter_hidden_source_change_cannot_be_published_with_metadata(self):
        executable=self.base/'hide-source'
        executable.write_text('#!'+sys.executable+'\nimport sys\nsys.stdin.read()\nsys.stdout.write("ALPHA\\n")\n');executable.chmod(0o755)
        (self.root/'.gitattributes').write_text('shaders/alpha/body.metal filter=hide-source\n')
        self.git(self.root,'config','filter.hide-source.clean',str(executable))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Source clean fixture');self.git(self.root,'push','origin','main')
        baseline=self.git(self.root,'rev-parse','HEAD')
        self.codex.write_text(CODEX.replace("if mode=='helper':", "meta_path=Path(f'shaders/{sid}/metadata.json');meta=json.loads(meta_path.read_text());meta['description']='candidate metadata';meta_path.write_text(json.dumps(meta))\n        if mode=='helper':"))
        code,events=self.run_worker();self.assertNotEqual(code,0,events)
        self.assertTrue(any('Committed tree differs' in event.get('message','') for event in events),events)
        self.assertEqual(self.git(self.root,'rev-parse','origin/main'),baseline)
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'ALPHA\n')

    def test_failed_new_baseline_preserves_ignored_files_created_after_publication(self):
        (self.root/'.gitignore').write_text('ignored/\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Ignored scratch');self.git(self.root,'push','origin','main')
        code,events=self.run_worker();self.assertEqual(code,0,events)
        (self.root/'ignored').mkdir();(self.root/'ignored/user-data').write_bytes(b'created after publication')
        (self.root/'.fixture-validation.json').write_text(json.dumps({'fail':True}))
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Broken new baseline');self.git(self.root,'push','origin','main')
        (self.job/'repair.json').write_text(json.dumps({'attemptID':'new','shaderID':'alpha','diagnostic':'Repair activation'}))
        code,events=self.run_worker();self.assertNotEqual(code,0)
        self.assertEqual((self.root/'ignored/user-data').read_bytes(),b'created after publication')

    def test_authoring_profiles_and_inventory_shape_are_protected(self):
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
        original=json.loads((self.root/'authoring.json').read_text())
        for change in ({'regressionProfiles':['unknown']}, {'schemaVersion':2}, {'sourceRequirements':{}}, {'upstreamRequirements':{}}, {'sourceRequirements':{'unrelated.metal':[]}}):
            (self.root/'authoring.json').write_text(json.dumps(dict(original,**change)))
            with self.assertRaises(worker_module.CandidateError):worker.scope()
        (self.root/'authoring.json').write_text('{"schemaVersion":1,"schemaVersion":2}')
        with self.assertRaises(worker_module.CandidateError):worker.scope()

    def test_candidate_checker_exit_two_requires_baseline_classification(self):
        worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
        marker=self.base/'executed'
        (self.root/'tools/library.py').write_text('from pathlib import Path\nPath('+repr(str(marker))+').touch()\n')
        worker.technical(baseline=True)
        self.assertFalse(marker.exists())
        self.tool.write_text(TOOL.replace("if args[:2] == ['library', 'validate']:", "if args[:2] == ['library', 'validate']: raise SystemExit(2)\nif False:"))
        with self.assertRaises(worker_module.VerificationError) as failure:worker.technical()
        with self.assertRaisesRegex(worker_module.OperationalError,'Baseline or host validation failed'):
            worker.classify_verification_failure(failure.exception)

    def test_attribution_checkout_conversion_fails_before_codex(self):
        file=self.root/'authoring.json';file.write_text(file.read_text()+'\n')
        (self.root/'.gitattributes').write_text('authoring.json text eol=crlf\n')
        self.git(self.root,'add','--all');self.git(self.root,'commit','-m','Attribution conversion fixture');self.git(self.root,'push','origin','main')
        file.unlink();self.git(self.root,'checkout','--','authoring.json')
        self.assertIn(b'\r\n',file.read_bytes())
        self.assertFalse(self.git(self.root,'status','--porcelain').strip())
        code,events=self.run_worker();self.assertNotEqual(code,0,events)
        self.assertTrue(any('checkout bytes differ' in e.get('message','') for e in events),events)
        self.assertFalse((self.job/'invocations.jsonl').exists())

    def test_setup_rejects_old_python_before_reporting_checker_ready(self):
        worker,owner=self.detached_setup_worker()
        calls=[]
        def incompatible(command,*args,**kwargs):
            calls.append(command)
            if '-c' in command:
                self.assertIn('-I',command)
                self.assertEqual(kwargs['timeout'],5)
                self.assertFalse(kwargs['check'])
                return subprocess.CompletedProcess(command,1,'','')
            return subprocess.CompletedProcess(command,0,'','')
        with patch.object(worker_module,'run',side_effect=incompatible), patch.object(worker_module.sys,'version_info',(3,8,0)):
            with self.assertRaisesRegex(worker_module.OperationalError,'Python 3.9 or later'):worker.preflight()
        self.assertFalse(any('info' in command for command in calls))
        self.assertEqual(json.loads(worker.owner.read_text()),owner)

    def test_cleanup_quarantines_type_changes_and_preserves_external_targets(self):
        for kind in ('directory', 'fifo', 'link', 'parent-link'):
            with self.subTest(kind=kind):
                worker=worker_module.Worker(self.config,self.job);worker.request=self.request;worker.save(base=self.base_sha)
                worker_module.write(worker.owner,{'id':self.request['id'],'directory':str(self.job)})
                worker_module.write(self.job/'baseline-workspace.json',worker.candidate_manifest(compare_baseline=False))
                source=self.root/'shaders/alpha/body.metal'
                outside=self.base/('outside-'+kind);outside.mkdir();(outside/'kept').write_text('preserved')
                if kind=='parent-link':
                    shutil.rmtree(source.parent);source.parent.symlink_to(outside,target_is_directory=True)
                else:
                    source.unlink()
                    if kind=='directory':source.mkdir();(source/'kept').write_text('preserved')
                    elif kind=='fifo':os.mkfifo(source)
                    else:source.symlink_to(outside/'kept')
                worker.clean()
                self.assertEqual(source.read_text(),'ALPHA\n')
                self.assertEqual((outside/'kept').read_text(),'preserved')
                self.assertFalse(worker.owner.exists())
                self.assertTrue(list((worker.gitdir/'holodeck-recovery'/self.job.name).glob('*.json')))

    def test_publication_rejects_fifo_and_symlink_metadata_without_reading(self):
        worker=worker_module.Worker(self.config,self.job)
        metadata=self.root/'shaders/alpha/metadata.json';original=metadata.read_bytes()
        for kind in ('fifo','link'):
            metadata.unlink()
            if kind=='fifo':os.mkfifo(metadata)
            else:metadata.symlink_to(self.root/'index.json')
            started=time.monotonic()
            with self.assertRaises((worker_module.CandidateError,OSError)):worker.publication_inputs()
            self.assertLess(time.monotonic()-started,1)
            metadata.unlink();metadata.write_bytes(original)

    def test_symlink_manifest_hashes_link_bytes(self):
        worker=worker_module.Worker(self.config,self.job);worker.save(base=self.base_sha)
        link=self.root/'safe-link';link.symlink_to(self.base/'missing-outside')
        record=worker.candidate_manifest()['safe-link']
        self.assertEqual(record['oid'],worker.blob_oid(os.fsencode(str(self.base/'missing-outside'))))

    def test_publication_lock_contention_is_immediate_and_actionable(self):
        worker=worker_module.Worker(self.config,self.job)
        with (worker.gitdir/'holodeck-requests.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            started=time.monotonic()
            with self.assertRaisesRegex(worker_module.OperationalError,'Checkout is busy in another process'):worker.prepare_current()
            self.assertLess(time.monotonic()-started,1)

    def test_validation_stages_have_independent_budgets_and_exit_two_reprobes_same_stage(self):
        worker=self.ignored_worker();(self.root/'shaders/alpha/body.metal').write_text('EDIT\n')
        calls=[]
        def validate(command,*args,**kwargs):
            phase='--gpu-only' if '--gpu-only' in command else '--compile'
            text=(self.root/'shaders/alpha/body.metal').read_text()
            calls.append((phase,kwargs['timeout'],text))
            return subprocess.CompletedProcess(command,2 if phase=='--gpu-only' and text=='EDIT\n' else 0,'candidate probe timed out','')
        worker.require_checker()
        with patch.object(worker_module,'run',side_effect=validate):
            with self.assertRaises(worker_module.VerificationError) as failure:worker.technical()
            worker.classify_verification_failure(failure.exception)
        self.assertEqual([(c[0],c[1]) for c in calls],[('--compile',600),('--gpu-only',600),('--gpu-only',600)])
        self.assertEqual(calls[-1][2],'ALPHA\n')
        self.assertEqual((self.root/'shaders/alpha/body.metal').read_text(),'EDIT\n')

    def test_checker_identity_mismatch_is_operational_before_validation(self):
        worker=worker_module.Worker(self.config,self.job)
        for field,value in [('version','1.99.0'),('sha256','c'*64),('sourceCommit','c'*40),('repository','someone/Other'),('interfaceVersion',True)]:
            with self.subTest(field=field):
                (self.root/'shader_checker.lock.json').write_text(json.dumps(dict(CHECKER_PIN,**{field:value})))
                with self.assertRaisesRegex(worker_module.OperationalError,'Update Holodeck'):
                    worker.technical()
        (self.root/'shader_checker.lock.json').write_text(json.dumps(CHECKER_PIN))
        worker.require_checker()

    def test_managed_communicate_preserves_large_input_across_timeouts(self):
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job));payload='x'*2000000
        result=worker_module.managed_run([sys.executable,'-c','import sys,time;time.sleep(.7);print(len(sys.stdin.read()))'],self.root,env,5,payload)
        self.assertEqual(result.stdout.strip(),str(len(payload)))

    def test_registry_prunes_more_than_700_retired_identities(self):
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        code="import os;exec('for _ in range(750):\\n p=os.fork()\\n if p==0:os._exit(0)\\n os.waitpid(p,0)');print(750)"
        with worker_module.ManagedChild([sys.executable,'-c',code],self.root,env) as child:
            output,_=child.process.communicate(timeout=30)
            self.assertEqual(output.strip(),'750')
            self.assertLess(child.registry.stat().st_size,1024)
            self.assertEqual(len(json.loads(child.registry.read_bytes())[0]['members']),1)
        self.assertFalse((self.job/'children.json').exists())

    def test_group_observation_timeout_is_operational_not_candidate_timeout(self):
        with patch.object(worker_module,'_libproc',None), patch.object(worker_module.subprocess,'run',side_effect=subprocess.TimeoutExpired('ps',2)):
            with self.assertRaises(worker_module.ProcessObservationError):worker_module.group_members(99999)

    def test_native_group_enumeration_grows_buffers_and_reports_errors(self):
        class Native:
            def __init__(self):self.sizes=[]
            def proc_listpids(self,kind,pid,data,size):
                self.sizes.append(size)
                if len(self.sizes)==1:return size
                worker_module.ctypes.memmove(data,struct.pack('=i',os.getpid()),4)
                return 4
        native=Native();identity=worker_module.process_identity(os.getpid())
        with patch.object(worker_module,'_libproc',native), patch.object(worker_module,'process_identity',return_value=identity):
            result=worker_module.group_members(os.getpgrp())
        self.assertEqual(native.sizes,[4096,8192]);self.assertEqual(result[0]['pid'],os.getpid())
        def failure(*args):worker_module.ctypes.set_errno(5);return 0
        native.proc_listpids=failure
        with patch.object(worker_module,'_libproc',native):
            with self.assertRaises(worker_module.ProcessObservationError):worker_module.group_members(123)
        native.proc_listpids=lambda kind,pid,data,size:size
        with patch.object(worker_module,'_libproc',native):
            with self.assertRaisesRegex(worker_module.ProcessObservationError,'capacity'):worker_module.group_members(123)

    def test_quarantine_uses_bounded_names_for_long_components(self):
        worker=worker_module.Worker(self.config,self.job);name='x'*240
        target=self.base/'preserved';target.write_text('outside')
        (self.root/name).symlink_to(target)
        worker.quarantine_obstructions([name])
        directory=worker.gitdir/'holodeck-recovery'/self.job.name
        record=next(directory.glob('*.json'))
        self.assertEqual(json.loads(record.read_text())['originalPath'],name)
        self.assertLess(len(record.name),64);self.assertEqual(target.read_text(),'outside')

    def test_quarantine_metadata_failure_leaves_original_in_place(self):
        worker=worker_module.Worker(self.config,self.job)
        target=self.base/'retained';target.write_bytes(b'original bytes')
        obstruction=self.root/'obstruction';obstruction.symlink_to(target)
        with patch.object(worker_module,'write',side_effect=OSError('metadata unavailable')):
            with self.assertRaisesRegex(OSError,'metadata unavailable'):
                worker.quarantine_obstructions(['obstruction'])
        self.assertTrue(obstruction.is_symlink());self.assertEqual(target.read_bytes(),b'original bytes')
        self.assertEqual(list((worker.gitdir/'holodeck-recovery'/self.job.name).iterdir()),[])

    def test_quarantine_rename_failure_retains_original_path_record(self):
        worker=worker_module.Worker(self.config,self.job)
        target=self.base/'retained';target.write_bytes(b'original bytes')
        obstruction=self.root/'obstruction';obstruction.symlink_to(target)
        with patch.object(worker_module.os,'rename',side_effect=OSError('rename unavailable')):
            with self.assertRaisesRegex(worker_module.OperationalError,'rename unavailable'):
                worker.quarantine_obstructions(['obstruction'])
        self.assertTrue(obstruction.is_symlink())
        records=list((worker.gitdir/'holodeck-recovery'/self.job.name).glob('*.json'))
        self.assertEqual(len(records),1);self.assertEqual(json.loads(records[0].read_bytes())['originalPath'],'obstruction')

    def test_late_fork_during_termination_is_adopted_by_retained_supervisor(self):
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job));marker=self.base/'late-child'
        code="""import signal,subprocess,sys,time
from pathlib import Path
def stop(*args):
 child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 Path(sys.argv[1]).write_text(str(child.pid))
 raise SystemExit(0)
signal.signal(signal.SIGTERM,stop)
sys.stdin.read();print('ready',flush=True)
time.sleep(60)
"""
        try:
            with worker_module.ManagedChild([sys.executable,'-c',code,str(marker)],self.root,env,stdin=True,text=False) as child:
                lines=child.lines('prompt');self.assertEqual(next(lines),'ready')
            self.assertFalse((self.job/'children.json').exists())
            self.assertFalse((self.job/'supervision.json').exists())
            self.assertIsNone(worker_module.process_identity(int(marker.read_text())))
        finally:
            if marker.exists():
                identity=worker_module.process_identity(int(marker.read_text()))
                if identity and worker_module.process_identity(identity['pid'])==identity:os.kill(identity['pid'],signal.SIGKILL)

    def test_live_registry_overflow_preserves_previous_evidence(self):
        registry=self.job/'children.json';original=b'[]';registry.write_bytes(original)
        identities=[{'pid':100000+i,'seconds':1792260000,'microseconds':123456} for i in range(1500)]
        with self.assertRaisesRegex(worker_module.ProcessRecoveryError,'64 KiB'):
            worker_module.save_registry(registry,[{'leader':identities[0],'members':identities}])
        self.assertEqual(registry.read_bytes(),original)

    def test_streaming_child_is_registered_and_sampled_while_output_is_idle(self):
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job));marker=self.base/'descendant'
        code="import subprocess,sys,time;from pathlib import Path;sys.stdin.read();p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));time.sleep(.6);print('done',flush=True)"
        with worker_module.ManagedChild([sys.executable,'-c',code,str(marker)],self.root,env,stdin=True,text=False) as child:
            self.assertTrue(child.registry.exists())
            self.assertEqual(list(child.lines('prompt')),['done'])
        self.assertIsNone(worker_module.process_identity(int(marker.read_text())))
        self.assertFalse((self.job/'children.json').exists())

    def supervisor_fixture(self, injected):
        script=self.base/('supervisor-'+str(uuid.uuid4())+'.py')
        script.write_text("import importlib.util,sys\n"+"spec=importlib.util.spec_from_file_location('w',"+repr(str(SCRIPT))+");w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)\n"+injected+"\nsys.exit(w.supervise(int(sys.argv[2])))\n")
        return script

    def test_supervision_deadlines_share_one_clock_across_processes(self):
        before=worker_module.process_clock()
        code="import runpy,sys;w=runpy.run_path(sys.argv[1]);print(w['process_clock']())"
        observed=float(subprocess.check_output([sys.executable,'-I','-c',code,str(SCRIPT)],text=True))
        after=worker_module.process_clock()
        self.assertLessEqual(before,observed);self.assertLessEqual(observed,after)
        child=worker_module.ManagedChild.__new__(worker_module.ManagedChild)
        child.status={'deadline':observed+10}
        self.assertGreater(child.drain_deadline(),after)
        self.assertLessEqual(child.drain_deadline(),worker_module.process_clock()+5)

    def test_successful_exit_with_final_unsampled_helper_is_successful(self):
        marker=self.base/'last-helper';env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        code="import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));print('success')"
        result=worker_module.run([sys.executable,'-c',code,str(marker)],self.root,env,timeout=5)
        self.assertEqual(result.returncode,0);self.assertIn('success',result.stdout)
        self.assertIsNone(worker_module.process_identity(int(marker.read_text())))
        self.assertFalse((self.job/'supervision.json').exists())

    def test_capacity_failure_still_terminates_every_verified_helper(self):
        script=self.supervisor_fixture("real=w.save_registry\ndef save(file,entries):\n if any(len(e['members'])>2 for e in entries):raise w.ProcessRecoveryError('Injected 64 KiB capacity')\n return real(file,entries)\nw.save_registry=save")
        marker=self.base/'capacity-helper';env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));time.sleep(60)"
        with self.assertRaisesRegex(worker_module.OperationalError,'64 KiB capacity'):
            with worker_module.ManagedChild([sys.executable,'-c',code,str(marker)],self.root,env,supervisor_script=script) as child:
                child.process.communicate(timeout=8)
        self.assertIsNone(worker_module.process_identity(int(marker.read_text())))
        self.assertIsNone(worker_module.process_identity(child.identity['pid']))

    def test_transient_native_observation_failures_retry_without_failing_command(self):
        script=self.supervisor_fixture("real=w.group_members\ncalls=0\ndef observe(pid):\n global calls\n calls+=1\n if calls<=2:raise w.ProcessObservationError('Transient enumeration failure')\n return real(pid)\nw.group_members=observe")
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        with worker_module.ManagedChild([sys.executable,'-c','import time;time.sleep(.8);print(42)'],self.root,env,supervisor_script=script) as child:
            output,_=child.process.communicate(timeout=5)
            self.assertEqual(output.strip(),'42')
        self.assertFalse((self.job/'supervision.json').exists())

    def test_control_channel_closure_drains_command_and_helpers(self):
        marker=self.base/'control-helper';env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));print('ready',flush=True);time.sleep(60)"
        with worker_module.ManagedChild([sys.executable,'-c',code,str(marker)],self.root,env,stdin=True,text=False) as child:
            self.assertEqual(next(child.lines('prompt')),'ready')
            child.control.close();child.control=None
            child.process.wait(timeout=8)
        self.assertIsNone(worker_module.process_identity(int(marker.read_text())))
        self.assertFalse((self.job/'supervision.json').exists())

    def test_supervisor_crash_stops_registered_command_and_retains_unknown_helper(self):
        marker=self.base/'crash-helper';env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);Path(sys.argv[1]).write_text(str(p.pid));print('ready',flush=True);time.sleep(60)"
        try:
            with self.assertRaises(worker_module.ProcessRecoveryError):
                with worker_module.ManagedChild([sys.executable,'-c',code,str(marker)],self.root,env,stdin=True,text=False) as child:
                    self.assertEqual(next(child.lines('prompt')),'ready')
                    self.assertIsNotNone(child.status.get('command'))
                    os.kill(child.identity['pid'],signal.SIGKILL);child.process.wait(timeout=2)
            self.assertIsNone(worker_module.process_identity(child.status['command']['pid']))
            self.assertTrue((self.job/'children.json').exists())
        finally:
            if marker.exists():
                identity=worker_module.process_identity(int(marker.read_text()))
                if identity and worker_module.process_identity(identity['pid'])==identity:os.kill(identity['pid'],signal.SIGKILL)

    def test_persistent_observation_failure_is_operational_and_retains_evidence(self):
        script=self.supervisor_fixture("def observe(pid):raise w.ProcessObservationError('Persistent enumeration failure')\nw.group_members=observe")
        env=dict(os.environ,HOLODECK_REQUEST_DIRECTORY=str(self.job))
        with self.assertRaises(worker_module.ProcessRecoveryError):
            with worker_module.ManagedChild([sys.executable,'-c','import time;time.sleep(60)'],self.root,env,supervisor_script=script) as child:
                child.process.communicate(timeout=15)
        self.assertIsNone(worker_module.process_identity(child.status['command']['pid']))
        self.assertTrue((self.job/'children.json').exists())
        self.assertTrue(worker_module.read_supervision(self.job)['recoveryRequired'])

    def test_external_pipe_holder_is_recovery_not_candidate_failure(self):
        worker=worker_module.Worker(self.config,self.job);marker=self.base/'escaped-holder'
        code="import subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True,stdin=subprocess.DEVNULL);Path(sys.argv[1]).write_text(str(p.pid))"
        worker.require_checker=lambda:None
        try:
            with self.assertRaises(worker_module.ProcessRecoveryError):
                worker.technical(commands=[[sys.executable,'-c',code,str(marker)]])
            state=worker_module.read_supervision(self.job)
            self.assertEqual(state['commandReturnCode'],0);self.assertEqual(state['failureKind'],'pipeDrain')
            with self.assertRaises(worker_module.ProcessDrainError):worker_module.terminate_registered(self.job)
        finally:
            if marker.exists():
                identity=worker_module.process_identity(int(marker.read_text()))
                if identity and worker_module.process_identity(identity['pid'])==identity:os.kill(identity['pid'],signal.SIGKILL)

    def test_registry_comparison_rejects_links_and_fifos_without_blocking(self):
        registry=self.job/'children.json';target=self.base/'registry-target';target.write_bytes(b'[]')
        for kind in ('symlink','fifo'):
            if kind=='symlink':registry.symlink_to(target)
            else:os.mkfifo(registry)
            started=time.monotonic()
            with self.assertRaises(worker_module.ProcessRecoveryError):worker_module.save_registry(registry,[])
            self.assertLess(time.monotonic()-started,1);registry.unlink()
        self.assertEqual(target.read_bytes(),b'[]')

    def test_validation_timeout_terminates_descendants_and_removes_registry(self):
        worker=worker_module.Worker(self.config,self.job)
        child_pid=self.base/'probe-pid'
        script='import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"]);Path(sys.argv[1]).write_text(str(p.pid));time.sleep(60)'
        with self.assertRaises(subprocess.TimeoutExpired):
            worker_module.run([sys.executable,'-c',script,str(child_pid)],self.root,worker.env,timeout=.5)
        self.assertIsNone(worker_module.process_identity(int(child_pid.read_text())))
        self.assertFalse((self.job/'children.json').exists())

    def test_unrecorded_descendant_can_settle_without_permanent_recovery_failure(self):
        gate=self.base/'leader-exit';pid_file=self.base/'settling-child'
        code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(.4)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);Path(sys.argv[2]).write_text(str(p.pid));exec('while not Path(sys.argv[1]).exists(): time.sleep(.005)')"
        parent=subprocess.Popen([sys.executable,'-c',code,str(gate),str(pid_file)],start_new_session=True)
        try:
            deadline=time.monotonic()+3
            while not pid_file.exists():
                self.assertLess(time.monotonic(),deadline);time.sleep(.005)
            birth=worker_module.process_identity(parent.pid)
            worker_module.write(self.job/'children.json',[{'leader':birth,'members':[birth]}])
            gate.touch();parent.wait(timeout=2)
            started=time.monotonic();worker_module.terminate_registered(self.job)
            self.assertLess(time.monotonic()-started,2)
            self.assertIsNone(worker_module.process_identity(int(pid_file.read_text())))
            self.assertFalse((self.job/'children.json').exists())
        finally:
            if parent.poll() is None:parent.kill();parent.wait(timeout=2)

    def test_repeated_signals_do_not_interrupt_registered_cleanup(self):
        bootstrap="""import importlib.util,subprocess,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('worker',sys.argv[1]);w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
class ProbeWorker:
 request=None
 def __init__(self,config,directory):
  child=subprocess.Popen([sys.executable,'-u','-c',"import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print('ready',flush=True);time.sleep(60)"],start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
  child.stdout.readline();birth=w.process_identity(child.pid);job=Path(directory);w.write(job/'children.json',[{'leader':birth,'members':[birth]}]);(job/'ready').touch()
 def perform(self):time.sleep(60)
w.Worker=ProbeWorker
sys.argv=[sys.argv[1],'run',sys.argv[2],sys.argv[3]]
w.main()
"""
        process=subprocess.Popen([sys.executable,'-I','-c',bootstrap,str(SCRIPT),str(self.config_path),str(self.job)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        birth=None
        try:
            deadline=time.monotonic()+3
            while not (self.job/'ready').exists():
                self.assertLess(time.monotonic(),deadline);time.sleep(.005)
            registry=self.job/'children.json';birth=json.loads(registry.read_text())[0]['leader'];stamp=registry.stat().st_mtime_ns
            process.send_signal(signal.SIGTERM)
            while registry.stat().st_mtime_ns==stamp:
                self.assertLess(time.monotonic(),deadline);time.sleep(.001)
            process.send_signal(signal.SIGTERM);process.send_signal(signal.SIGINT)
            out,err=process.communicate(timeout=11)
            self.assertEqual(process.returncode,130,err)
            self.assertNotIn('Traceback',err)
            self.assertIsNone(worker_module.process_identity(birth['pid']))
            self.assertFalse(registry.exists())
        finally:
            if process.poll() is None:process.kill();process.wait(timeout=2)
            if birth and worker_module.process_identity(birth['pid'])==birth:os.kill(birth['pid'],signal.SIGKILL)

    def test_process_registry_rejects_special_files_and_malformed_identities(self):
        registry=self.job/'children.json'
        for value in ('fifo','{}','[{"leader":{"pid":1},"members":[]}]'):
            if value=='fifo':os.mkfifo(registry)
            else:registry.write_text(value)
            started=time.monotonic()
            with self.assertRaises(worker_module.ProcessRecoveryError):worker_module.terminate_registered(self.job)
            self.assertLess(time.monotonic()-started,1)
            registry.unlink()

if __name__=='__main__': unittest.main()
