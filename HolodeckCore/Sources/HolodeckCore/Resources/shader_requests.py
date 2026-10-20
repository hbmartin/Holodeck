#!/usr/bin/env python3
"""Single-checkout Codex worker. JSONL bridge; no shell interpolation or model-owned Git writes."""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import selectors
import subprocess
import sys
import struct
import re
import stat
import uuid
import ctypes
import time


class OperationalError(RuntimeError):
    pass


class ProcessRecoveryError(OperationalError):
    pass


class CandidateError(RuntimeError):
    pass


class WorkspaceTypeError(CandidateError):
    pass


class WorkerInterrupted(BaseException):
    pass


_libproc = ctypes.CDLL('/usr/lib/libproc.dylib') if sys.platform == 'darwin' else None
REGISTRY_LIMIT = 65536
PROCESS_SAMPLE_SECONDS = .25


class ProcessObservationError(ProcessRecoveryError):
    pass


def process_identity(pid):
    """Birth identity shared with the native host; a PID alone is never ownership proof."""
    if sys.platform == "darwin":
        data = ctypes.create_string_buffer(136)  # Darwin proc_bsdinfo
        if _libproc.proc_pidinfo(pid, 3, 0, data, len(data)) != len(data):
            return None
        if struct.unpack_from('=I', data, 4)[0] == 5:  # zombie
            return None
        seconds, microseconds = struct.unpack_from('=QQ', data, 120)
        return {"pid": pid, "seconds": seconds, "microseconds": microseconds}
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        if fields[0] == 'Z': return None
        return {"pid": pid, "seconds": int(fields[19]), "microseconds": 0}
    except (OSError, ValueError, IndexError):
        return None


def process_groups():
    try:
        listing = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid='], capture_output=True, text=True, timeout=2, check=True)
        groups = {}
        for line in listing.stdout.splitlines():
            parts = line.split()
            if len(parts) == 2: groups.setdefault(int(parts[1]), []).append(int(parts[0]))
        return groups
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ProcessObservationError('Cannot observe owned process groups: ' + str(error)) from error


def group_members(pid, snapshot=None):
    groups = process_groups() if snapshot is None else snapshot
    return [identity for member in groups.get(pid, []) if (identity := process_identity(member)) is not None]


def merge_members(known, observed):
    return list({(i['pid'], i['seconds'], i['microseconds']): i for i in known + observed
                 if process_identity(i['pid']) == i}.values())


def terminate_registered(directory):
    file = Path(directory) / 'children.json'
    if not file.exists(): return
    try:
        fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode): raise ValueError('Expected a regular process registry')
            data = source.read(65537)
            if len(data) > 65536: raise ValueError('Process registry exceeds its size limit')
        entries = json.loads(data)
        def valid(identity):
            return isinstance(identity, dict) and all(type(identity.get(key)) is int for key in ('pid', 'seconds', 'microseconds')) and identity['pid'] > 1
        if not isinstance(entries, list) or any(not isinstance(e, dict) or not valid(e.get('leader')) or not isinstance(e.get('members'), list) or not all(valid(i) for i in e['members']) for e in entries):
            raise ValueError('Invalid process identities')
    except (OSError, ValueError, TypeError) as error:
        raise ProcessRecoveryError('Process registry is unreadable; retain the journal and recover or detach the checkout: ' + str(error)) from error
    deadline = time.monotonic() + 10
    term_sent, kill_sent = set(), set()
    next_sample = 0
    unknown = False
    while True:
        sampled = time.monotonic() >= next_sample
        if sampled:
            unknown = False
            snapshot = process_groups()
            for entry in entries:
                leader = entry['leader']
                observed = group_members(leader['pid'], snapshot)
                if process_identity(leader['pid']) == leader:
                    entry['members'] = merge_members(entry['members'], observed)
                else:
                    entry['members'] = merge_members(entry['members'], [])
                    # A retired leader does not authorize adopting unfamiliar identities.
                    unknown = unknown or (process_identity(leader['pid']) is None and any(i not in entry['members'] for i in observed))
            save_registry(file, entries)
            next_sample = time.monotonic() + PROCESS_SAMPLE_SECONDS
        sig = signal.SIGKILL if time.monotonic() >= deadline - 5 else signal.SIGTERM
        sent = kill_sent if sig == signal.SIGKILL else term_sent
        for entry in entries:
            for identity in entry['members']:
                key = (identity['pid'], identity['seconds'], identity['microseconds'])
                if key not in sent and process_identity(identity['pid']) == identity:
                    sent.add(key)
                    with contextlib.suppress(ProcessLookupError): os.kill(identity['pid'], sig)
        live = any(process_identity(i['pid']) == i for e in entries for i in e['members'])
        if not live and sampled and not unknown:
            file.unlink(missing_ok=True); return
        if time.monotonic() >= deadline:
            raise ProcessRecoveryError('Owned descendants did not settle; retain the journal and recover or detach the checkout')
        time.sleep(.025)


def save_registry(file, entries):
    data = json.dumps(entries, separators=(',', ':')).encode()
    if len(data) > REGISTRY_LIMIT:
        raise ProcessRecoveryError('Live process registry exceeds 64 KiB; existing ownership evidence was retained')
    # Avoid needless decoding/writes in the native supervisor when ownership has not changed.
    if file.exists() and file.read_bytes() == data: return
    temporary = file.with_suffix('.json.tmp')
    temporary.write_bytes(data); temporary.replace(file)


class ManagedChild:
    """One registered session, shared by captured commands and streaming Codex calls."""
    def __init__(self, args, cwd, env, *, stdin=False, stderr=subprocess.PIPE, text=True):
        self.args, self.cwd, self.env = args, cwd, env
        self.stdin, self.stderr, self.text = stdin, stderr, text
        self.registry = Path(env['HOLODECK_REQUEST_DIRECTORY']) / 'children.json'
        self.process = None
        self.next_sample = 0

    def __enter__(self):
        if self.registry.exists(): terminate_registered(self.registry.parent)
        read_gate, write_gate = os.pipe()
        bootstrap = 'import os,sys; gate=int(sys.argv[1]); go=os.read(gate,1); os.close(gate); go or sys.exit(125); os.execv(sys.argv[2],sys.argv[2:])'
        try:
            self.process = subprocess.Popen([sys.executable, '-I', '-c', bootstrap, str(read_gate), *self.args],
                cwd=self.cwd, env=self.env, stdin=subprocess.PIPE if self.stdin else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=self.stderr, text=self.text, start_new_session=True, pass_fds=(read_gate,))
            self.identity = process_identity(self.process.pid)
            if self.identity is None: raise ProcessRecoveryError('Cannot establish managed process identity')
            self.members = [self.identity]
            save_registry(self.registry, [{'leader': self.identity, 'members': self.members}])
            os.write(write_gate, b'1')
            return self
        except BaseException:
            if self.process is not None: self.process.kill(); self.process.wait(timeout=5)
            self.close_pipes()
            raise
        finally:
            os.close(read_gate); os.close(write_gate)

    def sample(self):
        if time.monotonic() < self.next_sample: return
        if process_identity(self.process.pid) == self.identity:
            self.members = merge_members(self.members, group_members(self.process.pid))
            save_registry(self.registry, [{'leader': self.identity, 'members': self.members}])
        self.next_sample = time.monotonic() + PROCESS_SAMPLE_SECONDS

    def close_pipes(self):
        if self.process is not None:
            for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
                if pipe is not None and hasattr(pipe, 'close'): pipe.close()

    def __exit__(self, kind, error, traceback):
        try:
            # Successful commands must settle their descendants too. Unknown survivors fail closed.
            terminate_registered(self.registry.parent)
            self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None: self.process.kill(); self.process.wait(timeout=5)
            self.close_pipes()

    def lines(self, prompt):
        """Keep observing while stdin is backpressured or stdout is idle, without a job deadline."""
        process = self.process
        payload = memoryview(prompt.encode('utf-8')); pending = bytearray()
        with selectors.DefaultSelector() as selector:
            os.set_blocking(process.stdin.fileno(), False); os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE)
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                self.sample()
                for key, _ in selector.select(PROCESS_SAMPLE_SECONDS):
                    if key.fileobj is process.stdin:
                        try: count = os.write(process.stdin.fileno(), payload[:65536])
                        except BrokenPipeError: count = len(payload)
                        payload = payload[count:]
                        if not payload:
                            selector.unregister(process.stdin); process.stdin.close()
                    else:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            selector.unregister(process.stdout)
                            if pending: yield pending.decode('utf-8', errors='replace')
                            pending.clear()
                        else:
                            pending.extend(chunk)
                            while b'\n' in pending:
                                line, _, pending = pending.partition(b'\n')
                                yield line.decode('utf-8', errors='replace')
                if process.poll() is not None:
                    # A descendant retaining stdout must not keep a finished Codex invocation alive.
                    while True:
                        try: chunk = os.read(process.stdout.fileno(), 65536)
                        except BlockingIOError: break
                        if not chunk: break
                        pending.extend(chunk)
                        while b'\n' in pending:
                            line, _, pending = pending.partition(b'\n')
                            yield line.decode('utf-8', errors='replace')
                    if pending: yield pending.decode('utf-8', errors='replace')
                    return
            while process.poll() is None:
                self.sample(); time.sleep(.025)


