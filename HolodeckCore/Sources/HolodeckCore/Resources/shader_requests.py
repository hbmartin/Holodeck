#!/usr/bin/env python3
"""Single-checkout Codex worker. JSONL bridge; no shell interpolation or model-owned Git writes."""
import ast
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import struct
import re


class OperationalError(RuntimeError):
    pass


class CandidateError(RuntimeError):
    pass


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
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, input=input,
                            capture_output=True, text=True, timeout=timeout)
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
        self.env = dict(os.environ, GIT_TERMINAL_PROMPT="0", HOLODECK_SHADER_TOOL=config["shaderTool"], PYTHONDONTWRITEBYTECODE="1")
        self.env["PATH"] = os.pathsep.join([str(Path(config["codex"]).parent), str(Path(config["python"]).parent),
                                             "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        self.request = {}
        self.checkpoint_path = self.directory / "checkpoint.json"
        self.checkpoint = json.loads(self.checkpoint_path.read_text()) if self.checkpoint_path.exists() else {}
        self.gitdir = Path(self.git("rev-parse", "--absolute-git-dir").strip())
        self.owner = self.gitdir / "holodeck-request-owner.json"

    def git(self, *args, check=True, raw=False):
        result = subprocess.run([self.git_executable, *args], cwd=self.root, env=self.env,
                                capture_output=True, text=not raw, timeout=60)
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

    def clean(self):
        # Only files produced while this request holds the exclusive checkout lease.
        if self.owner.exists() and json.loads(self.owner.read_text()).get("id") == self.request.get("id"):
            others = self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0")
            self.git("reset", "--hard", self.checkpoint.get("base", "HEAD"))
            for name in filter(None, others):
                path = self.root / name
                if path.is_symlink() or path.is_file():
                    path.unlink()
            self.owner.unlink(missing_ok=True)

    def park(self):
        self.save_patch()
        self.clean()

    def save_patch(self):
        base = self.checkpoint["base"]
        patch = subprocess.run([self.git_executable, "diff", "--binary", base], cwd=self.root,
                               capture_output=True, check=True).stdout
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
            result = run([self.git_executable, "apply", "--3way", patch], self.root, self.env, check=False)
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
        if self.owner.exists():
            owner = json.loads(self.owner.read_text())
            if owner.get("id") != self.request["id"]:
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
        self.save(base=remote)
        write(self.owner, {"id": self.request["id"], "directory": str(self.directory)})
        self.restore_patch()

    def discard(self):
        # Discarding owned work needs the durable request identity, even if its payload was corrupted.
        self.request = {"id": self.directory.name}
        with (self.gitdir / "holodeck-requests.lock").open("w") as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sha = self.checkpoint.get("commitSHA")
            published = False
            if sha:
                self.git("fetch", "origin", "main")
                published = self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
            if published:
                self.owner.unlink(missing_ok=True)
            else:
                self.clean()
            for name in ("changes.patch", "untracked.json"):
                (self.directory / name).unlink(missing_ok=True)
        emit("discarded")

    def fingerprint(self):
        value = self.git("diff", "--binary", self.checkpoint["base"], raw=True)
        for name in sorted(filter(None, self.git("ls-files", "--others", "--exclude-standard", "-z").split("\0"))):
            path = self.root / name
            value += name.encode("utf-8") + digest(path.read_bytes()).encode("ascii")
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
        primary = set()
        for name in paths:
            parts = name.split("/")
            if len(parts) == 3 and parts[0] == "shaders" and parts[2] in ("body.metal", "metadata.json"):
                primary.add(parts[1])
            elif name not in ("index.json", "shared/common.metal", "shared/material.metal", "shared/fragment.metal", "tools/test_licenses.py"):
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
        if "tools/test_licenses.py" in paths:
            before_bytes = self.git("show", f"{base}:tools/test_licenses.py", raw=True)
            after_bytes = (self.root / "tools/test_licenses.py").read_bytes()
            before = ast.parse(before_bytes)
            after = ast.parse(after_bytes)
            def inventory(tree, source):
                values = {}
                keep = []
                ranges = []
                lines = source.splitlines(keepends=True)
                for node in tree.body:
                    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ("SOURCE_REQUIREMENTS", "UPSTREAM_REQUIREMENTS"):
                        values[node.targets[0].id] = ast.literal_eval(node.value)
                        ranges.append((sum(map(len, lines[:node.lineno - 1])) + node.col_offset,
                                       sum(map(len, lines[:node.end_lineno - 1])) + node.end_col_offset))
                    else:
                        keep.append(node)
                for start, end in reversed(ranges):
                    source = source[:start] + b"<notice-inventory>" + source[end:]
                return ast.dump(ast.Module(body=keep, type_ignores=[]), include_attributes=False), values, source
            old_logic, old_records, old_outside = inventory(before, before_bytes)
            new_logic, new_records, new_outside = inventory(after, after_bytes)
            if old_logic != new_logic or old_outside != new_outside:
                raise CandidateError("License validation logic cannot change")
            for path, notices in old_records["SOURCE_REQUIREMENTS"].items():
                if not set(notices) <= set(new_records["SOURCE_REQUIREMENTS"].get(path, [])):
                    raise CandidateError("Existing attribution obligations cannot be weakened")
            allowed_sources = set(old_records["SOURCE_REQUIREMENTS"]) | {f"shaders/{sid}/body.metal" for sid in primary}
            if not set(new_records["SOURCE_REQUIREMENTS"]) <= allowed_sources:
                raise CandidateError("Unrelated notice records cannot be introduced")
            for key, value in old_records["UPSTREAM_REQUIREMENTS"].items():
                if new_records["UPSTREAM_REQUIREMENTS"].get(key) != value:
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
            process = subprocess.Popen(args, cwd=self.root, env=self.env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=stderr, text=True)
            process.stdin.write(prompt)
            process.stdin.close()
            for line in process.stdout:
                try:
                    event = json.loads(line)
                    if label == "implementation" and event.get("type") == "thread.started":
                        self.save(threadID=event["thread_id"])
                    emit("codex", data=event)
                except ValueError:
                    emit("log", text=line[:32000])
            code = process.wait()
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
        return """Implement one Holodeck shader request. Read AGENTS.md and the authoring/library docs, search techniques, and preserve attribution.
The user is viewing the captured source below; the checkout is latest origin/main and may differ. Preserve intervening edits.
Choose any ONE existing shader ID to EDIT, retaining its ID, or create ONE unused ID. If the context was deleted, recreate under a fresh ID.
Ask a concise clarification only if intent is ambiguous. Unsupported audio/textures/multipass/app capabilities must be approximated using this runtime and disclosed.
New output: append to index.shaders and relevant EXISTING collections; preserve the default and existing ordering. Generate a name, metadata and discovery tags/moods/motion. If editing an unlisted existing shader, append its ID too so the TV can download it.
Allowed changes: one primary shader body/metadata, index membership, canonical shared helpers, and DATA ONLY in SOURCE_REQUIREMENTS/UPSTREAM_REQUIREMENTS of tools/test_licenses.py.
No tooling, test logic, other shader bodies, originals, previews, or app changes. Do NOT commit, push, change branches, or alter Git configuration.
For PERFORMANCE purpose: optimize the context ID (unless deleted), preserve composition/colors/motion/detail for all affected shaders; report no changes if latest already addresses the old evidence. Timings refer to the observed old source, not necessarily latest.
For activation repair: repair the failed OUTPUT ID from the diagnostic, preserving the creative intent. Recreate it if deleted. Classification belongs to the logical request: retain "new" for an output this request already created and published. The changed flag describes only this candidate diff; the host records earlier changes too.
GPU access can be unavailable inside the implementation sandbox. Do not render or run GPU/Xcode tests yourself; the unsandboxed host performs all technical/GPU/image checks independently.
Make one candidate and return the schema. A host independently verifies and reviews it. No attempt/time budget.
An unchanged existing shader may be successful if it already satisfies the prompt. Do not fabricate an empty change.
""" + json.dumps({"request": {k: v for k, v in self.request.items() if k != "context"},
                          "capturedContext": context, "answer": answer, "activationRepair": repair,
                          "previousOutput": self.checkpoint.get("outcome"), "previousPublication": self.previous_publication(), "verificationFeedback": feedback}, indent=2)

    def technical(self):
        self.stage("validating", "Compiling macOS and tvOS shaders and running authoring/GPU tests")
        env = dict(self.env, HOLODECK_GPU_TESTS="1")
        commands = [[self.config["python"], "tools/library.py", "validate", "--compile"],
                    [self.config["python"], "-m", "unittest", "discover", "-s", "tools", "-p", "test_*.py"]]
        for command in commands:
            result = run(command, self.root, env, check=False)
            if result.returncode:
                raise CandidateError((result.stdout + result.stderr)[-12000:])

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
                    result = run([self.config["shaderTool"], "render", metal, png, "--width", "1280", "--height", "720", "--time", str(time)], self.root, self.env, timeout=60, check=False)
                    if result.returncode or not png.exists() or png.stat().st_size == 0:
                        raise CandidateError("Sample rendering failed: " + sid)
                    header = png.read_bytes()[:24]
                    if header[:8] != b"\x89PNG\r\n\x1a\n" or len(header) != 24 or struct.unpack(">II", header[16:24]) != (1280, 720):
                        raise CandidateError("Missing or incorrectly sized render evidence: " + sid)
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

    def prepare_publication(self):
        emit("preparePublication")
        response = sys.stdin.readline()
        if not response or json.loads(response).get("ok") is not True:
            raise OperationalError("Mac could not prepare a complete publication")

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
                self.prepare_publication()
                emit("result", result=result)
                return
            # Crash/lost-ack recovery: adopt an already-pushed request commit before reapplying any patch.
            if self.checkpoint.get("commitSHA") and not (self.directory / "repair.json").exists():
                self.git("fetch", "origin", "main")
                sha = self.checkpoint["commitSHA"]
                if self.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0:
                    outcome = self.checkpoint["outcome"]
                    response = {k: outcome[k] for k in ("outputKind", "shaderID", "changed", "summary", "approximations")}
                    response.update(commitSHA=sha, deliveredSourceHash=None)
                    write(ready, response)
                    self.owner.unlink(missing_ok=True)
                    for name in ("changes.patch", "untracked.json"):
                        (self.directory / name).unlink(missing_ok=True)
                    if self.git("status", "--porcelain").strip():
                        raise OperationalError("Uncommitted files prevent recovery of the pushed result")
                    self.git("checkout", "-B", "main", "origin/main")
                    self.prepare_publication()
                    emit("result", result=response)
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
                    self.prepare_publication()
                    if self.fingerprint() != frozen:
                        emit("discardPublication")
                        raise CandidateError("Candidate changed while preparing publication")
                    self.stage("pushing", "Committing verified changes and pushing to main")
                    if outcome["changed"]:
                        self.save_patch()
                        self.git("add", "--all")
                        message = f"{outcome['summary'][:180]}\n\nHolodeck-Request-ID: {self.request['id']}"
                        self.git("commit", "-m", message)
                        sha = self.git("rev-parse", "HEAD").strip()
                        self.save(commitSHA=sha)
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
                    response = {k: outcome[k] for k in ("outputKind", "shaderID", "changed", "summary", "approximations")}
                    previous = self.previous_publication()
                    if previous:
                        response["changed"] = outcome["changed"] or previous["changed"]
                        if not outcome["changed"] and previous["shaderID"] == outcome["shaderID"]:
                            sha = previous["commitSHA"]
                            response["summary"] = previous["summary"] + " Verified again after activation repair; no further source changes were necessary."
                            response["approximations"] = list(dict.fromkeys(previous["approximations"] + outcome["approximations"]))
                    response["commitSHA"] = sha
                    response["deliveredSourceHash"] = None
                    write(ready, response)
                    self.owner.unlink(missing_ok=True)
                    for name in ("changes.patch", "untracked.json", "repair.json"):
                        (self.directory / name).unlink(missing_ok=True)
                    emit("result", result=response)
                    return
                except (CandidateError, ValueError, SyntaxError, KeyError, TypeError, IndexError) as error:
                    feedback = str(error)
                    emit("log", text="Repairing shader defect: " + feedback)
                    self.stage("repairing", "Repairing verification findings")
                    self.git("fetch", "origin", "main")
                    if self.git("rev-parse", "origin/main").strip() != self.checkpoint["base"]:
                        self.synchronize()
                        feedback += " Latest main advanced; the request has been reapplied to it."
                    self.save_patch()

    def preflight(self):
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
        run([self.config["python"], "--version"], self.root, self.env)
        run([self.config["shaderTool"], "--version"], self.root, self.env)
        for sdk in ("appletvos", "macosx"):
            run(["/usr/bin/xcrun", "-sdk", sdk, "--find", "metal"], self.root, self.env)
        if not self.config.get("model", "").strip():
            raise OperationalError("Choose a Holodeck model")
        self.git("checkout", "-B", "main", "origin/main")
        self.git("push", "--dry-run", "origin", "HEAD:main")
        if not (self.root / "tools/shader_tool.py").is_file():
            raise OperationalError("Complete the native shader-tool and preview migration on origin/main before enabling requests.")
        sid = json.loads((self.root / "index.json").read_text())["defaultShaderID"]
        source = self.directory / "setup.metal"
        source.write_text(self.source(sid))
        for sdk in ("macosx", "appletvos"):
            run(["/usr/bin/xcrun", "-sdk", sdk, "metal", "-c", source, "-o", self.directory / f"setup-{sdk}.air"], self.root, self.env)
        image = self.directory / "setup.png"
        run([self.config["shaderTool"], "render", source, image], self.root, self.env)
        schema = {"type": "object", "properties": {"imageDescription": {"type": "string"}}, "required": ["imageDescription"], "additionalProperties": False}
        self.codex("Describe the attached shader image in one sentence and return the required JSON. Do not change files.", schema, "setup", [image])
        emit("preflight", message="Ready for shader requests")


def main():
    # All descendants share this request's group, so the native host can reconcile an orphan safely.
    with contextlib.suppress(PermissionError):
        os.setsid()
    config = json.loads(Path(sys.argv[2]).read_text())
    worker = None
    try:
        worker = Worker(config, sys.argv[3])
        if sys.argv[1] == "preflight":
            worker.preflight()
        elif sys.argv[1] == "discard":
            worker.discard()
        else:
            worker.perform()
    except BaseException as error:
        if worker and worker.request:
            # A lost push acknowledgement is reconciled before any destructive cleanup.
            published = False
            sha = worker.checkpoint.get("commitSHA")
            if sha:
                with contextlib.suppress(Exception):
                    worker.git("fetch", "origin", "main")
                    published = worker.git("merge-base", "--is-ancestor", sha, "origin/main", check=False).returncode == 0
            if not published:
                with contextlib.suppress(Exception):
                    worker.clean()
                for name in ("changes.patch", "untracked.json"):
                    (worker.directory / name).unlink(missing_ok=True)
            else:
                worker.owner.unlink(missing_ok=True)
        emit("failure", message=str(error))
        sys.exit(1)


if __name__ == "__main__":
    main()
