#!/usr/bin/env python3
"""Single-checkout Codex worker. JSONL bridge; no shell interpolation or model-owned Git writes."""
import base64
import contextlib
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import re
import stat
import struct
import unicodedata
import uuid
import time


SHADER_ID_PATTERN = r"[a-z0-9]+(?:-[a-z0-9]+)*"
TECHNICAL_PHASES = {"compile": "--compile", "gpu": "--gpu-only"}
SAMPLE_TIMES = (0, 3, 10)
CANDIDATE_CHECKPOINT = "candidate-checkpoint.json"
PREVIOUS_CANDIDATE_CHECKPOINT = "candidate-checkpoint.previous.json"
FINGERPRINT_VERSION = 2
PATCH_DIFF_OPTIONS = ("--no-ext-diff", "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/")
TRACKED_PATCH_CONFLICT = "(tracked patch)"
REVERIFIED_SUMMARY = "Verified again after activation repair; no further source changes were necessary."


class CandidateError(RuntimeError):
    pass


class WorkspaceTypeError(CandidateError):
    pass


class WorkerInterrupted(BaseException):
    pass


# Load only the sibling packaged runtime, independent of CWD and isolated-mode sys.path.
import importlib.util
sys.dont_write_bytecode = True  # -I ignores PYTHONDONTWRITEBYTECODE; bundled resources stay immutable.
_process_spec = importlib.util.spec_from_file_location('_holodeck_worker_processes', Path(__file__).resolve().with_name('shader_processes.py'))
processes = importlib.util.module_from_spec(_process_spec)
try: _process_spec.loader.exec_module(processes)
except (OSError, ImportError) as error:
    if __name__ != '__main__': raise
    print(json.dumps(dict(event='failure', message='Bundled shader process runtime is missing or unreadable: ' + str(error), recoveryRequired=False)), flush=True)
    raise SystemExit(2)
globals().update({name: getattr(processes, name) for name in processes.__all__})


class CleanupError(OperationalError):
    pass


class VerificationError(CandidateError):
    def __init__(self, message, command=None, shader_id=None, time=None, *, phase):
        super().__init__(message)
        self.command = command
        self.shader_id = shader_id
        self.time = time
        self.phase = phase


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, value, *, durable=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        if durable:
            stream.flush()
            os.fsync(stream.fileno())
    temporary.replace(path)
    if durable:
        sync_directory(path.parent)


def emit(event, **data):
    print(json.dumps(dict(event=event, **data)), flush=True)


def digest(value):
    if isinstance(value, str):
        value = value.encode()
    return hashlib.sha256(value).hexdigest()