def managed_run(args, cwd, env, timeout, input, text=True):
    with ManagedChild(args, cwd, env, stdin=input is not None, text=text) as child:
        deadline = time.monotonic() + timeout
        while True:
            child.sample()
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise subprocess.TimeoutExpired(args, timeout)
            try:
                stdout, stderr = child.process.communicate(input=input, timeout=min(PROCESS_SAMPLE_SECONDS, remaining))
                break
            except subprocess.TimeoutExpired:
                input = None  # communicate retains its buffered input and offset across retries.
                if child.process.poll() is not None:
                    terminate_registered(child.registry.parent)
                    stdout, stderr = child.process.communicate(timeout=5)
                    break
        return subprocess.CompletedProcess(args, child.process.returncode, stdout, stderr)


class VerificationError(CandidateError):
    def __init__(self, message, command=None, shader_id=None, time=None):
        super().__init__(message)
        self.command = command
        self.shader_id = shader_id
        self.time = time


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def emit(event, **data):
    print(json.dumps(dict(event=event, **data)), flush=True)


def digest(value):
    if isinstance(value, str):
        value = value.encode()
    return hashlib.sha256(value).hexdigest()


def run(args, cwd, env=None, timeout=600, check=True, input=None):
    args = [str(a) for a in args]
    if env and env.get('HOLODECK_REQUEST_DIRECTORY'):
        result = managed_run(args, cwd, env, timeout, input)
    else:
        result = subprocess.run(args, cwd=cwd, env=env, input=input, capture_output=True, text=True, timeout=timeout)
    if result.stdout:
        emit("log", text=result.stdout[-32000:])
    if result.stderr:
        emit("log", text=result.stderr[-32000:])
    if check and result.returncode:
        raise OperationalError(f"{Path(str(args[0])).name} exited {result.returncode}: {result.stderr[-4000:]}")
    return result


