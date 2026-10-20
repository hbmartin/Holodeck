#!/usr/bin/env python3
"""Compare managed-command startup against a Git revision using disposable files only."""
import argparse
import importlib.util
import hashlib
import json
import os
import resource
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / 'HolodeckCore/Sources/HolodeckCore/Resources/shader_requests.py'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='22dd0a8')
    parser.add_argument('--iterations', type=int, default=31)
    parser.add_argument('--worker', type=Path, default=WORKER)
    parser.add_argument('--idle-seconds', type=float, default=15)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='holodeck-supervision-profile-') as scratch:
        directory = Path(scratch)
        baseline_directory = directory / 'baseline-runtime'; baseline_directory.mkdir()
        baseline = baseline_directory / 'shader_requests.py'
        baseline.write_bytes(subprocess.check_output(['git', 'show', args.baseline + ':' + str(WORKER.relative_to(ROOT))], cwd=ROOT))
        dependency = subprocess.run(['git', 'show', args.baseline + ':' + str(WORKER.with_name('shader_processes.py').relative_to(ROOT))], cwd=ROOT, capture_output=True)
        if dependency.returncode == 0: (baseline_directory / 'shader_processes.py').write_bytes(dependency.stdout)
        current_directory = directory / 'current-runtime'; current_directory.mkdir()
        current = current_directory / 'shader_requests.py'
        current.write_bytes(args.worker.read_bytes())
        (current_directory / 'shader_processes.py').write_bytes(args.worker.with_name('shader_processes.py').read_bytes())
        versions = [('baseline', load('baseline', baseline)), ('current', load('current', current))]
        results = {'python': sys.version, 'baselineRef': args.baseline,
                   'currentWorkerSHA256': hashlib.sha256(current.read_bytes()).hexdigest(),
                   'currentRuntimeSHA256': hashlib.sha256((current_directory / 'shader_processes.py').read_bytes()).hexdigest()}
        for label, module in versions:
            journal = directory / label; journal.mkdir()
            env = dict(os.environ, HOLODECK_REQUEST_DIRECTORY=str(journal), PYTHONDONTWRITEBYTECODE='1')
            command = ['/usr/bin/git', '--version']
            module.managed_run(command, directory, env, 10, None)
            samples = []
            for _ in range(args.iterations):
                started = time.perf_counter()
                assert module.managed_run(command, directory, env, 10, None).returncode == 0
                samples.append((time.perf_counter() - started) * 1000)
            results[label] = {'shortCommandMedianMs': statistics.median(samples)}
            # Exercise the actual Worker.git path without contacting any remote.
            repository = directory / (label + '-repository'); repository.mkdir()
            subprocess.run(['/usr/bin/git', 'init', '-q', repository], check=True)
            config = dict(repository=str(repository), git='/usr/bin/git', python=sys.executable,
                          codex='/usr/bin/false', shaderTool='/usr/bin/false')
            samples = []
            for _ in range(5):
                started = time.perf_counter(); worker = module.Worker(config, journal)
                for _ in range(5):
                    worker.git('status', '--porcelain'); worker.git('rev-parse', '--show-toplevel'); worker.git('ls-files', '-z')
                samples.append((time.perf_counter() - started) * 1000)
            results[label]['eighteenGitCommandsMedianMs'] = statistics.median(samples)
            # Instrument separately so measurement hooks do not affect launch timings.
            runtime = getattr(module, 'processes', module)
            owner_script = Path(runtime.__file__)
            counts = directory / (label + '-counts.json'); wrapper = directory / (label + '-counted.py')
            wrapper.write_text("import importlib.util,json,sys\nfrom pathlib import Path\n"
                + "s=importlib.util.spec_from_file_location('p'," + repr(str(owner_script)) + ");p=importlib.util.module_from_spec(s);s.loader.exec_module(p)\n"
                + "counts={'fsyncs':0,'writes':0,'launches':0}\n"
                + "def count(name,original):\n def call(*a,**k):\n  counts[name]+=1\n  return original(*a,**k)\n return call\n"
                + "p.os.fsync=count('fsyncs',p.os.fsync);p.os.replace=count('writes',p.os.replace);p.subprocess.Popen=count('launches',p.subprocess.Popen)\n"
                + "try:rc=p.supervise(int(sys.argv[2]))\nfinally:Path(" + repr(str(counts)) + ").write_text(json.dumps(counts))\nsys.exit(rc)\n")
            parent_counts = {'fsyncs': 0, 'writes': 0, 'launches': 0}
            def counted(name, original):
                def call(*a, **k):
                    parent_counts[name] += 1
                    return original(*a, **k)
                return call
            with patch.object(runtime.os, 'fsync', counted('fsyncs', runtime.os.fsync)), \
                 patch.object(runtime.os, 'replace', counted('writes', runtime.os.replace)), \
                 patch.object(runtime.subprocess, 'Popen', counted('launches', runtime.subprocess.Popen)):
                with module.ManagedChild(command, directory, env, supervisor_script=wrapper) as child:
                    list(child.output_chunks(timeout=10))
            owner_counts = json.loads(counts.read_text())
            results[label]['oneCommand'] = {key: parent_counts[key] + owner_counts[key] for key in parent_counts}
            before_parent = resource.getrusage(resource.RUSAGE_SELF)
            before_child = resource.getrusage(resource.RUSAGE_CHILDREN)
            started = time.perf_counter()
            result = module.managed_run([sys.executable, '-c', 'import time;time.sleep(' + str(args.idle_seconds) + ')'], directory, env, args.idle_seconds + 10, None)
            assert result.returncode == 0
            elapsed = time.perf_counter() - started
            after_parent = resource.getrusage(resource.RUSAGE_SELF)
            after_child = resource.getrusage(resource.RUSAGE_CHILDREN)
            def percent(before, after):
                return (after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime) / elapsed * 100
            results[label]['idle'] = dict(elapsedSeconds=elapsed, parentCPUPercent=percent(before_parent, after_parent),
                                         reapedChildCPUPercent=percent(before_child, after_child))
        print(json.dumps(results, indent=2))


if __name__ == '__main__': main()