def git_file_mode(mode):
    return "100755" if mode & stat.S_IXUSR else "100644"


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
        checkout_config = self.git("config", "--type=bool", "--get-regexp", r"^core\.(filemode|ignorecase)$", check=False)
        values = dict(line.split(maxsplit=1) for line in checkout_config.stdout.splitlines())
        self.file_mode = values.get("core.filemode") != "false"
        self.ignore_case = values.get("core.ignorecase") == "true"

    def git(self, *args, check=True, raw=False, input=None):
        result = managed_run([*self.git_arguments, *args], self.root, self.env, timeout=60, input=input, text=not raw)
        if check and result.returncode:
            detail = result.stderr.decode("utf-8", errors="replace") if raw else result.stderr
            raise OperationalError("Git: " + detail[-4000:])
        return result.stdout if check else result

    def save(self, *, durable=False, **values):
        self.checkpoint.update(values)
        write(self.checkpoint_path, self.checkpoint, durable=durable)

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
                return {"mode": git_file_mode(info.st_mode), "hash": hasher.hexdigest()}

    def read_workspace(self, name, limit=2097152):
        data, _ = self.read_workspace_with_mode(name, limit)
        return data

    def read_workspace_with_mode(self, name, limit):
        with self.workspace_parent(name) as (parent, leaf):
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            with os.fdopen(fd, 'rb') as source:
                mode = os.fstat(source.fileno()).st_mode
                if not stat.S_ISREG(mode):
                    raise WorkspaceTypeError('Publication input must be a regular file: ' + name)
                data = source.read() if limit is None else source.read(limit + 1)
                if limit is not None and len(data) > limit: raise CandidateError('Publication input exceeds size limit: ' + name)
                return data, git_file_mode(mode)

    def quarantine_obstructions(self, names, *, move=True):
        quarantine = self.gitdir / 'holodeck-recovery' / self.directory.name
        quarantined = set()
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
                        original = '/'.join(parts[:index + 1])
                        quarantined.add(original)
                        if not move:
                            break
                        quarantine.mkdir(parents=True, exist_ok=True, mode=0o700)
                        destination = quarantine / str(uuid.uuid4())
                        record = destination.with_name(destination.name + '.json')
                        write(record, {'originalPath': original})
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
        return quarantined

    @staticmethod
    def safe_path(name):
        return (isinstance(name, str) and "\0" not in name
                and all(part.lower() not in ("", ".", "..", ".git") for part in name.split("/")))

    def read_record(self, path):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "r", encoding="utf-8") as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    raise ValueError("expected a regular file")
                record = json.load(source)
                if not isinstance(record, dict):
                    raise ValueError("expected a JSON object")
                return record
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as error:
            raise CleanupError(f"Cannot read {path.name}: {error}") from error

    def owned_record(self):
        owner = self.read_record(self.owner)
        if owner is None or not self.matches_request(owner):
            return None
        if owner.get("directory") != str(self.directory) or type(owner.get("checkpointParked", False)) is not bool:
            raise CleanupError("Invalid checkout owner journal identity or state")
        return owner

    def recoverable_owner(self):
        owner = self.owned_record()
        if owner is None and self.owner.exists():
            raise CleanupError("Another interrupted request owns this checkout. Recover that request first.")
        return owner

    def matches_request(self, record):
        request_id = self.request.get("id")
        owner_id = record.get("id")
        return isinstance(request_id, str) and isinstance(owner_id, str) and owner_id.lower() == request_id.lower()

    def mark_checkout(self, *, parked):
        write(self.owner, {"id": self.request["id"], "directory": str(self.directory),
                           "checkpointParked": parked}, durable=True)

    def has_pending_cleanup(self, owner):
        return (owner.get("checkpointParked") or "pendingShaderDirectories" in owner
                or (self.directory / "checkout-cleanup.json").exists())

    def record_paths(self, paths, label, prefix=""):
        if not isinstance(paths, list) or any(not self.safe_path(name) or not name.startswith(prefix) for name in paths):
            raise CleanupError("Invalid " + label)
        return set(paths)

    def shader_directories(self):
        directories = set()
        try:
            with self.workspace_parent("shaders/child") as (root, _):
                for folder, children, _, parent in os.fwalk(".", dir_fd=root, follow_symlinks=False):
                    children[:] = [name for name in children if self.safe_path(name)
                                   and stat.S_ISDIR(os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode)]
                    if folder != ".":
                        directories.add("shaders/" + folder[2:])
        except (FileNotFoundError, NotADirectoryError):
            pass
        return directories

    def cleanup_directories(self, others, legacy):
        baseline = self.read_record(self.directory / "baseline-directories.json")
        if baseline is not None:
            if not self.matches_request(baseline):
                raise CleanupError("Shader directory inventory belongs to another request")
            existing = self.record_paths(baseline.get("paths"), "shader directory inventory", "shaders/")
            directories = self.shader_directories() - existing
        else:
            # Legacy journals can only prove ownership from the saved list or owned files.
            directories = {parent.as_posix() for name in others if name.startswith("shaders/")
                           for parent in Path(name).parents if parent.as_posix().startswith("shaders/")}
        directories |= legacy
        if directories:
            paths = b"".join(os.fsencode(name) + b"/\0" for name in sorted(directories))
            result = self.git("check-ignore", "--no-index", "-z", "--stdin", raw=True, input=paths, check=False)
            if result.returncode not in (0, 1):
                raise CleanupError("Cannot identify ignored shader directories")
            directories -= {os.fsdecode(name).rstrip("/") for name in result.stdout.split(b"\0") if name}
        return directories

    def checkout_path_key(self, path):
        canonical = unicodedata.normalize("NFC", path)
        return canonical.casefold() if self.ignore_case else canonical

    def reclaim_palette_temp(self):
        journal = self.directory / "palette-temp.json"
        record = self.read_record(journal)
        if record is None:
            return
        name = record.get("path")
        if (not self.matches_request(record) or not isinstance(name, str)
                or not re.fullmatch(rf"shaders/{SHADER_ID_PATTERN}/\.metadata\.json-[0-9a-f]{{32}}\.tmp", name)):
            raise CleanupError("Invalid preview metadata temporary-file record")
        try:
            with self.workspace_parent(name) as (parent, leaf):
                os.unlink(leaf, dir_fd=parent)
        except (FileNotFoundError, NotADirectoryError):
            pass
        journal.unlink()

    def clean(self, revision=None):
        owner = self.owned_record()
        if owner is None:
            return False
        cleanup = self.directory / "checkout-cleanup.json"
        pending = self.read_record(cleanup)
        revision = revision or self.checkpoint.get("base", "HEAD")
        legacy = self.record_paths(owner.get("pendingShaderDirectories", []), "legacy pending shader directories", "shaders/")
        if any(not re.fullmatch(rf"shaders/{SHADER_ID_PATTERN}", name) for name in legacy):
            raise CleanupError("Invalid legacy pending shader directory")
        if pending is not None:
            revision = pending.get("revision")
            if not self.matches_request(pending) or not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
                raise CleanupError("Invalid checkout cleanup identity or revision")
            directories = self.record_paths(pending.get("directories"), "pending shader directories", "shaders/")
        else:
            directories = set()
        if not isinstance(revision, str) or not re.fullmatch(r"HEAD|[0-9a-f]{40}|[0-9a-f]{64}", revision):
            raise CleanupError("Invalid checkout cleanup revision")
        # Validate everything before altering the working tree.
        target = self.git("rev-parse", "--verify", revision + "^{commit}").strip()
        others = self.untracked_paths()
        directories |= self.cleanup_directories(others, legacy)
        write(cleanup, {"id": self.request["id"], "revision": target, "directories": sorted(directories)}, durable=True)
        self.reclaim_palette_temp()
        raw_changes = self.raw_workspace_changes()
        self.quarantine_obstructions(raw_changes | others)
        self.git("reset", "--hard", target)
        # Remove filter-hidden edits, then refresh index stat data for three-way apply.
        for name in raw_changes:
            try:
                with self.workspace_parent(name) as (parent, leaf):
                    os.unlink(leaf, dir_fd=parent)
            except FileNotFoundError:
                pass
        self.git("checkout-index", "--all", "--force", "--index")
        tracked = set(filter(None, self.git("ls-files", "-z").split("\0")))
        tracked_directories = {parent.as_posix() for name in tracked for parent in Path(name).parents}
        protected = {self.checkout_path_key(name) for name in tracked | tracked_directories}
        for name in sorted(others):
            if self.checkout_path_key(name) in protected:
                continue
            try:
                with self.workspace_parent(name) as (parent, leaf):
                    os.unlink(leaf, dir_fd=parent)
            except (FileNotFoundError, NotADirectoryError):
                pass
        for name in sorted(directories, key=lambda name: (-name.count("/"), name)):
            if self.checkout_path_key(name) in protected:
                continue
            try:
                with self.workspace_parent(name) as (parent, leaf):
                    os.rmdir(leaf, dir_fd=parent)
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.ENOTDIR, errno.ENOTEMPTY, errno.EEXIST):
                    raise
        self.owner.unlink(missing_ok=True)
        cleanup.unlink(missing_ok=True)
        return True

    def untracked_paths(self):
        return set(filter(None, self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")))

    def park(self):
        self.save_patch()
        self.park_checkpoint()

    def park_checkpoint(self):
        owner = self.owned_record()
        if owner is None:
            raise CleanupError("Cannot park a checkout without its request owner")
        if not self.has_pending_cleanup(owner):
            self.mark_checkout(parked=True)
        self.clean()

    def save_patch(self):
        try:
            self.reclaim_palette_temp()
            untracked = self.untracked_paths()
            changed = untracked | self.raw_workspace_changes()
            invalid = self.quarantine_obstructions(changed, move=False)
            # A quarantined tracked path is restored from the base, not checkpointed as a deletion.
            exclusions = [":(exclude,literal)" + name for name in sorted(invalid)]
            patch = self.git("diff", "--binary", *PATCH_DIFF_OPTIONS, self.checkpoint["base"], "--", *exclusions, raw=True)
            files = {}
            for name in sorted(untracked):
                if any(name == path or name.startswith(path + "/") for path in invalid):
                    continue
                data, mode = self.read_workspace_with_mode(name, limit=None)
                files[name] = {"data": base64.b64encode(data).decode(), "mode": mode}
            self.write_candidate_checkpoint({"patch": base64.b64encode(patch).decode(), "untracked": files})
            if invalid:
                diagnostic = ("Quarantined invalid workspace entries: " + ", ".join(sorted(invalid)))[:12000]
                emit("log", text=diagnostic)
                self.save(scopeRecovery=diagnostic, durable=True)
        except (CleanupError, SupervisionError):
            raise
        except (OSError, OperationalError, subprocess.TimeoutExpired) as error:
            raise CleanupError(f"Cannot save the candidate checkpoint. Live checkout edits were preserved: {error}") from error
        return bool(invalid)

    def write_candidate_checkpoint(self, snapshot):
        path = self.directory / CANDIDATE_CHECKPOINT
        previous = self.directory / PREVIOUS_CANDIDATE_CHECKPOINT
        if path.exists() and not previous.exists():
            os.link(path, previous, follow_symlinks=False)
        if previous.exists():
            # Keep the prior snapshot reachable even if syncing the replacement fails.
            sync_directory(self.directory)
        write(path, snapshot, durable=True)
        previous.unlink(missing_ok=True)

    def read_candidate_checkpoint(self):
        checkpoint = self.read_record(self.directory / CANDIDATE_CHECKPOINT)
        if checkpoint is None:
            checkpoint = self.read_record(self.directory / PREVIOUS_CANDIDATE_CHECKPOINT)
        if checkpoint is None:
            patch_path = self.directory / "changes.patch"
            patch = patch_path.read_bytes() if patch_path.exists() else b""
            checkpoint = {"patch": base64.b64encode(patch).decode(),
                          "untracked": self.read_record(self.directory / "untracked.json") or {}}
        try:
            files = checkpoint["untracked"]
            if not isinstance(files, dict) or any(not self.safe_path(name) for name in files):
                raise ValueError("invalid untracked paths")
            additions = {}
            for name, entry in files.items():
                if isinstance(entry, str):
                    data, mode = entry, None
                else:
                    data, mode = entry["data"], entry["mode"]
                    if mode not in ("100644", "100755"):
                        raise ValueError("invalid Git mode for " + name)
                additions[name] = base64.b64decode(data, validate=True), mode
            return base64.b64decode(checkpoint["patch"], validate=True), additions
        except (KeyError, TypeError, ValueError) as error:
            raise CleanupError(f"Invalid candidate checkpoint: {error}") from error

    def restore_conflicts(self, published_id):
        active = self.read_record(self.directory / "restore-conflicts.json") or {}
        if published_id is not None:
            for entry in active.values():
                if entry.get("retainedShaderID") == published_id:
                    entry.pop("retainedShaderID")
        return active

    def record_restore_conflicts(self, conflicts, patch):
        if not conflicts:
            return
        # Store evidence separately from the live checkpoint. Saving the next
        # candidate must never overwrite the only copy of a colliding addition.
        record = self.directory / "restore-conflicts.json"
        published_id = (self.previous_publication() or {}).get("shaderID")
        active = self.restore_conflicts(published_id)
        payload = {"files": conflicts, "patch": base64.b64encode(patch).decode()}
        evidence = self.directory / "restore-evidence" / (digest(json.dumps(payload, sort_keys=True)) + ".json")
        write(evidence, payload, durable=True)
        output = self.checkpoint.get("outcome") or {}
        new_id = output.get("shaderID") if output.get("outputKind") == "new" else None
        occupied_id = new_id if new_id and new_id != published_id and new_id in self.baseline_ids() else None
        for name, detail in conflicts.items():
            entry = {"path": name, "diagnostic": detail["diagnostic"], "evidenceFile": str(evidence)}
            if occupied_id and name.startswith(f"shaders/{occupied_id}/"):
                entry["retainedShaderID"] = occupied_id
            elif active.get(name, {}).get("retainedShaderID"):
                entry["retainedShaderID"] = active[name]["retainedShaderID"]
            active[name] = entry
        write(record, active, durable=True)

    def restore_patch(self):
        patch, untracked = self.read_candidate_checkpoint()
        conflicts = {}
        if patch:
            result = self.git("apply", "--3way", "-", input=patch, raw=True, check=False)
            if result.returncode:
                message = "Reapplying checkpoint requires conflict resolution by Codex."
                if result.stderr:
                    message += "\n" + result.stderr[-4000:].decode(errors="replace").strip()
                emit("log", text=message)
                names = self.git("diff", "--name-only", "--diff-filter=U", "-z").split("\0")
                for name in list(filter(None, names)) or [TRACKED_PATCH_CONFLICT]:
                    conflicts[name] = {"diagnostic": message}
        for name, (data, mode) in untracked.items():
            try:
                with self.workspace_parent(name, create=True) as (parent, leaf):
                    fd = os.open(leaf, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=parent)
                    with os.fdopen(fd, "wb") as target:
                        target.write(data)
                        if self.file_mode and mode == "100755":
                            mode_bits = stat.S_IMODE(os.fstat(target.fileno()).st_mode)
                            os.fchmod(target.fileno(), mode_bits | stat.S_IXUSR)
            except OSError as error:
                if error.errno not in (errno.EEXIST, errno.ENOTDIR, errno.ELOOP):
                    raise CleanupError(f"Cannot restore candidate file {name}: {error}") from error
                try:
                    existing_data, existing_mode = self.read_workspace_with_mode(name, limit=None)
                    if existing_data == data and (not self.file_mode or mode is None or mode == existing_mode):
                        continue
                except (OSError, WorkspaceTypeError):
                    pass
                message = "Reapplying checkpoint encountered an existing path: " + name
                emit("log", text=message)
                conflicts[name] = {"diagnostic": message, "candidate": base64.b64encode(data).decode()}
                if self.file_mode and mode is not None:
                    conflicts[name]["candidateMode"] = mode
        self.record_restore_conflicts(conflicts, patch)
        return bool(conflicts)

    def restore_owned_patch(self):
        conflicted = self.restore_patch()
        repair = self.checkpoint.get("verificationRepair")
        if conflicted and repair:
            self.save(verificationRepair={**repair, "restoreConflict": True}, durable=True)
        self.mark_checkout(parked=False)
        return conflicted

    def unmerged_paths(self):
        return set(filter(None, self.git("diff", "--name-only", "--diff-filter=U", "-z").split("\0")))

    def check_candidate_head(self):
        if self.git("rev-parse", "HEAD").strip() != self.checkpoint["base"]:
            raise OperationalError("Codex changed Git state; only the host may commit")

    def check_conflict_markers(self, paths, unmerged):
        if not paths:
            return
        path_list = b"".join(os.fsencode(name) + b"\0" for name in paths)
        attributes = self.git("check-attr", "-z", "--stdin", "conflict-marker-size", input=path_list, raw=True).split(b"\0")
        widths = {os.fsdecode(name): int(value) for name, value in zip(attributes[::3], attributes[2::3])
                  if value.isdigit() and len(value) < 10 and int(value) > 0}
        for name in paths:
            try:
                data = self.read_workspace(name, limit=None)
            except (OSError, WorkspaceTypeError) as error:
                if isinstance(error, FileNotFoundError) and name not in unmerged:
                    continue
                if isinstance(error, OSError) and error.errno not in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
                    raise CleanupError(f"Cannot read the resolved candidate file {name}: {error}") from error
                raise CandidateError("Restore a regular file before resolving the merge conflict: " + name) from error
            width = widths.get(name, 7)
            for line in data.splitlines():
                marker = line.partition(b" ")[0]
                # A separator alone is ambiguous with an ordinary source banner.
                if len(marker) == width and marker[:1] in (b"<", b">", b"|") and marker.count(marker[:1]) == width:
                    raise CandidateError("Remove merge conflict markers from " + name)

    def accept_restore_resolution(self, outcome, conflicts):
        self.check_candidate_head()
        if set(outcome.get("resolvedRestoreConflicts", [])) != set(conflicts):
            raise CandidateError("Account for every restored conflict before proceeding")
        retained = {entry["retainedShaderID"] for entry in conflicts.values() if "retainedShaderID" in entry}
        if retained and (outcome["outputKind"] != "new" or outcome["shaderID"] in retained):
            raise CandidateError("Preserve the upstream shader and recreate the candidate under an unused ID")
        unmerged = self.unmerged_paths()
        paths = set(conflicts) - {TRACKED_PATCH_CONFLICT}
        if any(not self.safe_path(name) for name in paths):
            raise CleanupError("Invalid tracked restore conflict path")
        if unmerged - paths:
            raise CandidateError("Resolve all merge conflicts")
        self.check_conflict_markers(sorted(paths), unmerged)
        if unmerged:
            # Only the worker may change Git state. Reset the index entries to
            # the upstream versions and leave the reconciled worktree bytes for scope and verification.
            paths = [":(literal)" + name for name in sorted(unmerged)]
            self.git("reset", "--quiet", self.checkpoint["base"], "--", *paths)

    def prepare_baseline(self):
        self.check_checkout_inputs()
        self.validate_baseline()
        write(self.directory / "baseline-workspace.json", self.candidate_manifest(compare_baseline=False))
        write(self.directory / "baseline-directories.json",
              {"id": self.request["id"], "paths": sorted(self.shader_directories())}, durable=True)

    def synchronize(self):
        self.git_tree("HEAD")
        owner = self.recoverable_owner()
        if owner is not None:
            if self.has_pending_cleanup(owner):
                self.read_candidate_checkpoint()
                self.clean()
            else:
                self.park()
        if self.git("status", "--porcelain", "--untracked-files=all").strip():
            raise OperationalError("Managed checkout has external uncommitted changes; they have been preserved")
        self.git("fetch", "origin", "main")
        remote = self.git("rev-parse", "origin/main").strip()
        head = self.git("rev-parse", "HEAD").strip()
        if head != remote and self.git("merge-base", "--is-ancestor", head, remote, check=False).returncode:
            raise OperationalError("Local commits are not on origin/main; commit/push them before enabling management")
        # A completed reset may have stopped just after releasing ownership.
        (self.directory / "checkout-cleanup.json").unlink(missing_ok=True)
        self.git("checkout", "-B", "main", "origin/main")
        self.save(base=remote, commitSHA=None, publicationCommitPending=False)
        for name in ("baseline-workspace.json", "baseline-directories.json"):
            (self.directory / name).unlink(missing_ok=True)
        self.mark_checkout(parked=True)
        self.prepare_baseline()
        repair = self.checkpoint.get("verificationRepair") or {}
        if repair.get("pending") and repair.get("base") == remote:
            self.probe_candidate_failure(repair)
            self.save(verificationRepair={**repair, "pending": False}, durable=True)
        self.restore_owned_patch()

    def clear_candidate_checkpoint(self):
        for name in (PREVIOUS_CANDIDATE_CHECKPOINT, CANDIDATE_CHECKPOINT + ".tmp", "changes.patch", "untracked.json",
                     "restore-conflicts.json", "baseline-directories.json"):
            path = self.directory / name
            path.unlink(missing_ok=True)
            if path.suffix == ".json":
                path.with_suffix(".json.tmp").unlink(missing_ok=True)
        evidence = self.directory / "restore-evidence"
        if evidence.is_dir():
            for pattern in ("*.json", "*.json.tmp"):
                for path in evidence.glob(pattern):
                    path.unlink(missing_ok=True)
            evidence.rmdir()
        # The reader may fall back to older files while the primary is absent.
        sync_directory(self.directory)
        (self.directory / CANDIDATE_CHECKPOINT).unlink(missing_ok=True)
        sync_directory(self.directory)

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
            self.clear_candidate_checkpoint()
            self.save(verificationRepair=None, verifiedCandidate=None, scopeRecovery=None)
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
            if not isinstance(sid, str) or re.fullmatch(SHADER_ID_PATTERN, sid) is None:
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
            if not self.file_mode and record["mode"] in ("100644", "100755"):
                base_mode = tree.get(name, {}).get("mode")
                record["mode"] = "100755" if base_mode == "100755" else "100644"
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

    def stage_candidate(self, manifest):
        self.git("add", "--all")
        if self.file_mode:
            return
        modes = {"100644": [], "100755": []}
        for entry in filter(None, self.git("ls-files", "--stage", "-z").split("\0")):
            descriptor, name = entry.split("\t", 1)
            current = descriptor.split()[0]
            desired = manifest.get(name, {}).get("mode")
            if current in modes and desired in modes and current != desired:
                modes[desired].append(name)
        for mode, names in modes.items():
            if names:
                self.git("update-index", "--chmod=" + ("+x" if mode == "100755" else "-x"), "--", *names)

    def active_repair_attempt(self):
        repair = self.directory / "repair.json"
        try:
            data = repair.read_bytes()
        except FileNotFoundError:
            return None
        except OSError as error:
            raise CleanupError(f"Cannot read activation repair journal: {error}") from error
        try:
            payload = json.loads(data)
            attempt = payload.get("attemptID") if isinstance(payload, dict) else None
            if not isinstance(payload, dict) or (attempt is not None and not isinstance(attempt, str)):
                raise ValueError("Invalid activation repair attempt")
        except (ValueError, TypeError) as error:
            raise CleanupError(f"Cannot read activation repair journal: {error}") from error
        return attempt or "legacy-repair-" + digest(data)

    def begin_attempt(self, repair_attempt):
        attempt = repair_attempt or "initial"
        if self.checkpoint.get("attemptID") != attempt:
            previous = self.previous_publication()
            sha = self.checkpoint.get("commitSHA")
            # Upgrade a pending old-format commit without adopting the prior publication as this repair.
            legacy_pending = self.checkpoint.get("attemptID") is None and sha and (not previous or sha != previous["commitSHA"])
            self.save(attemptID=attempt, commitSHA=sha if legacy_pending else None,
                      verificationRepair=None, verifiedCandidate=None, scopeRecovery=None, publicationCommitPending=False)

    def publication_result(self, outcome, sha):
        response = {k: outcome[k] for k in ("outputKind", "shaderID", "changed", "summary", "approximations")}
        previous = self.previous_publication()
        if previous:
            response["changed"] = outcome["changed"] or previous["changed"]
            if not outcome["changed"] and previous["shaderID"] == outcome["shaderID"]:
                sha = previous["commitSHA"]
                response["summary"] = previous["summary"]
                if not response["summary"].endswith(REVERIFIED_SUMMARY):
                    response["summary"] += " " + REVERIFIED_SUMMARY
                response["approximations"] = list(dict.fromkeys(previous["approximations"] + outcome["approximations"]))
        response.update(commitSHA=sha, deliveredSourceHash=None)
        return response

    def finish_publication(self, response):
        saved = {**response, "attemptID": self.checkpoint["attemptID"]}
        try:
            write(self.directory / "worker-result.json", saved, durable=True)
        except OSError as error:
            raise CleanupError(f"Cannot save the publication result: {error}") from error
        self.emit_saved_publication(saved)

    def emit_saved_publication(self, saved):
        try:
            self.retire_published_candidate()
            repair_attempt = self.active_repair_attempt()
            if repair_attempt is not None and saved.get("attemptID") == repair_attempt:
                (self.directory / "repair.json").unlink(missing_ok=True)
                sync_directory(self.directory)
        except OSError as error:
            raise CleanupError(f"Cannot finalize the saved publication: {error}") from error
        emit("result", result={key: value for key, value in saved.items() if key != "attemptID"})

    def retire_published_candidate(self):
        owner = self.owned_record()
        try:
            self.clear_candidate_checkpoint()
            if owner is not None:
                self.owner.unlink(missing_ok=True)
                sync_directory(self.gitdir)
        except OSError as error:
            raise CleanupError(f"Cannot retire the published candidate checkpoint: {error}") from error

    def fingerprint(self, manifest=None):
        if manifest is None:
            manifest = self.candidate_manifest()
        return digest(json.dumps(manifest, sort_keys=True))

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

    def scope(self, outcome=None, *, allowed_unmerged=()):
        self.check_candidate_head()
        base = self.checkpoint["base"]
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
            if len(shader_id) > 100 or re.fullmatch(SHADER_ID_PATTERN, shader_id) is None:
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
                if not isinstance(metadata, dict):
                    raise CandidateError("Output shader metadata must be a JSON object")
                discovery = metadata.get("discovery", {})
                if not isinstance(discovery, dict) or not discovery.get("tags") or not discovery.get("moods") or not discovery.get("motion"):
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
        if self.unmerged_paths().difference(allowed_unmerged):
            raise CandidateError("Resolve all merge conflicts")
        return paths

    def normalize_preview_colors(self, outcome):
        shader_id = outcome["shaderID"]
        if outcome["outputKind"] != "new" or shader_id in self.baseline_ids():
            return

        def unique_fields(pairs):
            fields = dict(pairs)
            if len(fields) != len(pairs):
                raise ValueError("Duplicate metadata key")
            return fields

        name = f"shaders/{shader_id}/metadata.json"
        try:
            metadata = json.loads(self.read_workspace(name), object_pairs_hook=unique_fields)
        except ValueError:
            return  # Let the checker report invalid metadata without rewriting it.
        colors = metadata.get("colors")
        if not isinstance(colors, list) or len(colors) != 3:
            return
        if not all(
            isinstance(color, list) and len(color) == 3
            and all(type(component) in (int, float) and 0 <= component <= 1 for component in color)
            for color in colors
        ):
            return

        metadata["colors"] = colors[:2]
        try:
            contents = json.dumps(metadata, indent=2, allow_nan=False, ensure_ascii=False) + "\n"
        except ValueError:
            return
        with self.workspace_parent(name) as (parent, leaf):
            mode = os.stat(leaf, dir_fd=parent, follow_symlinks=False).st_mode
            if not stat.S_ISREG(mode):
                raise WorkspaceTypeError("Preview metadata must be a regular file: " + name)
            temporary = f".{leaf}-{uuid.uuid4().hex}.tmp"
            journal = self.directory / "palette-temp.json"
            write(journal, {"id": self.request["id"], "path": name.rsplit("/", 1)[0] + "/" + temporary}, durable=True)
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as target:
                    target.write(contents)
                    os.fchmod(target.fileno(), stat.S_IMODE(mode))
                os.replace(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent)
            finally:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary, dir_fd=parent)
                journal.unlink()
        emit("log", text=f"Trimmed preview colors for {shader_id} from three to two. Dropped {colors[2]}.")

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
                code = child.command_returncode
        if code or not output.exists():
            tail = (self.directory / f"{label}-stderr.log").read_text()[-4000:]
            raise OperationalError(f"Codex {label} failed ({code}): {tail}")
        try:
            return json.loads(output.read_text())
        except ValueError as error:
            raise OperationalError("Codex returned malformed structured output") from error

    def repair_prompt_context(self, repair):
        base = self.checkpoint["base"]
        changed = self.git("diff", "--name-only", "-z", base).split("\0")
        untracked = self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
        paths = sorted((set(changed) | set(untracked) | self.raw_workspace_changes()) - {""})
        allowed = [path for path in paths if path in (
            "index.json", "authoring.json", "shared/common.metal", "shared/material.metal", "shared/fragment.metal"
        ) or re.fullmatch(rf"shaders/{SHADER_ID_PATTERN}/(?:body\.metal|metadata\.json)", path)]
        target = f"shaders/{repair.get('shaderID')}/"
        allowed.sort(key=lambda path: (not path.startswith(target), path))
        forbidden = sorted(set(paths) - set(allowed))
        offending = []
        if repair.get("phase") == "scope":
            _, separator, name = repair.get("diagnostic", "").partition(": ")
            if separator and name in paths:
                offending.append(name)
        visible = list(dict.fromkeys(offending + allowed + forbidden))[:64]
        target_paths = [path for path in allowed if path.startswith(target)]
        other_paths = [path for path in allowed[:64] if path not in target_paths]
        diff = b""
        for group in (target_paths, other_paths):
            if group and len(diff) <= 16384:
                diff += self.git("diff", *PATCH_DIFF_OPTIONS, base, "--", *group, raw=True)
        return {
            **repair,
            "baseAdvanced": repair["base"] != base,
            "changedPaths": visible,
            "changedPathsTruncated": len(paths) > len(visible),
            "candidateDiff": diff[:16384].decode("utf-8", errors="replace"),
            "candidateDiffTruncated": len(diff) > 16384 or len(allowed) > 64,
        }

    def prompt(self, feedback, verification_repair=None, conflicts=None):
        context = dict(self.request["context"])
        context.pop("screenshot", None)
        answer_path = self.directory / "answer.json"
        answer = json.loads(answer_path.read_text()) if answer_path.exists() else None
        repair_path = self.directory / "repair.json"
        repair = json.loads(repair_path.read_text()) if repair_path.exists() else None
        if conflicts:
            action = """Reconcile the saved Holodeck candidate with the current checkout. Inspect every restoreConflicts entry.
The checkout contains upstream files. The evidence JSON contains candidate additions as base64 in files[path].candidate and the saved tracked diff as base64 in patch.
Use files[path].candidateMode when present to reproduce the candidate's Git executable bit.
If a conflict lists retainedShaderID, preserve the upstream shader and recreate the unpublished candidate under one fresh ID.
If this request already published the existing activation output, retain its ID and reconcile the repair with upstream edits to that shader.
Reconcile index and attribution records with upstream.
Resolve every listed conflict and include its path in resolvedRestoreConflicts when returning a completed candidate.
"""
        elif verification_repair or self.checkpoint.get("scopeRecovery"):
            action = """Repair the existing Holodeck shader candidate. Start with the failed check in verificationRepair and make the smallest edit that addresses it while preserving the request's intent.
Inspect the restored files for context, including any newly created shader files listed in changedPaths. The diagnostic and diff are evidence about the failure.
If main advanced or checkpoint reapply conflicted, reconcile the current checkout and confirm that the earlier failure still applies. Resolve workspace scope errors before attempting shader changes.
"""
        else:
            action = """Implement one Holodeck shader request. Search assets with file search and direct reads, and scaffold from templates.
Choose any ONE existing shader ID to EDIT, retaining its ID, or create ONE unused ID.
"""
        return action + """Read AGENTS.md, skills/holodeck-authoring/SKILL.md and the authoring/library docs. Preserve attribution.
The user is viewing the captured source below; the checkout is latest origin/main and may differ. Preserve intervening edits.
If the context was deleted, recreate under a fresh ID.
Ask a concise clarification only if intent is ambiguous. Unsupported audio/textures/multipass/app capabilities must be approximated using this runtime and disclosed.
New output: append to index.shaders and relevant EXISTING collections; preserve the default and existing ordering. Generate a name, metadata and discovery tags/moods/motion. If editing an unlisted existing shader, append its ID too so the TV can download it.
In shader metadata, colors contains exactly two RGB triples for the preview gradient. Each component is a number between 0 and 1.
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
                          "previousOutput": self.checkpoint.get("outcome"), "previousPublication": self.previous_publication(),
                          "verificationFeedback": feedback,
                          "scopeRecovery": self.checkpoint.get("scopeRecovery"),
                          "restoreConflicts": list(conflicts.values()) if conflicts else [],
                          "verificationRepair": self.repair_prompt_context(verification_repair) if verification_repair else None}, indent=2)

    def require_checker(self):
        """Validate data-only expectations and distinguish launch faults from identity mismatch."""
        fields = ('repository', 'version', 'interfaceVersion', 'sourceCommit', 'sha256')
        try:
            raw = self.read_workspace('shader_checker.lock.json', limit=65536)
            pin = json.loads(raw)
            if not isinstance(pin, dict) or pin.get('repository') != 'hbmartin/HolodeckShaderCheck':
                raise ValueError('unapproved checker repository')
            for name, pattern in [('version', r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'), ('sourceCommit', r'[0-9a-f]{40}'), ('sha256', r'[0-9a-f]{64}')]:
                if type(pin.get(name)) is not str or re.fullmatch(pattern, pin[name]) is None: raise ValueError('invalid ' + name)
            if type(pin.get('interfaceVersion')) is not int or pin['interfaceVersion'] < 1: raise ValueError('invalid checker interface')
        except (OSError, ValueError, TypeError, CandidateError) as error:
            raise OperationalError('Selected library checker lock is invalid or unreadable: ' + str(error)) from error
        if pin['interfaceVersion'] != 1 or int(pin['version'].split('.')[0]) != 1:
            raise OperationalError('Update Holodeck and the shader library together: selected library requires an unsupported checker version or interface')
        try: executable = os.stat(self.config['shaderTool'])
        except OSError as error: raise OperationalError('Cannot inspect the configured shader tool: ' + str(error)) from error
        key = (raw, executable.st_ino, executable.st_size, executable.st_mtime_ns)
        if getattr(self, '_checker_identity_key', None) == key: return
        def probe(arguments, label):
            try: result = run([self.config['shaderTool'], 'library', *arguments], self.root, self.env, timeout=30)
            except SupervisionError: raise
            except subprocess.TimeoutExpired as error:
                raise OperationalError(label + ' timed out after 30 seconds. Retry when the native tool can start normally.') from error
            except (OSError, OperationalError) as error:
                raise OperationalError(label + ' could not run: ' + str(error)) from error
            try: response = json.loads(result.stdout)
            except (ValueError, TypeError) as error: raise OperationalError(label + ' returned malformed JSON: ' + str(error)) from error
            if not isinstance(response, dict): raise OperationalError(label + ' returned a malformed response')
            return response
        identity = probe(['artifact-info', '--json'], 'Native artifact identity probe')
        if any(type(identity.get(name)) is not type(pin[name]) for name in fields) or any(
                re.fullmatch(pattern, identity.get(name, '')) is None for name, pattern in
                [('version', r'[0-9]+\.[0-9]+\.[0-9]+'), ('sourceCommit', r'[0-9a-f]{40}'), ('sha256', r'[0-9a-f]{64}')]):
            raise OperationalError('Native artifact identity probe returned malformed identity fields')
        if any(identity[name] != pin[name] for name in fields):
            raise OperationalError('Update Holodeck and the shader library together: bundled checker identity differs from the selected library lock')
        info = probe(['info', '--json', '--python', self.config['python']], 'Packaged checker information probe')
        if type(info.get('interfaceVersion')) is not int or type(info.get('checkerVersion')) is not str or re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', info['checkerVersion']) is None:
            raise OperationalError('Packaged checker information probe returned malformed version/interface fields')
        if info['interfaceVersion'] != pin['interfaceVersion'] or info['checkerVersion'] != pin['version']:
            raise OperationalError('Update Holodeck and the shader library together: packaged checker reports a different version or interface')
        self._checker_identity_key = key

    def technical(self, baseline=False, commands=None, *, first_phase=None):
        self.require_checker()
        self.stage("validating", "Compiling macOS and tvOS shaders and running authoring/GPU tests")
        if not commands:
            phases = sorted(TECHNICAL_PHASES, key=lambda phase: phase != first_phase)
            commands = [[self.config["shaderTool"], "library", "validate", str(self.root), TECHNICAL_PHASES[phase],
                         "--python", self.config["python"]] for phase in phases]
        for command in commands:
            phase = next((name for name, flag in TECHNICAL_PHASES.items() if flag in command), "validation")
            try:
                result = run(command, self.root, self.env, timeout=600, check=False)
            except subprocess.TimeoutExpired as error:
                if baseline: raise OperationalError("Baseline validation timed out") from error
                raise VerificationError("Candidate validation timed out", command=command, phase=phase) from error
            if result.returncode:
                message = (result.stdout + result.stderr)[-12000:] or f"Validation exited {result.returncode}"
                if baseline:
                    raise OperationalError("Baseline or host validation failed: " + message)
                raise VerificationError(message, command=command, phase=phase)

    def baseline_render(self, shader_id=None, time=None):
        sid = shader_id if shader_id in self.baseline_ids() else json.loads((self.root / "index.json").read_text())["defaultShaderID"]
        directory = self.directory / "baseline" / self.checkpoint["base"] / sid
        directory.mkdir(parents=True, exist_ok=True)
        source = directory / "source.metal"
        source.write_bytes(self.source(sid).encode("utf-8"))
        for sample in SAMPLE_TIMES if time is None else (time,):
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

    def probe_candidate_failure(self, repair):
        if repair["phase"] in TECHNICAL_PHASES:
            command = [self.config["shaderTool"], "library", "validate", str(self.root),
                       TECHNICAL_PHASES[repair["phase"]], "--python", self.config["python"]]
            self.technical(baseline=True, commands=[command])
        elif repair["phase"] == "render":
            self.baseline_render(repair["shaderID"], repair["sampleTime"])
        else:
            raise CleanupError("Invalid pending verification check")

    def remember_verification_failure(self, error, outcome, phase):
        failure = error if isinstance(error, VerificationError) else None
        pending = bool(failure and (failure.command or failure.phase == "render"))
        repair = {
            "attemptID": self.checkpoint["attemptID"],
            "base": self.checkpoint["base"],
            "phase": failure.phase if failure else phase,
            "diagnostic": str(error)[-12000:],
            "shaderID": (failure.shader_id if failure and failure.shader_id
                         else outcome.get("shaderID") if isinstance(outcome, dict) else None),
            "sampleTime": failure.time if failure else None,
            "restoreConflict": False,
            "pending": pending,
        }
        try:
            self.save(verificationRepair=repair, verifiedCandidate=None, durable=True)
        except OSError as error:
            raise CleanupError(f"Cannot save the verification diagnostic. Live checkout edits were preserved: {error}") from error
        invalid = self.save_patch()
        if pending or invalid:
            # Keep the exact candidate parked until classification can finish.
            self.park_checkpoint()
            self.mark_checkout(parked=True)
            if pending:
                self.probe_candidate_failure(repair)
                self.save(verificationRepair={**repair, "pending": False}, durable=True)
            self.restore_owned_patch()

    def visual_sources(self, shader_id, outcome, before_ids):
        after = self.source(shader_id)
        before = self.source(shader_id, self.checkpoint["base"]) if shader_id in before_ids else None
        if before == after and shader_id != outcome["shaderID"]:
            return None
        if before is None and shader_id == self.request["context"]["shaderID"]:
            before = self.request["context"]["source"]
        return {"before": before, "after": after}

    def render_sample(self, evidence_root, evidence, shader_id, variant, source, time):
        path = evidence_root / shader_id / variant
        png = path / f"{time}.png"
        key = (shader_id, variant, time)
        source_hash = digest(source)
        previous = evidence.get(key)
        if previous:
            if (previous["sourceHash"] != source_hash or not png.is_file()
                    or previous["imageHash"] != digest(png.read_bytes())):
                raise CandidateError("Render evidence changed during verification: " + shader_id)
            return png
        path.mkdir(parents=True, exist_ok=True)
        metal = path / "source.metal"
        metal.write_text(source)
        png.unlink(missing_ok=True)
        try:
            result = run([self.config["shaderTool"], "render", metal, png, "--width", "1280", "--height", "720",
                          "--time", str(time)], self.root, self.env, timeout=60, check=False)
        except subprocess.TimeoutExpired as error:
            if variant == "before":
                raise OperationalError("Baseline render timed out: " + shader_id) from error
            raise VerificationError("Candidate render timed out: " + shader_id, shader_id=shader_id,
                                    time=time, phase="render") from error
        if result.returncode or not self.valid_image(png):
            if variant == "before":
                raise OperationalError("Baseline sample or host rendering failed: " + shader_id)
            message = "Missing, failed or incorrectly sized render evidence: " + shader_id
            detail = (result.stdout + result.stderr)[-12000:].strip()
            if detail:
                message += "\n" + detail
            raise VerificationError(message, shader_id=shader_id, time=time, phase="render")
        evidence[key] = {"shaderID": shader_id, "variant": variant, "time": time,
                         "sourceHash": source_hash, "imageHash": digest(png.read_bytes()), "path": str(png)}
        return png

    def review_shader(self, shader_id, sources, outcome, evidence_root, evidence, tool_hash):
        images = [self.render_sample(evidence_root, evidence, shader_id, variant, source, time)
                  for variant, source in sources.items() if source is not None for time in SAMPLE_TIMES]
        hashes = {variant: digest(source) for variant, source in sources.items() if source is not None}
        captured = self.directory / "captured.png"
        diff = self.git("diff", self.checkpoint["base"])
        stamp = digest(json.dumps({"requestID": self.request["id"], "prompt": self.request["prompt"], "outcome": outcome,
                                    "capturedImage": digest(captured.read_bytes()), "captureTime": self.request["context"].get("animationTime"),
                                    "diffHash": digest(self.git("diff", self.checkpoint["base"], raw=True)),
                                    "sources": hashes, "images": [digest(p.read_bytes()) for p in images],
                                    "size": [1280, 720], "times": SAMPLE_TIMES, "tool": tool_hash}, sort_keys=True))
        schema = {"type": "object", "properties": {"passed": {"type": "boolean"}, "reason": {"type": "string"},
                  "evidenceDigest": {"type": "string", "enum": [stamp]}},
                  "required": ["passed", "reason", "evidenceDigest"], "additionalProperties": False}
        prompt = "Independently review the attached ACTUAL timed images (before then after, each at 0,3,10 seconds). Do not modify files. "
        prompt += "Check rendering, visual coherence and requested intent. For performance requests preserve composition, colors, motion and detail. "
        prompt += "For other affected shaders reject unintended visual regressions. Approximations are allowed only for unsupported runtime capabilities and must be disclosed. "
        prompt += "You may inspect source/diff; no physical TV or frame-rate success is claimed. "
        prompt += json.dumps({"shaderID": shader_id, "primary": shader_id == outcome["shaderID"], "request": self.request["prompt"],
                              "purpose": self.request["purpose"], "outcome": outcome, "capturedContext": {k: v for k, v in self.request["context"].items() if k != "screenshot"},
                              "sourceHashes": hashes, "evidenceDigest": stamp, "diff": diff})
        images.append(captured)
        verdict = self.codex(prompt, schema, "review-" + shader_id, images)
        write(evidence_root / shader_id / "verdict.json", verdict)
        if (not isinstance(verdict, dict) or verdict.get("evidenceDigest") != stamp
                or type(verdict.get("passed")) is not bool or not isinstance(verdict.get("reason"), str)):
            raise OperationalError("Independent visual reviewer returned an invalid verdict for " + shader_id)
        if not verdict["passed"]:
            raise VerificationError("Independent visual review: " + verdict["reason"], shader_id=shader_id, phase="review")

    def verify_candidate(self, outcome, repair):
        self.require_checker()
        phase = repair.get("phase")
        target = repair.get("shaderID")
        shader_ids = sorted(path.parent.name for path in (self.root / "shaders").glob("*/metadata.json"))
        before_ids = set(self.baseline_ids())
        retry_render = phase == "render" and repair.get("sampleTime") in SAMPLE_TIMES
        focused_sources = None
        if target in shader_ids and (retry_render or phase == "review"):
            focused_sources = self.visual_sources(target, outcome, before_ids)
        tool = Path(self.config["shaderTool"])
        tool_hash = digest(tool.read_bytes())
        if not focused_sources:
            self.technical(first_phase=phase)
        attempt = self.checkpoint.get("verificationAttempt", 0) + 1
        self.save(verificationAttempt=attempt)
        evidence_root = self.directory / "evidence" / f"attempt-{attempt}"
        evidence = {}
        reviewed = None
        if focused_sources:
            self.stage("reviewing", f"Rechecking {target} after repair")
            if retry_render:
                self.render_sample(evidence_root, evidence, target, "after", focused_sources["after"], repair["sampleTime"])
            self.technical()
            if not retry_render:
                self.stage("reviewing", f"Rechecking the visual review for {target}")
                self.review_shader(target, focused_sources, outcome, evidence_root, evidence, tool_hash)
                reviewed = target
        self.stage("reviewing", "Rendering samples and running independent visual review")
        for shader_id in shader_ids:
            if shader_id == reviewed:
                continue
            sources = self.visual_sources(shader_id, outcome, before_ids)
            if sources:
                self.review_shader(shader_id, sources, outcome, evidence_root, evidence, tool_hash)
        if digest(tool.read_bytes()) != tool_hash:
            raise OperationalError("The shader tool changed during candidate verification")
        ordered = sorted(evidence, key=lambda key: (key[0], key[1] != "before", key[2]))
        write(evidence_root / "manifest.json", [evidence[key] for key in ordered])

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
            frozen = self.fingerprint()
            self.prepare_publication(required=[])
            if frozen != self.fingerprint():
                raise OperationalError("Checkout changed while rebuilding the publication")
            emit("publicationReady")

    def recover_pending_commit(self):
        if not self.checkpoint.get("publicationCommitPending") or self.checkpoint.get("commitSHA"):
            return
        head = self.git("rev-parse", "HEAD").strip()
        base = self.checkpoint["base"]
        if (head != base and self.owned_record() is not None
                and self.git("rev-list", "--parents", "-n", "1", head).split() == [head, base]
                and f"Holodeck-Request-ID: {self.request['id']}" in self.git("log", "-1", "--format=%B", head).splitlines()):
            self.verify_commit(head, self.checkpoint["commitManifest"], check_workspace=False)
            self.save(commitSHA=head, publicationCommitPending=False, durable=True)

    def perform(self):
        self.request = json.loads((self.directory / "request.json").read_text())
        screenshot = self.directory / "captured.png"
        screenshot.write_bytes(base64.b64decode(self.request["context"]["screenshot"]))
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.recoverable_owner()
            repair_attempt = self.active_repair_attempt()
            result = self.previous_publication()
            if result is not None and (repair_attempt is None or result.get("attemptID") == repair_attempt):
                self.git("fetch", "origin", "main")
                if self.git("status", "--porcelain").strip():
                    raise OperationalError("Uncommitted work prevents publication recovery")
                if self.git("merge-base", "--is-ancestor", result["commitSHA"], "origin/main", check=False).returncode:
                    raise OperationalError("The previously pushed commit is no longer on main")
                self.git("checkout", "-B", "main", "origin/main")
                self.check_checkout_inputs()
                self.verify_commit("origin/main", self.candidate_manifest())
                self.prepare_publication()
                self.emit_saved_publication(result)
                return
            # Crash/lost-ack recovery: adopt an already-pushed request commit before reapplying any patch.
            self.begin_attempt(repair_attempt)
            self.recover_pending_commit()
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
                if self.owned_record() is not None and self.git("rev-parse", "HEAD").strip() == sha:
                    self.park_checkpoint()
            self.synchronize()
            published_id = (self.previous_publication() or {}).get("shaderID")
            schema = {"type": "object", "properties": {"status": {"type": "string", "enum": ["completed", "needsClarification"]},
                      "outputKind": {"type": "string", "enum": ["new", "edited"]}, "shaderID": {"type": "string"},
                      "changed": {"type": "boolean"}, "summary": {"type": "string"},
                      "approximations": {"type": "array", "items": {"type": "string"}}, "question": {"type": "string"},
                      "options": {"type": "array", "items": {"type": "string"}}}, "additionalProperties": False}
            schema["required"] = list(schema["properties"])
            feedback = ""
            while True:
                repair = self.checkpoint.get("verificationRepair")
                if repair and repair["attemptID"] != self.checkpoint["attemptID"]:
                    repair = None
                verified = self.checkpoint.get("verifiedCandidate") or {}
                conflicts = self.restore_conflicts(published_id)
                unclassified_on_new_base = repair and repair.get("pending")
                reverify = not conflicts and not self.checkpoint.get("scopeRecovery") and (
                    verified.get("attemptID") == self.checkpoint["attemptID"] or unclassified_on_new_base)
                if reverify:
                    outcome = self.checkpoint["outcome"]
                    feedback = ""
                else:
                    if conflicts or repair or self.checkpoint.get("scopeRecovery"):
                        self.stage("repairing", "Codex is reconciling the candidate" if conflicts else "Codex is repairing the candidate")
                    else:
                        self.stage("implementing", "Codex is working on the request")
                    reply_schema = schema
                    if conflicts:
                        reply_schema = {**schema, "properties": {**schema["properties"],
                            "resolvedRestoreConflicts": {"type": "array", "items": {"type": "string"}}},
                            "required": schema["required"] + ["resolvedRestoreConflicts"]}
                    active_repair = repair if repair and not repair.get("pending") else None
                    outcome = self.codex(self.prompt(feedback, active_repair, conflicts), reply_schema,
                                         "implementation", [screenshot], resume=True)
                    if outcome.get("status") == "completed":
                        self.save(outcome=outcome, verifiedCandidate=None)
                    else:
                        self.save(verifiedCandidate=None)
                    feedback = ""
                phase = "scope"
                try:
                    if outcome["status"] == "needsClarification":
                        self.scope(allowed_unmerged=conflicts)
                        self.park()
                        emit("clarification", question=outcome["question"], options=outcome["options"])
                        return
                    if conflicts:
                        self.accept_restore_resolution(outcome, conflicts)
                    self.scope(outcome)
                    if conflicts:
                        self.save_patch()
                        (self.directory / "restore-conflicts.json").unlink()
                    if self.checkpoint.get("scopeRecovery"):
                        self.save(scopeRecovery=None)
                    self.normalize_preview_colors(outcome)
                    manifest = self.candidate_manifest()
                    frozen = self.fingerprint(manifest)
                    if (reverify and verified.get("base") == self.checkpoint["base"]
                            and verified.get("fingerprintVersion") == FINGERPRINT_VERSION and verified.get("fingerprint") != frozen):
                        raise CandidateError("Saved candidate changed since verification")
                    phase = "verification"
                    focused = not reverify and not conflicts and repair and repair["base"] == self.checkpoint["base"] and not repair["restoreConflict"]
                    self.verify_candidate(outcome, repair if focused else {})
                    phase = "consistency"
                    if self.fingerprint() != frozen:
                        raise CandidateError("Candidate changed while verification was running")
                    self.save_patch()
                    self.save(verificationRepair=None, verifiedCandidate={
                        "attemptID": self.checkpoint["attemptID"], "base": self.checkpoint["base"],
                        "fingerprintVersion": FINGERPRINT_VERSION, "fingerprint": frozen,
                    }, durable=True)
                    # No writable agent runs after this point; all review inputs remain immutable.
                    self.git("fetch", "origin", "main")
                    if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                        self.synchronize()
                        feedback = "Remote main changed; reapply the intent, resolve conflicts, and repeat verification."
                        continue
                    self.prepare_publication(self.required_previews(outcome))
                    if self.candidate_manifest() != manifest:
                        emit("discardPublication")
                        raise CandidateError("Candidate changed while preparing publication")
                    self.stage("pushing", "Committing verified changes and pushing to main")
                    write(self.directory / "candidate-manifest.json", manifest)
                    write(self.directory / "evidence" / f"attempt-{self.checkpoint['verificationAttempt']}" / "candidate-manifest.json", manifest)
                    if outcome["changed"]:
                        self.save(publicationCommitPending=True, commitManifest=manifest, durable=True)
                        self.stage_candidate(manifest)
                        message = f"{outcome['summary'][:180]}\n\nHolodeck-Request-ID: {self.request['id']}"
                        self.git("commit", "-m", message)
                        sha = self.git("rev-parse", "HEAD").strip()
                        self.verify_commit(sha, manifest)
                        self.save(commitSHA=sha, publicationCommitPending=False, durable=True)
                        result = self.git("push", "origin", "HEAD:main", check=False)
                        self.git("fetch", "origin", "main")
                        published = self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
                        if not published:
                            if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                                emit("discardPublication")
                                self.park_checkpoint()
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
                    self.remember_verification_failure(error, outcome, phase)
                    emit("log", text="Repairing shader defect: " + str(error)[-12000:])
                    self.git("fetch", "origin", "main")
                    if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                        self.synchronize()

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
    except BaseException as error:
        if not isinstance(error, Exception):
            cleanup_errors = list(getattr(error, 'cleanup_errors', []))
            recovery_required = getattr(error, 'recovery_required', False)
            try: budget = status_budget(read_supervision(sys.argv[3]))
            except (OperationalError, OSError): budget = None  # Settlement independently reports unreadable evidence.
            try: terminate_registered(sys.argv[3], budget=budget)
            except (OperationalError, OSError) as cleanup_error:
                cleanup_errors.append(str(cleanup_error))
                recovery_required |= isinstance(cleanup_error, ProcessRecoveryError) or any(
                    (Path(sys.argv[3]) / name).exists() for name in ("children.json", "supervision.json"))
            if cleanup_errors or recovery_required:
                message = 'Worker interrupted' + (': ' + str(error) if str(error) else '')
                if cleanup_errors: message += '; cleanup failed: ' + '; cleanup error: '.join(dict.fromkeys(cleanup_errors))
                emit("failure", message=message, failureKind="interrupted", recoveryRequired=recovery_required)
                sys.exit(1)
            sys.exit(130)
        cleanup_failure = isinstance(error, CleanupError)
        message = str(error)
        if worker and worker.request and not isinstance(error, (SupervisionError, CleanupError)):
            try:
                with (worker.gitdir / "holodeck-requests.lock").open("w") as lease:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    # Reconcile a lost push acknowledgement before resetting the checkout.
                    published = False
                    sha = worker.checkpoint.get("commitSHA")
                    if sha:
                        with contextlib.suppress(Exception):
                            worker.git("fetch", "origin", "main")
                            published = worker.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
                    if published:
                        worker.clean(revision=sha)
                    elif worker.clean() and not (worker.directory / "restore-evidence").exists():
                        worker.clear_candidate_checkpoint()
                        worker.save(verificationRepair=None, verifiedCandidate=None, scopeRecovery=None)
            except Exception as cleanup_error:
                try:
                    cleanup_failure = worker.owned_record() is not None
                except CleanupError:
                    cleanup_failure = True
                if cleanup_failure:
                    message += "; checkout cleanup remains pending: " + str(cleanup_error)
                emit("log", text="Cleanup remains pending: " + str(cleanup_error))
        failure_kind = "supervision" if isinstance(error, SupervisionError) else "operational"
        if cleanup_failure:
            failure_kind = "checkoutCleanup"
        emit("failure", message=message, failureKind=failure_kind,
             retryable=isinstance(error, SupervisionError) and error.retryable,
             recoveryRequired=cleanup_failure or isinstance(error, ProcessRecoveryError))
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "_supervise": sys.exit(supervise(int(sys.argv[2])))
    main()