class Worker:
    def __init__(self, config, directory):
        self.config = config
        self.root = Path(config["repository"]).resolve()
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.git_executable = config["git"]
        self.hooks = self.directory / "empty-hooks"
        self.hooks.mkdir(exist_ok=True)
        if any(self.hooks.iterdir()):
            raise OperationalError("App-owned hooks directory must be empty")
        self.git_arguments = [self.git_executable, "-c", "core.hooksPath=" + str(self.hooks)]
        self.env = dict(os.environ, GIT_TERMINAL_PROMPT="0", HOLODECK_SHADER_TOOL=config["shaderTool"], PYTHONDONTWRITEBYTECODE="1")
        scratch = self.directory / "tmp"; scratch.mkdir(exist_ok=True)
        self.env["TMPDIR"] = str(scratch)
        self.env['HOLODECK_REQUEST_DIRECTORY'] = str(self.directory)
        self.env["PATH"] = os.pathsep.join([str(Path(config["codex"]).parent), str(Path(config["python"]).parent),
                                             "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        self.request = {}
        self.checkpoint_path = self.directory / "checkpoint.json"
        self.checkpoint = json.loads(self.checkpoint_path.read_text()) if self.checkpoint_path.exists() else {}
        self.gitdir = Path(self.git("rev-parse", "--absolute-git-dir").strip())
        self.owner = self.gitdir / "holodeck-request-owner.json"
        self.checkout_identity = self.gitdir / "holodeck-checkout-id"
        if config.get("checkoutID") and (not self.checkout_identity.exists() or self.checkout_identity.read_text().strip() != config["checkoutID"]):
            raise OperationalError("Selected checkout identity does not match the request journal")
        self.object_format = self.git("rev-parse", "--show-object-format").strip()
        self.file_mode = self.git("config", "--bool", "core.fileMode", check=False).stdout.strip() != "false"

    def git(self, *args, check=True, raw=False):
        result = managed_run([*self.git_arguments, *args], self.root, self.env, timeout=60, input=None, text=not raw)
        if check and result.returncode:
            detail = result.stderr.decode("utf-8", errors="replace") if raw else result.stderr
            raise OperationalError("Git: " + detail[-4000:])
        return result.stdout if check else result

    def save(self, **values):
        self.checkpoint.update(values)
        write(self.checkpoint_path, self.checkpoint)

    def stage(self, name, message):
        self.save(stage=name)
        emit("stage", stage=name, message=message)

    @contextlib.contextmanager
    def workspace_parent(self, name, create=False):
        parts = name.split("/")
        if any(part in ("", ".", "..") for part in parts):
            raise OperationalError("Invalid workspace path: " + name)
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in parts[:-1]:
                if create:
                    try: os.mkdir(part, dir_fd=fd)
                    except FileExistsError: pass
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = child
            yield fd, parts[-1]
        finally:
            os.close(fd)

    def workspace_record(self, name):
        with self.workspace_parent(name) as (parent, leaf):
            info = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                link = os.readlink(leaf, dir_fd=parent)
                return {"mode": "120000", "hash": digest(os.fsencode(link)), "link": link}
            if not stat.S_ISREG(info.st_mode):
                raise WorkspaceTypeError("Workspace path must be a regular file: " + name)
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode):
                    raise WorkspaceTypeError("Workspace path must be a regular file: " + name)
                hasher = hashlib.sha256()
                for chunk in iter(lambda: source.read(65536), b""):
                    hasher.update(chunk)
                return {"mode": "100755" if info.st_mode & stat.S_IXUSR else "100644", "hash": hasher.hexdigest()}

    def read_workspace(self, name, limit=2097152):
        with self.workspace_parent(name) as (parent, leaf):
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, 'rb') as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    raise WorkspaceTypeError('Publication input must be a regular file: ' + name)
                data = source.read(limit + 1)
                if len(data) > limit: raise CandidateError('Publication input exceeds size limit: ' + name)
                return data

    def quarantine_obstructions(self, names):
        quarantine = self.gitdir / 'holodeck-recovery' / self.directory.name
        for name in sorted(names):
            parts = name.split('/')
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                for index, part in enumerate(parts):
                    try: info = os.stat(part, dir_fd=fd, follow_symlinks=False)
                    except FileNotFoundError: break
                    leaf = index == len(parts) - 1
                    expected = stat.S_ISREG(info.st_mode) if leaf else stat.S_ISDIR(info.st_mode)
                    if not expected:
                        quarantine.mkdir(parents=True, exist_ok=True, mode=0o700)
                        destination = quarantine / str(uuid.uuid4())
                        record = destination.with_name(destination.name + '.json')
                        write(record, {'originalPath': '/'.join(parts[:index + 1])})
                        with record.open('rb') as metadata: os.fsync(metadata.fileno())
                        parent = os.open(quarantine, os.O_RDONLY | os.O_DIRECTORY)
                        try: os.fsync(parent)
                        finally: os.close(parent)
                        try: os.rename(part, destination, src_dir_fd=fd)
                        except OSError as error:
                            raise OperationalError('Cannot quarantine owned obstruction ' + name + '; files retained: ' + str(error)) from error
                        break
                    if not leaf:
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                        os.close(fd); fd = child
            finally: os.close(fd)

    def clean(self, revision=None):
        # Only tracked and non-ignored candidate files belong to host cleanup.
        if self.owner.exists() and str(json.loads(self.owner.read_text()).get("id")).lower() == str(self.request.get("id")).lower():
            others = self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
            raw_changes = self.raw_workspace_changes()
            self.quarantine_obstructions(raw_changes | set(filter(None, others)))
            self.git("reset", "--hard", revision or self.checkpoint.get("base", "HEAD"))
            # Git can consider a filter-hidden edit clean even with checkout --force.
            # Remove those owned files first so checkout must reconstruct their bytes.
            for name in raw_changes:
                try:
                    with self.workspace_parent(name) as (parent, leaf): os.unlink(leaf, dir_fd=parent)
                except FileNotFoundError: pass
            self.git("checkout-index", "--all", "--force")
            tracked = set(filter(None, self.git('ls-files', '-z').split('\0')))
            for name in filter(None, others):
                if name in tracked or any(path.startswith(name + '/') for path in tracked): continue
                try:
                    with self.workspace_parent(name) as (parent, leaf): os.unlink(leaf, dir_fd=parent)
                except (FileNotFoundError, NotADirectoryError): pass
            self.owner.unlink(missing_ok=True)

    def park(self):
        self.save_patch()
        self.clean()

    def save_patch(self):
        base = self.checkpoint["base"]
        patch = self.git("diff", "--binary", base, raw=True)
        (self.directory / "changes.patch").write_bytes(patch)
        others = self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
        files = {}
        for name in filter(None, others):
            path = self.root / name
            if path.is_symlink() or not path.is_file():
                raise CandidateError("New source paths must be regular files")
            files[name] = base64.b64encode(path.read_bytes()).decode()
        write(self.directory / "untracked.json", files)

    def restore_patch(self):
        patch = self.directory / "changes.patch"
        if patch.exists() and patch.stat().st_size:
            result = self.git("apply", "--3way", str(patch), check=False)
            # A conflict is given to Codex; never push or verify unresolved files.
            if result.returncode:
                emit("log", text="Reapplying checkpoint requires conflict resolution by Codex.")
        untracked = self.directory / "untracked.json"
        if untracked.exists():
            for name, data in json.loads(untracked.read_text()).items():
                path = self.root / name
                if self.root not in path.resolve().parents:
                    raise OperationalError("Checkpoint path escapes managed checkout")
                if not path.exists():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(base64.b64decode(data))

    def synchronize(self):
        self.git_tree("HEAD")
        if self.owner.exists():
            owner = json.loads(self.owner.read_text())
            if str(owner.get("id")).lower() != self.request["id"].lower():
                raise OperationalError("Another interrupted request owns this checkout; recover it first")
            self.save_patch()
            self.clean()
        if self.git("status", "--porcelain", "--untracked-files=all").strip():
            raise OperationalError("Managed checkout has external uncommitted changes; they have been preserved")
        self.git("fetch", "origin", "main")
        remote = self.git("rev-parse", "origin/main").strip()
        head = self.git("rev-parse", "HEAD").strip()
        if head != remote and self.git("merge-base", "--is-ancestor", head, remote, check=False).returncode:
            raise OperationalError("Local commits are not on origin/main; commit/push them before enabling management")
        self.git("checkout", "-B", "main", "origin/main")
        self.save(base=remote, commitSHA=None)
        # Old publication snapshots must never become the baseline of a new attempt.
        (self.directory / "baseline-workspace.json").unlink(missing_ok=True)
        write(self.owner, {"id": self.request["id"], "directory": str(self.directory)})
        self.check_checkout_inputs()
        self.validate_baseline()
        write(self.directory / "baseline-workspace.json", self.candidate_manifest(compare_baseline=False))
        self.restore_patch()

    def discard(self):
        # Discarding owned work needs the durable request identity, even if its payload was corrupted.
        self.request = {"id": self.directory.name}
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sha = self.checkpoint.get("commitSHA")
            published = False
            if sha and self.owner.exists():
                self.git("fetch", "origin", "main")
                published = self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
            if published:
                self.clean(revision=sha)
            else:
                self.clean()
            for name in ("changes.patch", "untracked.json"):
                (self.directory / name).unlink(missing_ok=True)
        emit("discarded")

    def git_tree(self, revision):
        tree = {}
        for entry in filter(None, self.git("ls-tree", "-r", "-z", revision).split("\0")):
            descriptor, name = entry.split("\t", 1)
            mode, kind, oid = descriptor.split()
            if kind != "blob":
                raise OperationalError("Submodules and non-blob Git entries are unsupported: " + name)
            tree[name] = {"mode": mode, "oid": oid}
        return tree

    def blob_oid(self, data):
        return hashlib.new(self.object_format, b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()

    def publication_inputs(self):
        index = json.loads(self.read_workspace('index.json'))
        paths = {"index.json"}
        for sid in index["shaders"]:
            if not isinstance(sid, str) or re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", sid) is None:
                raise CandidateError("Invalid indexed shader ID")
            folder = f"shaders/{sid}/"
            paths.update((folder + "metadata.json", folder + "body.metal"))
            metadata = json.loads(self.read_workspace(folder + 'metadata.json'))
            shared = metadata["shared"]
            if shared not in (["common", "fragment"], ["common", "material", "fragment"]):
                raise CandidateError("Invalid shared declaration: " + sid)
            paths.update(f"shared/{part}.metal" for part in shared)
        return paths

    def require_publication_inputs(self, manifest):
        missing = self.publication_inputs() - manifest.keys()
        if missing:
            raise CandidateError("Publication input must be included in the verified commit: " + sorted(missing)[0])

    def check_checkout_inputs(self):
        tree = self.git_tree("HEAD")
        self.require_publication_inputs(tree)
        for name, entry in tree.items():
            if name in ("index.json", "authoring.json") or (name.startswith("shared/") and name.endswith(".metal")) or (name.startswith("shaders/") and name.endswith(("/body.metal", "/metadata.json"))):
                with self.workspace_parent(name) as (parent, leaf):
                    fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    with os.fdopen(fd, "rb") as file:
                        if not stat.S_ISREG(os.fstat(file.fileno()).st_mode):
                            raise OperationalError("Publication inputs must be regular files: " + name)
                        actual = self.blob_oid(file.read())
                if actual != entry["oid"]:
                    raise OperationalError("Publication input checkout bytes differ from Git (disable source filters/EOL conversion): " + name)

    def raw_workspace_changes(self):
        baseline = self.directory / "baseline-workspace.json"
        changed = set()
        if baseline.exists():
            for name, original in json.loads(baseline.read_text()).items():
                try:
                    current = self.workspace_record(name)
                    if not self.file_mode: current["mode"] = original["mode"]
                    differs = any(current[key] != original[key] for key in ("hash", "mode"))
                except (FileNotFoundError, NotADirectoryError, WorkspaceTypeError):
                    differs = True
                except OSError as error:
                    # O_NOFOLLOW rejects a symlinked parent before it can be traversed.
                    if error.errno not in (1, 20, 40, 62): raise
                    differs = True
                if differs: changed.add(name)
        return changed

    def candidate_manifest(self, compare_baseline=True):
        base = self.checkpoint.get("base", "HEAD")
        if not self.git("status", "--porcelain", "--untracked-files=all").strip(): base = "HEAD"
        tree = self.git_tree(base)
        changed = set(filter(None, self.git("diff", "--name-only", "-z", base).split("\0")))
        owned = self.owner.exists() and str(json.loads(self.owner.read_text()).get("id")).lower() == str(self.request.get("id")).lower()
        if compare_baseline and owned: changed.update(self.raw_workspace_changes())
        names = set(filter(None, self.git("ls-files", "-z").split("\0")))
        names.update(filter(None, self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")))
        manifest = {}
        for name in sorted(names):
            record = self.workspace_record(name)
            if not self.file_mode and name in tree: record["mode"] = tree[name]["mode"]
            if name in tree and name not in changed:
                record["oid"] = tree[name]["oid"]
            else:
                record["oid"] = self.blob_oid(os.fsencode(record['link']) if 'link' in record else self.read_workspace(name, limit=16777216))
            manifest[name] = record
        self.require_publication_inputs(manifest)
        return manifest

    def verify_commit(self, sha, manifest, check_workspace=True):
        tree = self.git_tree(sha)
        if all("oid" in value for value in manifest.values()):
            expected = {name: {key: value[key] for key in ("mode", "oid")} for name, value in manifest.items()}
            matches = tree == expected
        else:
            # Read old attempt journals without weakening their exact-byte proof.
            committed = {name: {"mode": value["mode"], "hash": digest(self.git("cat-file", "blob", value["oid"], raw=True))} for name, value in tree.items()}
            matches = committed == manifest
        workspace_matches = not check_workspace or self.candidate_manifest() == manifest
        if not matches or not workspace_matches:
            raise OperationalError("Committed tree differs from verified source; publication filters or external changes must be corrected")

    def begin_attempt(self):
        repair = self.directory / "repair.json"
        if repair.exists():
            payload = json.loads(repair.read_text())
            attempt = payload.get("attemptID") or "legacy-repair-" + digest(repair.read_bytes())
        else:
            attempt = "initial"
        if self.checkpoint.get("attemptID") != attempt:
            previous = self.previous_publication()
            sha = self.checkpoint.get("commitSHA")
            # Upgrade a pending old-format commit without adopting the prior publication as this repair.
            legacy_pending = self.checkpoint.get("attemptID") is None and sha and (not previous or sha != previous["commitSHA"])
            self.save(attemptID=attempt, commitSHA=sha if legacy_pending else None)

    def publication_result(self, outcome, sha):
        response = {k: outcome[k] for k in ("outputKind", "shaderID", "changed", "summary", "approximations")}
        previous = self.previous_publication()
        if previous:
            response["changed"] = outcome["changed"] or previous["changed"]
            if not outcome["changed"] and previous["shaderID"] == outcome["shaderID"]:
                sha = previous["commitSHA"]
                response["summary"] = previous["summary"] + " Verified again after activation repair; no further source changes were necessary."
                response["approximations"] = list(dict.fromkeys(previous["approximations"] + outcome["approximations"]))
        response.update(commitSHA=sha, deliveredSourceHash=None)
        return response

    def finish_publication(self, response):
        write(self.directory / "worker-result.json", response)
        self.owner.unlink(missing_ok=True)
        for name in ("changes.patch", "untracked.json", "repair.json"):
            (self.directory / name).unlink(missing_ok=True)
        emit("result", result=response)

    def fingerprint(self):
        value = self.git("diff", "--binary", self.checkpoint["base"], raw=True)
        for name in sorted(filter(None, self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0"))):
            path = self.root / name
            value += name.encode("utf-8") + digest(path.read_bytes()).encode("ascii")
        value += json.dumps(self.candidate_manifest(), sort_keys=True).encode()
        return digest(value)

    def source(self, shader_id, revision=None):
        def read(name):
            if revision:
                return self.git("show", f"{revision}:{name}", raw=True).decode("utf-8")
            path = self.root / name
            if path.is_symlink() or self.root not in path.resolve().parents:
                raise CandidateError("Source paths must stay inside the checkout")
            return path.read_bytes().decode("utf-8")
        meta = json.loads(read(f"shaders/{shader_id}/metadata.json"))
        shared = meta["shared"]
        if shared not in (["common", "fragment"], ["common", "material", "fragment"]):
            raise CandidateError("Invalid shared declaration")
        return "".join(read(f"shared/{part}.metal") for part in shared[:-1]) + read(f"shaders/{shader_id}/body.metal") + read("shared/fragment.metal")

    def previous_publication(self):
        path = self.directory / "worker-result.json"
        if not path.exists():
            return None
        try:
            previous = json.loads(path.read_text())
            if previous["outputKind"] not in ("new", "edited") or not previous["shaderID"]:
                raise ValueError("invalid saved result")
            return previous
        except (ValueError, KeyError, TypeError) as error:
            raise OperationalError("The saved publication result is corrupted") from error

    def baseline_ids(self):
        names = self.git("ls-tree", "-r", "--name-only", self.checkpoint["base"]).splitlines()
        return [p.split("/")[1] for p in names if p.startswith("shaders/") and p.endswith("/metadata.json")]

    def scope(self, outcome=None):
        base = self.checkpoint["base"]
        if self.git("rev-parse", "HEAD").strip() != base:
            raise OperationalError("Codex changed Git state; only the host may commit")
        paths = self.git("diff", "--name-only", base).splitlines()
        paths += list(filter(None, self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")))
        paths += sorted(self.raw_workspace_changes() - set(paths))
        primary = set()
        for name in paths:
            parts = name.split("/")
            if len(parts) == 3 and parts[0] == "shaders" and parts[2] in ("body.metal", "metadata.json"):
                primary.add(parts[1])
            elif name not in ("index.json", "shared/common.metal", "shared/material.metal", "shared/fragment.metal", "authoring.json"):
                raise CandidateError("Forbidden change: " + name)
            path = self.root / name
            if not path.is_file() or path.is_symlink():
                raise CandidateError("Files cannot be removed or replaced with symlinks: " + name)
        if len(primary) > 1:
            raise CandidateError("A request may change only one primary shader")
        if outcome:
            shader_id = outcome["shaderID"]
            if len(shader_id) > 100 or re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", shader_id) is None:
                raise CandidateError("Output ID must be a valid catalog ID")
            if primary and primary != {shader_id}:
                raise CandidateError("Output ID does not match the changed shader")
            existing = shader_id in self.baseline_ids()
            if not existing:
                reserved = {name.split("/")[1] for name in self.git("ls-tree", "-r", "--name-only", base).splitlines() if name.startswith("shaders/") and len(name.split("/")) >= 3}
                if shader_id in reserved or shader_id == self.request["context"]["shaderID"]:
                    raise CandidateError("New shaders and removed-context recreations require a fresh unused ID")
            previous = self.previous_publication()
            created_by_request = previous and previous["outputKind"] == "new" and previous["shaderID"] == shader_id
            expected_kind = "new" if not existing or created_by_request else "edited"
            if outcome["outputKind"] != expected_kind:
                raise CandidateError("Output kind disagrees with stable shader identity")
            if not existing and not outcome["changed"]:
                raise CandidateError("A new shader must change the repository")
            if self.request["purpose"] == "performance" and self.request["context"]["shaderID"] in self.baseline_ids() and shader_id != self.request["context"]["shaderID"]:
                raise CandidateError("Performance requests must improve their existing shader ID")
            repair_path = self.directory / "repair.json"
            if repair_path.exists():
                failed_id = json.loads(repair_path.read_text())["shaderID"]
                if failed_id in self.baseline_ids() and shader_id != failed_id:
                    raise CandidateError("Activation repair must retain the existing output ID")
                if failed_id not in self.baseline_ids() and existing:
                    raise CandidateError("A removed output must be recreated under a fresh ID")
            if self.request["purpose"] == "performance" and self.request["context"]["shaderID"] not in self.baseline_ids() and existing and not created_by_request:
                raise CandidateError("A removed performance target must be recreated under a fresh ID")
            old = json.loads(self.git("show", f"{base}:index.json"))
            new = json.loads((self.root / "index.json").read_text())
            if {k: v for k, v in new.items() if k not in ("shaders", "collections")} != {k: v for k, v in old.items() if k not in ("shaders", "collections")}:
                raise CandidateError("Unrelated catalog settings cannot change")
            if [c["id"] for c in old.get("collections", [])] != [c["id"] for c in new.get("collections", [])]:
                raise CandidateError("Preserve collection order and identities")
            expected = old["shaders"] + ([] if shader_id in old["shaders"] else [shader_id])
            if new["defaultShaderID"] != old["defaultShaderID"] or new["shaders"] != expected:
                raise CandidateError("Preserve the default and existing gallery order; append a new output")
            if expected_kind == "new":
                metadata = json.loads((self.root / f"shaders/{shader_id}/metadata.json").read_text())
                discovery = metadata.get("discovery", {})
                if not discovery.get("tags") or not discovery.get("moods") or not discovery.get("motion"):
                    raise CandidateError("A new shader requires discovery tags, moods and motion")
            if shader_id not in new["shaders"]:
                raise CandidateError("Output must be indexed")
            old_collections = {c["id"]: c for c in old.get("collections", [])}
            new_collections = {c["id"]: c for c in new.get("collections", [])}
            if old_collections.keys() != new_collections.keys():
                raise CandidateError("Use existing collections")
            for cid, previous in old_collections.items():
                current = new_collections[cid]
                if {k: v for k, v in current.items() if k != "shaderIDs"} != {k: v for k, v in previous.items() if k != "shaderIDs"}:
                    raise CandidateError("Collection definitions must stay unchanged")
                if [s for s in previous["shaderIDs"] if s != shader_id] != [s for s in current["shaderIDs"] if s != shader_id]:
                    raise CandidateError("Only the output shader's collection memberships may change")
            if bool(paths) != outcome["changed"]:
                raise CandidateError("Changed flag disagrees with the actual diff")
        if "authoring.json" in paths:
            def inventory(data):
                def unique(pairs):
                    result = {}
                    for key, value in pairs:
                        if key in result:
                            raise CandidateError("Duplicate attribution key: " + key)
                        result[key] = value
                    return result
                try:
                    value = json.loads(data, object_pairs_hook=unique)
                    if not isinstance(value, dict) or not isinstance(value.get("sourceRequirements"), dict) or not isinstance(value.get("upstreamRequirements"), dict):
                        raise CandidateError("Invalid attribution inventory")
                    for required in value["sourceRequirements"].values():
                        if not isinstance(required, list) or any(not isinstance(item, str) for item in required) or len(required) != len(set(required)):
                            raise CandidateError("Invalid attribution obligations")
                    return value
                except (ValueError, TypeError) as error:
                    raise CandidateError("Invalid attribution data: " + str(error)) from error
            old_records = inventory(self.git("show", f"{base}:authoring.json", raw=True))
            new_records = inventory((self.root / "authoring.json").read_bytes())
            protected = lambda value: {k: v for k, v in value.items() if k not in ("sourceRequirements", "upstreamRequirements")}
            if protected(old_records) != protected(new_records):
                raise CandidateError("Authoring schema and regression profiles cannot change")
            for path, notices in old_records["sourceRequirements"].items():
                if path not in new_records["sourceRequirements"] or not set(notices) <= set(new_records["sourceRequirements"][path]):
                    raise CandidateError("Existing attribution obligations cannot be weakened")
            allowed_sources = set(old_records["sourceRequirements"]) | {f"shaders/{sid}/body.metal" for sid in primary}
            if not set(new_records["sourceRequirements"]) <= allowed_sources:
                raise CandidateError("Unrelated notice records cannot be introduced")
            for key, value in old_records["upstreamRequirements"].items():
                if new_records["upstreamRequirements"].get(key) != value:
                    raise CandidateError("Existing upstream provenance cannot change")
        if self.git("diff", "--name-only", "--diff-filter=U").strip():
            raise CandidateError("Resolve all merge conflicts")
        return paths

    def codex(self, prompt, schema, label, images=(), resume=False):
        schema_path = self.directory / f"{label}-schema.json"
        output = self.directory / f"{label}-reply.json"
        write(schema_path, schema)
        output.unlink(missing_ok=True)
        args = [self.config["codex"], "--sandbox", "workspace-write" if label == "implementation" else "read-only",
                "--ask-for-approval", "never", "--model", self.config["model"],
                "--config", "model_reasoning_effort=" + json.dumps(self.config["reasoning"]), "exec"]
        if resume and self.checkpoint.get("threadID"):
            args.extend(["resume", self.checkpoint["threadID"]])
        args.extend(["--ignore-user-config", "--json", "--output-schema", str(schema_path), "--output-last-message", str(output)])
        for image in images:
            args.extend(["--image", str(image)])
        args.extend(["--", "-"])
        with (self.directory / f"{label}-stderr.log").open("a") as stderr:
            with ManagedChild(args, self.root, self.env, stdin=True, stderr=stderr, text=False) as child:
                for line in child.lines(prompt):
                    try:
                        event = json.loads(line)
                        if label == "implementation" and event.get("type") == "thread.started":
                            self.save(threadID=event["thread_id"])
                        emit("codex", data=event)
                    except ValueError:
                        emit("log", text=line[:32000])
                code = child.process.returncode
        if code or not output.exists():
            tail = (self.directory / f"{label}-stderr.log").read_text()[-4000:]
            raise OperationalError(f"Codex {label} failed ({code}): {tail}")
        try:
            return json.loads(output.read_text())
        except ValueError as error:
            raise OperationalError("Codex returned malformed structured output") from error

    def prompt(self, feedback):
        context = dict(self.request["context"])
        context.pop("screenshot", None)
        answer_path = self.directory / "answer.json"
        answer = json.loads(answer_path.read_text()) if answer_path.exists() else None
        repair_path = self.directory / "repair.json"
        repair = json.loads(repair_path.read_text()) if repair_path.exists() else None
        return """Implement one Holodeck shader request. Read AGENTS.md, skills/holodeck-authoring/SKILL.md and the authoring/library docs. Search assets with file search and direct reads, scaffold from templates, and preserve attribution.
The user is viewing the captured source below; the checkout is latest origin/main and may differ. Preserve intervening edits.
Choose any ONE existing shader ID to EDIT, retaining its ID, or create ONE unused ID. If the context was deleted, recreate under a fresh ID.
Ask a concise clarification only if intent is ambiguous. Unsupported audio/textures/multipass/app capabilities must be approximated using this runtime and disclosed.
New output: append to index.shaders and relevant EXISTING collections; preserve the default and existing ordering. Generate a name, metadata and discovery tags/moods/motion. If editing an unlisted existing shader, append its ID too so the TV can download it.
Allowed changes: one primary shader body/metadata, index membership, canonical shared helpers, and DATA ONLY in sourceRequirements/upstreamRequirements of authoring.json. Preserve schemaVersion and regressionProfiles.
Shared helper edits must preserve all shader, snippet and template interfaces. If a template breaks, repair or revert the helper; templates are not editable.
No tooling, test logic, other shader bodies, originals, previews, or app changes. Do NOT commit, push, change branches, or alter Git configuration.
For PERFORMANCE purpose: optimize the context ID (unless deleted), preserve composition/colors/motion/detail for all affected shaders; report no changes if latest already addresses the old evidence. Timings refer to the observed old source, not necessarily latest.
For activation repair: repair the failed OUTPUT ID from the diagnostic, preserving the creative intent. Recreate it if deleted. Classification belongs to the logical request: retain "new" for an output this request already created and published. The changed flag describes only this candidate diff; the host records earlier changes too.
GPU access can be unavailable inside the implementation sandbox. Do not render or run GPU/Xcode tests yourself; the unsandboxed host performs all technical/GPU/image checks independently.
Make one candidate and return the schema. A host independently verifies and reviews it. No attempt/time budget.
An unchanged existing shader may be successful if it already satisfies the prompt. Do not fabricate an empty change.
""" + json.dumps({"request": {k: v for k, v in self.request.items() if k != "context"},
                          "capturedContext": context, "answer": answer, "activationRepair": repair,
                          "previousOutput": self.checkpoint.get("outcome"), "previousPublication": self.previous_publication(), "verificationFeedback": feedback}, indent=2)

    def require_checker(self):
        """Compare data-only library expectations with the native tool's verified bundled identity."""
        try:
            raw = self.read_workspace('shader_checker.lock.json', limit=65536)
            executable = os.stat(self.config['shaderTool'])
            key = (raw, executable.st_ino, executable.st_size, executable.st_mtime_ns)
            if getattr(self, '_checker_identity_key', None) == key: return
            pin = json.loads(raw)
            fields = ('repository', 'version', 'interfaceVersion', 'sourceCommit', 'sha256')
            if not isinstance(pin, dict) or pin.get('repository') != 'hbmartin/HolodeckShaderCheck':
                raise ValueError('unapproved checker repository')
            for name, pattern in [('version', r'1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'), ('sourceCommit', r'[0-9a-f]{40}'), ('sha256', r'[0-9a-f]{64}')]:
                if type(pin.get(name)) is not str or re.fullmatch(pattern, pin[name]) is None:
                    raise ValueError('invalid checker lock ' + name)
            if type(pin.get('interfaceVersion')) is not int or pin['interfaceVersion'] != 1:
                raise ValueError('unsupported checker interface')
            identity = json.loads(run([self.config['shaderTool'], 'library', 'artifact-info', '--json'], self.root, self.env, timeout=5).stdout)
            if not isinstance(identity, dict) or any(type(identity.get(name)) is not type(pin[name]) or identity[name] != pin[name] for name in fields):
                raise ValueError('bundled checker identity differs from the selected library lock')
            info = json.loads(run([self.config['shaderTool'], 'library', 'info', '--json', '--python', self.config['python']], self.root, self.env, timeout=5).stdout)
            if not isinstance(info, dict) or type(info.get('interfaceVersion')) is not int or info['interfaceVersion'] != pin['interfaceVersion'] or info.get('checkerVersion') != pin['version']:
                raise ValueError('packaged checker reports a different version or interface')
            self._checker_identity_key = key
        except ProcessRecoveryError:
            raise
        except (ValueError, TypeError, KeyError, OSError, CandidateError, OperationalError, subprocess.TimeoutExpired) as error:
            raise OperationalError('Update Holodeck and the shader library together: ' + str(error)) from error

    def technical(self, baseline=False, commands=None):
        self.require_checker()
        self.stage("validating", "Compiling macOS and tvOS shaders and running authoring/GPU tests")
        commands = commands or [[self.config["shaderTool"], "library", "validate", str(self.root), phase, "--python", self.config["python"]]
                                for phase in ('--compile', '--gpu-only')]
        for command in commands:
            try:
                result = run(command, self.root, self.env, timeout=600, check=False)
            except subprocess.TimeoutExpired as error:
                if baseline: raise OperationalError("Baseline validation timed out") from error
                raise VerificationError("Candidate validation timed out", command=command) from error
            if result.returncode:
                message = (result.stdout + result.stderr)[-12000:] or f"Validation exited {result.returncode}"
                if baseline:
                    raise OperationalError("Baseline or host validation failed: " + message)
                raise VerificationError(message, command=command)

    def baseline_render(self, shader_id=None, time=None):
        sid = shader_id if shader_id in self.baseline_ids() else json.loads((self.root / "index.json").read_text())["defaultShaderID"]
        directory = self.directory / "baseline" / self.checkpoint["base"] / sid
        directory.mkdir(parents=True, exist_ok=True)
        source = directory / "source.metal"
        source.write_bytes(self.source(sid).encode("utf-8"))
        for sample in (0, 3, 10) if time is None else (time,):
            png = directory / f"{sample}.png"
            png.unlink(missing_ok=True)
            result = run([self.config["shaderTool"], "render", source, png, "--width", "1280", "--height", "720", "--time", str(sample)], self.root, self.env, timeout=60, check=False)
            if result.returncode or not self.valid_image(png):
                raise OperationalError("Baseline rendering or host GPU failed: " + sid)

    @staticmethod
    def valid_image(path):
        if not path.is_file():
            return False
        header = path.read_bytes()[:24]
        return header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) == 24 and struct.unpack(">II", header[16:24]) == (1280, 720)

    def validate_baseline(self):
        emit("log", text="Checking pristine main before restoring the candidate or invoking Codex")
        self.technical(baseline=True)
        self.baseline_render()

    def classify_verification_failure(self, error):
        # Keep one checkout: park the candidate while the same failing operation probes pristine base.
        self.save_patch()
        self.clean()
        write(self.owner, {"id": self.request["id"], "directory": str(self.directory)})
        try:
            if error.command:
                self.technical(baseline=True, commands=[error.command])
            else:
                self.baseline_render(error.shader_id, error.time)
        finally:
            self.restore_patch()

    def visual(self, outcome):
        self.stage("reviewing", "Rendering samples and running independent visual review")
        base = self.checkpoint["base"]
        before_ids = self.baseline_ids()
        after_ids = [p.parent.name for p in (self.root / "shaders").glob("*/metadata.json")]
        evidence = []
        attempt = self.checkpoint.get("verificationAttempt", 0) + 1
        self.save(verificationAttempt=attempt)
        evidence_root = self.directory / "evidence" / f"attempt-{attempt}"
        for sid in after_ids:
            after = self.source(sid)
            before = self.source(sid, base) if sid in before_ids else None
            if before == after and sid != outcome["shaderID"]:
                continue
            if before is None and sid == self.request["context"]["shaderID"]:
                before = self.request["context"]["source"]
            images = []
            hashes = {}
            for label, source in (("before", before), ("after", after)):
                if source is None:
                    continue
                hashes[label] = digest(source)
                path = evidence_root / sid / label
                path.mkdir(parents=True, exist_ok=True)
                metal = path / "source.metal"
                metal.write_text(source)
                for time in (0, 3, 10):
                    png = path / f"{time}.png"
                    png.unlink(missing_ok=True)
                    try:
                        result = run([self.config["shaderTool"], "render", metal, png, "--width", "1280", "--height", "720", "--time", str(time)], self.root, self.env, timeout=60, check=False)
                    except subprocess.TimeoutExpired as error:
                        if label == "before": raise OperationalError("Baseline render timed out: " + sid) from error
                        raise VerificationError("Candidate render timed out: " + sid, shader_id=sid, time=time) from error
                    if result.returncode or not self.valid_image(png):
                        if label == "before":
                            raise OperationalError("Baseline sample or host rendering failed: " + sid)
                        raise VerificationError("Missing, failed or incorrectly sized render evidence: " + sid, shader_id=sid, time=time)
                    images.append(png)
                    evidence.append({"shaderID": sid, "variant": label, "time": time, "sourceHash": hashes[label],
                                     "imageHash": digest(png.read_bytes()), "path": str(png)})
            captured = self.directory / "captured.png"
            stamp = digest(json.dumps({"requestID": self.request["id"], "prompt": self.request["prompt"], "outcome": outcome,
                                        "capturedImage": digest(captured.read_bytes()), "captureTime": self.request["context"].get("animationTime"),
                                        "diffHash": digest(self.git("diff", base, raw=True)), "sources": hashes, "images": [digest(p.read_bytes()) for p in images],
                                        "size": [1280, 720], "times": [0, 3, 10], "tool": digest(Path(self.config["shaderTool"]).read_bytes())}, sort_keys=True))
            schema = {"type": "object", "properties": {"passed": {"type": "boolean"}, "reason": {"type": "string"},
                      "evidenceDigest": {"type": "string", "enum": [stamp]}},
                      "required": ["passed", "reason", "evidenceDigest"], "additionalProperties": False}
            prompt = "Independently review the attached ACTUAL timed images (before then after, each at 0,3,10 seconds). Do not modify files. "
            prompt += "Check rendering, visual coherence and requested intent. For performance requests preserve composition, colors, motion and detail. "
            prompt += "For other affected shaders reject unintended visual regressions. Approximations are allowed only for unsupported runtime capabilities and must be disclosed. "
            prompt += "You may inspect source/diff; no physical TV or frame-rate success is claimed. "
            prompt += json.dumps({"shaderID": sid, "primary": sid == outcome["shaderID"], "request": self.request["prompt"],
                                  "purpose": self.request["purpose"], "outcome": outcome, "capturedContext": {k: v for k, v in self.request["context"].items() if k != "screenshot"}, "sourceHashes": hashes,
                                  "evidenceDigest": stamp, "diff": self.git("diff", self.checkpoint["base"])})
            screenshot = self.directory / "captured.png"
            if screenshot.exists():
                images.append(screenshot)
            verdict = self.codex(prompt, schema, "review-" + sid, images)
            write(evidence_root / sid / "verdict.json", verdict)
            if verdict.get("evidenceDigest") != stamp or verdict.get("passed") is not True:
                raise CandidateError("Independent visual review: " + verdict.get("reason", "invalid verdict"))
        write(evidence_root / "manifest.json", evidence)

    def required_previews(self, outcome=None):
        if outcome:
            base = self.checkpoint["base"]
            before_ids = self.baseline_ids()
            ids = json.loads((self.root / "index.json").read_text())["shaders"]
            required = [sid for sid in ids if sid == outcome["shaderID"] or sid not in before_ids or self.source(sid) != self.source(sid, base)]
            self.save(requiredPreviewShaderIDs=required)
            return required
        return self.checkpoint.get("requiredPreviewShaderIDs")

    def prepare_publication(self, required=None):
        self.require_checker()
        emit("preparePublication", requiredPreviewShaderIDs=required if required is not None else self.required_previews())
        response = sys.stdin.readline()
        reply = json.loads(response) if response else {}
        if reply.get("ok") is not True:
            raise OperationalError(reply.get("message") or "Mac could not prepare a complete publication")

    def prepare_current(self):
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            try: fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise OperationalError('Checkout is busy in another process; retry after it finishes.') from error
            if self.owner.exists(): raise OperationalError("An owned request must be recovered before rebuilding the library")
            if self.git("branch", "--show-current").strip() != "main" or self.git("status", "--porcelain", "--untracked-files=all").strip():
                raise OperationalError("Rebuilding requires a clean main checkout; no files or branches have been changed")
            self.check_checkout_inputs()
            self.save(base=self.git("rev-parse", "HEAD").strip())
            frozen = self.fingerprint(), self.candidate_manifest()
            self.prepare_publication(required=[])
            if frozen != (self.fingerprint(), self.candidate_manifest()):
                raise OperationalError("Checkout changed while rebuilding the publication")
            emit("publicationReady")

    def perform(self):
        self.request = json.loads((self.directory / "request.json").read_text())
        screenshot = self.directory / "captured.png"
        screenshot.write_bytes(base64.b64decode(self.request["context"]["screenshot"]))
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ready = self.directory / "worker-result.json"
            if ready.exists() and not (self.directory / "repair.json").exists():
                result = json.loads(ready.read_text())
                self.git("fetch", "origin", "main")
                if self.git("status", "--porcelain").strip():
                    raise OperationalError("Uncommitted work prevents publication recovery")
                if self.git("merge-base", "--is-ancestor", result["commitSHA"], "origin/main", check=False).returncode:
                    raise OperationalError("The previously pushed commit is no longer on main")
                self.git("checkout", "-B", "main", "origin/main")
                self.check_checkout_inputs()
                self.verify_commit("origin/main", self.candidate_manifest())
                self.prepare_publication()
                emit("result", result=result)
                return
            # Crash/lost-ack recovery: adopt an already-pushed request commit before reapplying any patch.
            self.begin_attempt()
            if self.checkpoint.get("commitSHA"):
                self.git("fetch", "origin", "main")
                sha = self.checkpoint["commitSHA"]
                if self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0:
                    outcome = self.checkpoint["outcome"]
                    manifest = self.checkpoint.get("commitManifest")
                    if manifest:
                        self.verify_commit(sha, manifest, check_workspace=False)
                    response = self.publication_result(outcome, sha)
                    self.clean(revision=sha)
                    if self.git("status", "--porcelain").strip():
                        raise OperationalError("Uncommitted files prevent recovery of the pushed result")
                    self.git("checkout", "-B", "main", "origin/main")
                    self.check_checkout_inputs()
                    self.verify_commit("origin/main", self.candidate_manifest())
                    self.prepare_publication()
                    self.finish_publication(response)
                    return
            self.synchronize()
            schema = {"type": "object", "properties": {"status": {"type": "string", "enum": ["completed", "needsClarification"]},
                      "outputKind": {"type": "string", "enum": ["new", "edited"]}, "shaderID": {"type": "string"},
                      "changed": {"type": "boolean"}, "summary": {"type": "string"},
                      "approximations": {"type": "array", "items": {"type": "string"}}, "question": {"type": "string"},
                      "options": {"type": "array", "items": {"type": "string"}}}, "additionalProperties": False}
            schema["required"] = list(schema["properties"])
            feedback = ""
            while True:
                self.stage("implementing", "Codex is working on the request")
                outcome = self.codex(self.prompt(feedback), schema, "implementation", [screenshot], resume=True)
                self.save(outcome=outcome)
                try:
                    self.scope()
                    if outcome["status"] == "needsClarification":
                        self.park()
                        emit("clarification", question=outcome["question"], options=outcome["options"])
                        return
                    self.scope(outcome)
                    frozen = self.fingerprint()
                    manifest = self.candidate_manifest()
                    self.technical()
                    self.visual(outcome)
                    if self.fingerprint() != frozen:
                        raise CandidateError("Candidate changed while verification was running")
                    # No writable agent runs after this point; all review inputs remain immutable.
                    self.git("fetch", "origin", "main")
                    if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                        self.synchronize()
                        feedback = "Remote main changed; reapply the intent, resolve conflicts, and repeat verification."
                        continue
                    self.prepare_publication(self.required_previews(outcome))
                    if self.fingerprint() != frozen or self.candidate_manifest() != manifest:
                        emit("discardPublication")
                        raise CandidateError("Candidate changed while preparing publication")
                    self.stage("pushing", "Committing verified changes and pushing to main")
                    write(self.directory / "candidate-manifest.json", manifest)
                    write(self.directory / "evidence" / f"attempt-{self.checkpoint['verificationAttempt']}" / "candidate-manifest.json", manifest)
                    if outcome["changed"]:
                        self.save_patch()
                        self.git("add", "--all")
                        message = f"{outcome['summary'][:180]}\n\nHolodeck-Request-ID: {self.request['id']}"
                        self.git("commit", "-m", message)
                        sha = self.git("rev-parse", "HEAD").strip()
                        self.verify_commit(sha, manifest)
                        self.save(commitSHA=sha, commitManifest=manifest)
                        result = self.git("push", "origin", "HEAD:main", check=False)
                        self.git("fetch", "origin", "main")
                        published = self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
                        if not published:
                            if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                                emit("discardPublication")
                                self.clean()
                                self.synchronize()
                                feedback = "Push raced with main; reapply checkpoint changes and reverify."
                                continue
                            raise OperationalError("Git push failed: " + result.stderr[-4000:])
                    else:
                        sha = self.checkpoint["base"]
                        self.verify_commit(sha, manifest)
                    self.finish_publication(self.publication_result(outcome, sha))
                    return
                except (CandidateError, ValueError, SyntaxError, KeyError, TypeError, IndexError) as error:
                    if isinstance(error, VerificationError):
                        self.classify_verification_failure(error)
                    feedback = str(error)
                    emit("log", text="Repairing shader defect: " + feedback)
                    self.stage("repairing", "Repairing verification findings")
                    self.git("fetch", "origin", "main")
                    if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                        self.synchronize()
                        feedback += " Latest main advanced; the request has been reapplied to it."
                    self.save_patch()

    def preflight(self):
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.preflight_locked()

    def preflight_locked(self):
        detached = self.config.get("detachedOwner")
        owner = json.loads(self.owner.read_text()) if self.owner.exists() else None
        if owner:
            identity = self.checkout_identity.read_text().strip() if self.checkout_identity.exists() else None
            matches = detached and str(owner.get("id")).lower() == detached["requestID"].lower()
            matches = matches and Path(owner.get("directory", "")).resolve() == Path(detached["directory"]).resolve()
            matches = matches and self.root == Path(detached["repository"]).resolve()
            if detached and detached.get("checkoutID"):
                matches = matches and identity == detached["checkoutID"]
            if not matches:
                raise OperationalError("Restore the owned checkout's original path, or select a fresh clean checkout. Owned work must be cleaned or explicitly detached before setup.")
        self.git_tree("HEAD")
        if self.git("rev-parse", "--show-toplevel").strip() != str(self.root):
            raise OperationalError("Choose the repository root")
        if self.git("status", "--porcelain", "--untracked-files=all").strip():
            raise OperationalError("Commit or remove uncommitted files before enabling app management")
        self.git("fetch", "origin", "main")
        head = self.git("rev-parse", "HEAD").strip()
        if self.git("merge-base", "--is-ancestor", head, "origin/main", check=False).returncode:
            raise OperationalError("Push your existing local commits first")
        for key in ("user.name", "user.email"):
            if not self.git("config", key).strip():
                raise OperationalError("Configure Git " + key)
        run([self.config["codex"], "--version"], self.root, self.env)
        run([self.config["codex"], "login", "status"], self.root, self.env)
        if sys.version_info < (3, 9):
            raise OperationalError("The shader checker requires Python 3.9 or later; choose a supported interpreter.")
        run([self.config["shaderTool"], "--version"], self.root, self.env)
        for sdk in ("appletvos", "macosx"):
            run(["/usr/bin/xcrun", "-sdk", sdk, "--find", "metal"], self.root, self.env)
        if not self.config.get("model", "").strip():
            raise OperationalError("Choose a Holodeck model")
        self.git("checkout", "-B", "main", "origin/main")
        self.check_checkout_inputs()
        self.git("push", "--dry-run", "origin", "HEAD:main")
        self.require_checker()
        try:
            configuration = json.loads(self.read_workspace('authoring.json'))
            if not isinstance(configuration, dict) or type(configuration.get('schemaVersion')) is not int or configuration['schemaVersion'] != 1:
                raise ValueError("missing authoring schema 1")
        except (ValueError, TypeError, KeyError, OSError) as error:
            raise OperationalError("Update Holodeck and the shader library together before enabling requests: " + str(error)) from error
        sid = json.loads((self.root / "index.json").read_text())["defaultShaderID"]
        source = self.directory / "setup.metal"
        source.write_text(self.source(sid))
        for sdk in ("macosx", "appletvos"):
            run(["/usr/bin/xcrun", "-sdk", sdk, "metal", "-c", source, "-o", self.directory / f"setup-{sdk}.air"], self.root, self.env)
        image = self.directory / "setup.png"
        run([self.config["shaderTool"], "render", source, image], self.root, self.env)
        schema = {"type": "object", "properties": {"imageDescription": {"type": "string"}}, "required": ["imageDescription"], "additionalProperties": False}
        self.codex("Describe the attached shader image in one sentence and return the required JSON. Do not change files.", schema, "setup", [image])
        if not self.checkout_identity.exists():
            self.checkout_identity.write_text(str(uuid.uuid4()))
        if owner:
            if json.loads(self.owner.read_text()) != owner:
                raise OperationalError("Checkout ownership changed during setup")
            self.owner.unlink()
        emit("preflight", message="Ready for shader requests", checkoutID=self.checkout_identity.read_text().strip())


def main():
    # All descendants share this request's group, so the native host can reconcile an orphan safely.
    with contextlib.suppress(PermissionError):
        os.setsid()
    config = json.loads(Path(sys.argv[2]).read_text())
    def interrupted(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise WorkerInterrupted(signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    worker = None
    try:
        worker = Worker(config, sys.argv[3])
        if sys.argv[1] == "preflight":
            worker.preflight()
        elif sys.argv[1] == "publication":
            worker.prepare_current()
        elif sys.argv[1] == "discard":
            worker.discard()
        else:
            worker.perform()
    except WorkerInterrupted:
        terminate_registered(sys.argv[3])
        sys.exit(130)
    except BaseException as error:
        if worker and worker.request and not isinstance(error, ProcessRecoveryError):
            # A lost push acknowledgement is reconciled before any destructive cleanup.
            published = False
            sha = worker.checkpoint.get("commitSHA")
            if sha:
                with contextlib.suppress(Exception):
                    worker.git("fetch", "origin", "main")
                    published = worker.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
            if not published:
                try:
                    worker.clean()
                    for name in ("changes.patch", "untracked.json"):
                        (worker.directory / name).unlink(missing_ok=True)
                except Exception as cleanup_error:
                    emit("log", text="Cleanup remains pending: " + str(cleanup_error))
            else:
                with contextlib.suppress(Exception):
                    worker.clean(revision=sha)
        emit("failure", message=str(error))
        sys.exit(1)


if __name__ == "__main__":
    main()
