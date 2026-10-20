#!/usr/bin/env python3
"""Bounded process evidence, retained command supervision and nonblocking I/O."""
import contextlib
import ctypes
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid


class OperationalError(RuntimeError):
    pass


class ProcessRecoveryError(OperationalError):
    pass


CLOCK_DOMAIN = 'darwin-uptime-raw' if sys.platform == 'darwin' else 'linux-monotonic'
_libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True) if sys.platform == 'darwin' else None
REGISTRY_LIMIT = 65536
PROCESS_SAMPLE_SECONDS = .25
TERMINAL_STATES = ('settled', 'failed', 'cancelled')


def process_clock():
    # Shared across processes, and (like native systemUptime) excludes system sleep.
    clock = time.CLOCK_UPTIME_RAW if sys.platform == 'darwin' else time.CLOCK_MONOTONIC
    return time.clock_gettime(clock)


class ProcessObservationError(ProcessRecoveryError):
    pass


class ProcessDrainError(ProcessRecoveryError):
    pass


def process_identity(pid):
    """Birth identity shared with the native host; a PID alone is never ownership proof."""
    if sys.platform == 'darwin':
        data = ctypes.create_string_buffer(136)
        if _libproc.proc_pidinfo(pid, 3, 0, data, len(data)) != len(data): return None
        if struct.unpack_from('=I', data, 4)[0] == 5: return None
        seconds, microseconds = struct.unpack_from('=QQ', data, 120)
        return {'pid': pid, 'seconds': seconds, 'microseconds': microseconds}
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        if fields[0] == 'Z': return None
        return {'pid': pid, 'seconds': int(fields[19]), 'microseconds': 0}
    except (OSError, ValueError, IndexError): return None


def group_members(pid):
    if _libproc is not None:
        size = 4096
        while size <= 1048576:
            data = ctypes.create_string_buffer(size)
            ctypes.set_errno(0)
            count = _libproc.proc_listpids(2, pid, data, size)
            if count < 0 or (count == 0 and ctypes.get_errno()):
                raise ProcessObservationError('Cannot enumerate owned process group: ' + os.strerror(ctypes.get_errno()))
            if count < size:
                if count % 4: raise ProcessObservationError('Malformed owned process group enumeration')
                pids = struct.unpack_from('=' + 'i' * (count // 4), data)
                break
            size *= 2
        else: raise ProcessObservationError('Owned process group enumeration exceeds its capacity')
    else:
        try:
            listing = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid='], capture_output=True, text=True, timeout=2, check=True)
            pids = [int(parts[0]) for line in listing.stdout.splitlines()
                    if len(parts := line.split()) == 2 and int(parts[1]) == pid]
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise ProcessObservationError('Cannot observe owned process group: ' + str(error)) from error
    return [identity for member in pids if member > 1 and (identity := process_identity(member)) is not None]


def merge_members(known, observed):
    return list({(i['pid'], i['seconds'], i['microseconds']): i for i in known + observed
                 if process_identity(i['pid']) == i}.values())


def read_process_bytes(file, missing=None):
    try:
        fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode): raise ValueError('Expected a regular process record')
            data = source.read(REGISTRY_LIMIT + 1)
            if len(data) > REGISTRY_LIMIT: raise ValueError('Process record exceeds 64 KiB')
            return data
    except FileNotFoundError: return missing
    except (OSError, ValueError) as error:
        raise ProcessRecoveryError('Process evidence is unreadable; retain the journal: ' + str(error)) from error


def read_process_json(file, missing=None):
    data = read_process_bytes(file)
    if data is None: return missing
    try: return json.loads(data)
    except (ValueError, TypeError) as error: raise ProcessRecoveryError('Invalid process evidence: ' + str(error)) from error


_batch_directory = None


@contextlib.contextmanager
def process_write_batch(directory):
    """Fsync each new file, then commit compatible renames with one directory sync."""
    global _batch_directory
    directory = Path(directory); previous = _batch_directory
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    _batch_directory = directory
    try: yield
    finally:
        _batch_directory = previous
        try: os.fsync(fd)
        finally: os.close(fd)


def save_process_json(file, value):
    file = Path(file)
    data = json.dumps(value, separators=(',', ':')).encode()
    if len(data) > REGISTRY_LIMIT:
        raise ProcessRecoveryError('Live process registry exceeds 64 KiB; existing ownership evidence was retained')
    if read_process_bytes(file) == data: return
    parent = os.open(file.parent, os.O_RDONLY | os.O_DIRECTORY)
    temporary = '.' + file.name + '.' + str(uuid.uuid4()) + '.tmp'
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as output:
            output.write(data); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, file.name, src_dir_fd=parent, dst_dir_fd=parent)
        if _batch_directory != file.parent: os.fsync(parent)
    finally:
        with contextlib.suppress(FileNotFoundError): os.unlink(temporary, dir_fd=parent)
        os.close(parent)


def save_registry(file, entries): save_process_json(file, entries)


def retire_evidence(directory):
    for name in ('children.json', 'supervision.json'): (Path(directory) / name).unlink(missing_ok=True)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def valid_identity(identity):
    return isinstance(identity, dict) and all(type(identity.get(key)) is int for key in ('pid', 'seconds', 'microseconds')) and identity['pid'] > 1


def read_registry(directory):
    entries = read_process_json(Path(directory) / 'children.json', [])
    if not isinstance(entries, list) or any(not isinstance(e, dict) or not valid_identity(e.get('leader'))
            or not isinstance(e.get('members'), list) or not all(valid_identity(i) for i in e['members']) for e in entries):
        raise ProcessRecoveryError('Invalid process identities; retain the journal')
    return entries


def read_supervision(directory):
    value = read_process_json(Path(directory) / 'supervision.json')
    if value is None: return None
    if (not isinstance(value, dict) or type(value.get('formatVersion')) is not int or value['formatVersion'] not in (1, 2)
            or not valid_identity(value.get('supervisor')) or value.get('state') not in ('starting', 'running', 'draining', *TERMINAL_STATES)
            or (value.get('command') is not None and not valid_identity(value['command']))):
        raise ProcessRecoveryError('Invalid supervision evidence; retain the journal')
    if value['formatVersion'] == 2:
        try: uuid.UUID(value['sessionID'])
        except (KeyError, ValueError, TypeError, AttributeError) as error: raise ProcessRecoveryError('Invalid supervision session') from error
        if (type(value.get('revision')) is not int or value['revision'] < 0 or value.get('clock') != CLOCK_DOMAIN
                or type(value.get('pipeDrainComplete')) is not bool or type(value.get('processesSettled')) is not bool):
            raise ProcessRecoveryError('Invalid supervision revision, clock or completion evidence')
    return value


def new_status(anchor, session):
    return dict(formatVersion=2, sessionID=session, revision=0, clock=CLOCK_DOMAIN, supervisor=anchor,
                command=None, state='starting', commandReturnCode=None, processesSettled=False, pipeDrainComplete=False)


class Termination:
    def __init__(self, deadline=None):
        self.deadline = deadline; self.term_sent = set(); self.kill_sent = set()

    @property
    def started(self): return self.deadline - 10 if self.deadline is not None else None

    def begin(self):
        if self.deadline is None: self.deadline = process_clock() + 10

    def signal(self, identities, exclude=()):
        self.begin(); errors = []
        for identity in identities:
            if identity in exclude or process_identity(identity['pid']) != identity: continue
            key = (identity['pid'], identity['seconds'], identity['microseconds'])
            signals = [(signal.SIGTERM, self.term_sent)]
            if process_clock() >= self.deadline - 5: signals.append((signal.SIGKILL, self.kill_sent))
            for sig, sent in signals:
                if key in sent: continue
                sent.add(key)
                try:
                    if process_identity(identity['pid']) == identity: os.kill(identity['pid'], sig)
                except ProcessLookupError: pass
                except OSError as error: errors.append(error)
        return errors

    @property
    def expired(self): return self.deadline is not None and process_clock() >= self.deadline


def status_deadline(status):
    # Version 1 used a different Darwin clock. Never compare its absolute deadline.
    if status and status.get('formatVersion') == 2 and status.get('clock') == CLOCK_DOMAIN:
        deadline = status.get('deadline')
        if type(deadline) in (int, float): return deadline
    return None


class Settlement:
    """One observation/termination engine for normal, exceptional and orphan cleanup."""
    def __init__(self, directory, entries, anchor=None, termination=None):
        self.directory = Path(directory); self.entries = entries; self.anchor = anchor
        self.termination = termination or Termination()
        self.next_sample = 0; self.observation_errors = 0; self.uncertain = True
        self.errors = []; self.failure_kind = None

    @property
    def identities(self): return [i for entry in self.entries for i in entry['members']]

    def fail(self, error, kind):
        message = str(error)
        if message not in self.errors: self.errors.append(message)
        self.failure_kind = self.failure_kind or kind
        self.termination.begin()

    @property
    def failure(self): return '; cleanup error: '.join(self.errors) if self.errors else None

    def observe(self):
        quiet = True; self.uncertain = False
        for entry in self.entries:
            leader = entry['leader']; current = process_identity(leader['pid'])
            observed = group_members(leader['pid']) if current in (None, leader) else []
            if current == leader:
                entry['members'] = merge_members(entry['members'] + [leader], observed)
                quiet &= not any(i != self.anchor for i in observed)
            else:
                entry['members'] = merge_members(entry['members'], [])
                self.uncertain |= any(i not in entry['members'] for i in observed)
                quiet &= not observed
            quiet &= not any(i != self.anchor for i in entry['members'])
        return quiet and not self.uncertain

    def step(self, delegate=False):
        # Signals are attempted even when evidence persistence or observation fails.
        if self.termination.started is not None and (not delegate or process_clock() >= self.termination.deadline - 5):
            for error in self.termination.signal(self.identities, exclude=[self.anchor]): self.fail(error, 'signal')
        if process_clock() < self.next_sample: return False
        self.next_sample = process_clock() + PROCESS_SAMPLE_SECONDS
        try:
            quiet = self.observe(); self.observation_errors = 0
        except ProcessObservationError as error:
            self.observation_errors += 1; self.uncertain = True
            if self.observation_errors >= 3: self.fail(error, 'observation')
            return False
        try:
            if not quiet: save_registry(self.directory / 'children.json', self.entries)
        except (OSError, ProcessRecoveryError) as error: self.fail(error, 'registry')
        if self.termination.started is not None and (not delegate or process_clock() >= self.termination.deadline - 5):
            for error in self.termination.signal(self.identities, exclude=[self.anchor]): self.fail(error, 'signal')
        if quiet or not any(i != self.anchor and process_identity(i['pid']) == i for i in self.identities):
            # Never use the snapshot preceding a signal or fsync as completion proof.
            try: return self.observe()
            except ProcessObservationError as error:
                self.uncertain = True; self.observation_errors += 1
                if self.observation_errors >= 3: self.fail(error, 'observation')
        return False

    def expired_error(self):
        message = self.failure or ('Cannot observe owned processes' if self.uncertain else 'Owned descendants did not settle')
        return ProcessRecoveryError(message + '; settlement budget exhausted before verification. Retain the journal and recover or detach the checkout.')


def terminate_registered(directory, deadline=None):
    directory = Path(directory); entries = read_registry(directory); status = read_supervision(directory)
    if not entries and status is None: return
    anchor = status['supervisor'] if status else None
    if (not entries and status and status.get('processesSettled') and status.get('pipeDrainComplete')
            and process_identity(anchor['pid']) != anchor):
        retire_evidence(directory); return
    if anchor and not any(e['leader'] == anchor for e in entries):
        raise ProcessRecoveryError('Supervisor identity does not match its process registry')
    termination = Termination(status_deadline(status) if deadline is None else deadline); termination.begin()
    engine = Settlement(directory, entries, anchor, termination)
    if anchor and process_identity(anchor['pid']) == anchor:
        try: os.kill(anchor['pid'], signal.SIGTERM)
        except ProcessLookupError: pass
        except OSError as error: engine.fail(error, 'signal')
    while True:
        anchor_live = anchor is not None and process_identity(anchor['pid']) == anchor
        quiet = engine.step(delegate=anchor_live)
        if quiet:
            if anchor_live:
                # The fresh group contains only the trusted owner. Retire it last.
                for error in termination.signal([anchor]): engine.fail(error, 'signal')
            else:
                final = read_supervision(directory) or status
                pending = final and final.get('formatVersion') == 2 and not final['pipeDrainComplete']
                if pending or (final and final.get('failureKind') == 'pipeDrain' and final.get('recoveryRequired')):
                    raise ProcessDrainError((final or {}).get('failure') or 'Pipe completion is unverified; retain the journal and recover or detach the checkout')
                retire_evidence(directory)
                if engine.failure: raise OperationalError(engine.failure)
                return
        if termination.expired: raise engine.expired_error()
        time.sleep(min(.025, max(0, termination.deadline - process_clock())))


class SignalWakeup:
    def __init__(self, control):
        self.read, self.write = os.pipe()
        os.set_blocking(self.read, False); os.set_blocking(self.write, False)
        self.previous = signal.set_wakeup_fd(self.write)
        signal.signal(signal.SIGCHLD, lambda *_: None)
        self.selector = selectors.DefaultSelector()
        self.selector.register(control, selectors.EVENT_READ)
        self.selector.register(self.read, selectors.EVENT_READ)

    def forget(self, control):
        with contextlib.suppress(KeyError): self.selector.unregister(control)

    def wait(self, timeout):
        for key, _ in self.selector.select(max(0, timeout)):
            if key.fd == self.read:
                with contextlib.suppress(BlockingIOError):
                    while os.read(self.read, 4096): pass

    def close(self):
        signal.set_wakeup_fd(self.previous)
        self.selector.close(); os.close(self.read); os.close(self.write)


def supervise(control_fd):
    control = socket.socket(fileno=control_fd); control.setblocking(False)
    wakeup = SignalWakeup(control)
    directory = Path(os.environ['HOLODECK_REQUEST_DIRECTORY'])
    anchor = process_identity(os.getpid()); command = None; launched = False; stop = [False]
    status = new_status(anchor, os.environ.get('HOLODECK_SUPERVISION_SESSION', str(uuid.uuid4())))
    engine = Settlement(directory, [{'leader': anchor, 'members': [anchor]}], anchor)
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__(0, True))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__(0, True))
    def report(state, durable=True, **fields):
        status.update(state=state, revision=status['revision'] + 1, **fields)
        persisted = True
        try:
            if durable: save_process_json(directory / 'supervision.json', status)
        except (OSError, ProcessRecoveryError) as error:
            engine.fail(error, 'persistence'); persisted = False
            status.update(revision=status['revision'] + 1, failure=engine.failure, failureKind=engine.failure_kind)
        with contextlib.suppress(OSError): control.sendall(json.dumps(status).encode() + b'\n')
        return persisted
    pending = bytearray(); control_open = True
    try:
        startup_deadline = process_clock() + 30
        while b'\n' not in pending and not stop[0]:
            try: chunk = control.recv(4096)
            except BlockingIOError:
                if process_clock() >= startup_deadline: raise OperationalError('Managed startup timed out after 30 seconds')
                wakeup.wait(startup_deadline - process_clock()); continue
            if not chunk: control_open = False; stop[0] = True; break
            pending.extend(chunk)
            if len(pending) > REGISTRY_LIMIT: raise OperationalError('Managed startup message exceeds 64 KiB')
        if stop[0]:
            status.update(pipeDrainComplete=True, processesSettled=True)
            report('cancelled', failure='Managed startup cancelled before command execution', failureKind='startup', recoveryRequired=False)
            wakeup.close(); control.close()
            return 130
        line, _, pending = pending.partition(b'\n'); request = json.loads(line)
        read_gate, write_gate = os.pipe()
        bootstrap = 'import os,sys;gate=int(sys.argv[1]);go=os.read(gate,1);os.close(gate);go or sys.exit(125);os.execv(sys.argv[2],sys.argv[2:])'
        try:
            command = subprocess.Popen([sys.executable, '-I', '-c', bootstrap, str(read_gate), *request['args']],
                cwd=request['cwd'], pass_fds=(read_gate,))
            identity = process_identity(command.pid)
            if identity is None: raise ProcessRecoveryError('Cannot establish command birth identity')
            status['command'] = identity; engine.entries[0]['members'].append(identity)
            with process_write_batch(directory):
                save_registry(directory / 'children.json', engine.entries)
                persisted = report('running')
            if persisted and not stop[0]: os.write(write_gate, b'1'); launched = True
        finally: os.close(read_gate); os.close(write_gate)
    except BaseException as error: engine.fail(error, 'startup'); stop[0] = True
    finally:
        for fd in (0, 1, 2):
            with contextlib.suppress(OSError): os.close(fd)
    if not launched: status['pipeDrainComplete'] = True
    control.setblocking(False); work_settled = False; drain_deadline = None
    try:
        while True:
            try:
                if control_open:
                    try:
                        message = control.recv(65536)
                        if not message:
                            control_open = False; stop[0] = True; wakeup.forget(control)
                        pending.extend(message)
                    except BlockingIOError: pass
                    except OSError as error:
                        engine.fail(error, 'control'); control_open = False; stop[0] = True; wakeup.forget(control)
                    while b'\n' in pending:
                        line, _, pending = pending.partition(b'\n'); message = json.loads(line)
                        if message.get('action') == 'stop':
                            stop[0] = True
                            inherited = message.get('deadline')
                            if type(inherited) in (int, float):
                                engine.termination.deadline = min(engine.termination.deadline or inherited, inherited)
                        if message.get('sessionID') == status['sessionID']:
                            if message.get('action') == 'drained':
                                status['pipeDrainComplete'] = True; engine.next_sample = 0
                            if message.get('action') == 'pipeFailure': engine.fail(ProcessDrainError(message['message']), 'pipeDrain'); stop[0] = True
                    if len(pending) > REGISTRY_LIMIT: raise OperationalError('Managed control message exceeds 64 KiB')
                rc = command.poll() if command is not None else None
                if rc is not None and status['commandReturnCode'] is None:
                    status['commandReturnCode'] = rc; engine.termination.begin(); engine.next_sample = 0
                if stop[0]: engine.termination.begin()
                if engine.termination.started is not None and status.get('deadline') != engine.termination.deadline:
                    report('draining', deadline=engine.termination.deadline)
                quiet = engine.step()
                if engine.termination.started is not None and quiet and (command is None or rc is not None):
                    if not work_settled:
                        work_settled = True; status['processesSettled'] = True
                        drain_deadline = min(process_clock() + 5, engine.termination.deadline)
                        report('draining', durable=False)
                    if not control_open and not status['pipeDrainComplete']:
                        report('failed', failure='Parent control channel closed before output pipe acknowledgment', failureKind='control', recoveryRequired=True)
                        return 2
                    if status['pipeDrainComplete']:
                        report('failed' if engine.failure else 'settled', failure=engine.failure, failureKind=engine.failure_kind, recoveryRequired=False)
                        return 0 if not engine.failure else 2
                    if engine.failure_kind == 'pipeDrain' or process_clock() >= drain_deadline:
                        engine.fail(ProcessDrainError('Managed output pipes did not close; external pipe ownership is unresolved. Recover or detach the checkout.'), 'pipeDrain')
                        report('failed', failure=engine.failure, failureKind='pipeDrain', recoveryRequired=True)
                        return 2
                if engine.termination.expired:
                    report('failed', failure=str(engine.expired_error()), failureKind=engine.failure_kind or 'settlement', recoveryRequired=True)
                    return 2
            except BaseException as error:
                engine.fail(error, 'supervision'); stop[0] = True; control_open = False; pending.clear(); wakeup.forget(control)
            remaining = engine.next_sample - process_clock()
            for limit in (engine.termination.deadline, drain_deadline):
                if limit is not None: remaining = min(remaining, limit - process_clock())
            wakeup.wait(remaining)
    finally: wakeup.close(); control.close()


class ManagedChild:
    def __init__(self, args, cwd, env, *, stdin=False, stderr=subprocess.PIPE, text=True, supervisor_script=None):
        self.args, self.cwd, self.env = [str(a) for a in args], cwd, env
        self.supervisor_script = Path(supervisor_script or __file__).resolve()
        self.stdin, self.stderr, self.text = stdin, stderr, text
        self.registry = Path(env['HOLODECK_REQUEST_DIRECTORY']) / 'children.json'
        self.process = None; self.control = None; self.status = None; self.pending = bytearray(); self.control_eof = False; self.stop_sent = False; self.channel_error = None
        self.local_failure = None; self.pipes_drained = False; self.acknowledged = False; self.fallback = None
        self.stop_deadline = None; self.cleanup_errors = []; self.fallback_evidence_error = None

    def __enter__(self):
        terminate_registered(self.registry.parent)
        self.control, child_control = socket.socketpair(); session = str(uuid.uuid4())
        try:
            self.process = subprocess.Popen([sys.executable, '-I', str(self.supervisor_script), '_supervise', str(child_control.fileno())],
                cwd=self.cwd, env=dict(self.env, HOLODECK_SUPERVISION_SESSION=session), stdin=subprocess.PIPE if self.stdin else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=self.stderr, text=self.text, start_new_session=True, pass_fds=(child_control.fileno(),))
            self.identity = process_identity(self.process.pid)
            if self.identity is None: raise ProcessRecoveryError('Cannot establish managed supervisor identity')
            self.status = new_status(self.identity, session)
            save_registry(self.registry, [{'leader': self.identity, 'members': [self.identity]}])
            self.control.sendall(json.dumps({'args': self.args, 'cwd': str(self.cwd)}).encode() + b'\n')
            self.control.setblocking(False); deadline = process_clock() + 30
            with selectors.DefaultSelector() as ready:
                ready.register(self.control, selectors.EVENT_READ)
                while self.status['state'] == 'starting':
                    self.sample()
                    if self.status['state'] != 'starting' or self.process.poll() is not None or self.control_eof: break
                    if process_clock() >= deadline: raise OperationalError('Managed supervisor startup timed out after 30 seconds')
                    ready.select(max(0, deadline - process_clock()))
            self.check_status()
            return self
        except BaseException as error:
            if self.process is not None and self.status is None:
                # No launch request has been sent. Closing control aborts the owner;
                # never signal a PID whose birth could not be established.
                self.close_pipes()
                try: self.process.wait(timeout=10)
                except subprocess.TimeoutExpired as cleanup_error:
                    raise ProcessRecoveryError('Unregistered supervisor did not exit after startup cancellation; retain the journal') from cleanup_error
                retire_evidence(self.registry.parent)
                raise OperationalError('Managed startup failed before command execution: ' + str(error)) from error
            if self.process is not None:
                self.stop()
                self.__exit__(*sys.exc_info())
            else: self.close_pipes()
            raise
        finally: child_control.close()

    @property
    def command_returncode(self): return self.status.get('commandReturnCode') if self.status else None

    def accept_status(self, value):
        if self.status and (value.get('sessionID') != self.status.get('sessionID') or value.get('supervisor') != self.identity):
            raise ProcessRecoveryError('Supervisor status does not belong to this command')
        if self.status is None or value.get('revision', 0) > self.status.get('revision', 0): self.status = value

    def sample(self):
        while self.control is not None:
            try: chunk = self.control.recv(65536)
            except BlockingIOError: break
            except OSError as error:
                self.channel_error = str(error); self.control_eof = True; break
            if not chunk: self.control_eof = True; break
            self.pending.extend(chunk)
            while b'\n' in self.pending:
                line, _, self.pending = self.pending.partition(b'\n'); self.accept_status(json.loads(line))
            if len(self.pending) > REGISTRY_LIMIT: raise ProcessRecoveryError('Malformed supervisor status channel')

    def check_status(self):
        self.sample()
        if self.local_failure: raise self.local_failure
        if self.status and self.status.get('failure'):
            kind = (ProcessDrainError if self.status.get('failureKind') == 'pipeDrain' else ProcessRecoveryError) if self.status.get('recoveryRequired') else OperationalError
            raise kind(self.status['failure'])

    def send(self, action, **fields):
        if self.control is not None:
            with contextlib.suppress(OSError):
                self.control.sendall(json.dumps(dict(action=action, sessionID=self.status['sessionID'], **fields)).encode() + b'\n')

    def stop(self):
        self.stop_deadline = self.stop_deadline or status_deadline(self.status) or process_clock() + 10
        self.send('stop', deadline=self.stop_deadline)
        identity = getattr(self, 'identity', None)
        if self.process is not None and identity is not None and not self.stop_sent and process_identity(self.process.pid) == identity:
            self.stop_sent = True
            try: os.kill(self.process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            except OSError as error: self.cleanup_errors.append(str(error))

    def drain_deadline(self):
        return min(process_clock() + 5, status_deadline(self.status) or process_clock() + 10)

    def pipe_failure(self):
        message = 'Managed output pipes did not close; external pipe ownership is unresolved. Recover or detach the checkout.'
        self.local_failure = ProcessDrainError(message)
        self.send('pipeFailure', message=message)
        raise self.local_failure

    def close_pipes(self):
        if self.control is not None: self.control.close(); self.control = None
        if self.process is not None:
            for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
                if pipe is not None and hasattr(pipe, 'close'):
                    with contextlib.suppress(OSError): pipe.close()

    def fallback_step(self):
        if (self.status.get('state') in TERMINAL_STATES and self.status.get('processesSettled')
                and self.status.get('pipeDrainComplete') and not self.status.get('recoveryRequired')
                and not group_members(self.identity['pid'])
                and not (self.status.get('command') and process_identity(self.status['command']['pid']) == self.status['command'])):
            return self.pipes_drained
        if self.fallback is None:
            final = read_supervision(self.registry.parent)
            if final: self.accept_status(final)
            try: entries = read_registry(self.registry.parent)
            except (OperationalError, OSError) as error:
                self.fallback_evidence_error = error
                entries = [{'leader': self.identity, 'members': [i for i in (self.identity, self.status.get('command')) if i]}]
            self.fallback = Settlement(self.registry.parent, entries, self.identity,
                                       Termination(self.stop_deadline or status_deadline(self.status)))
            self.fallback.termination.begin()
        if self.fallback_evidence_error:
            try:
                self.fallback.entries = read_registry(self.registry.parent)
                self.fallback_evidence_error = None
            except (OperationalError, OSError) as error: self.fallback.fail(error, 'registry')
        quiet = self.fallback.step()
        if quiet and self.pipes_drained and self.fallback_evidence_error is None:
            if (not self.status.get('processesSettled') or self.status.get('state') not in TERMINAL_STATES
                    or (not self.status.get('pipeDrainComplete') and self.status.get('failureKind') != 'pipeDrain')):
                self.status.update(revision=self.status['revision'] + 1, state='failed', processesSettled=True,
                    pipeDrainComplete=True, failure=self.status.get('failure') or ('Managed supervisor exited; command outcome is unknown' if self.command_returncode is None else 'Managed supervisor exited before completing its protocol'),
                    failureKind='supervisor', recoveryRequired=False)
                if self.fallback.failure: self.status['failure'] += '; cleanup error: ' + self.fallback.failure
                try: save_process_json(self.registry.parent / 'supervision.json', self.status)
                except (OSError, ProcessRecoveryError) as error: self.status['failure'] += '; cleanup error: ' + str(error)
            return True
        if self.fallback.termination.expired: raise self.fallback.expired_error()
        return False

    def __exit__(self, kind, error, traceback):
        try:
            if isinstance(error, ProcessDrainError): self.local_failure = error
            if self.process.poll() is None: self.stop()
            for _ in self.output_chunks(finishing=True): pass
            self.process.wait(timeout=1)
            if self.status and self.status.get('processesSettled') and self.pipes_drained and not self.local_failure and not self.status.get('recoveryRequired'):
                retire_evidence(self.registry.parent)
            self.check_status()
            if self.cleanup_errors: raise OperationalError('; cleanup error: '.join(self.cleanup_errors))
            if self.process.returncode != 0:
                raise OperationalError('Managed supervisor exited ' + str(self.process.returncode) + ' after verified settlement')
        except (OperationalError, OSError) as cleanup_error:
            if error is not None and cleanup_error is not error and str(cleanup_error) != str(error):
                unresolved = isinstance(cleanup_error, ProcessRecoveryError) or not (self.status and self.status.get('processesSettled') and self.pipes_drained)
                failure = ProcessRecoveryError if unresolved else OperationalError
                raise failure('Original command error: ' + str(error) + '; cleanup error: ' + str(cleanup_error)) from cleanup_error
            raise
        finally: self.close_pipes()

    def output_chunks(self, input=None, timeout=None, finishing=False):
        process = self.process
        payload = memoryview(input.encode(getattr(process.stdin, 'encoding', None) or 'utf-8') if isinstance(input, str) else input or b'')
        deadline = process_clock() + timeout if timeout is not None else None
        drain_deadline = None
        with selectors.DefaultSelector() as selector:
            if self.control is not None: selector.register(self.control, selectors.EVENT_READ, 'control')
            for name, pipe in [('stdout', process.stdout), ('stderr', process.stderr)]:
                if pipe is not None and not pipe.closed:
                    os.set_blocking(pipe.fileno(), False); selector.register(pipe, selectors.EVENT_READ, name)
            if process.stdin is not None and not process.stdin.closed:
                if payload:
                    os.set_blocking(process.stdin.fileno(), False); selector.register(process.stdin, selectors.EVENT_WRITE, 'stdin')
                else: process.stdin.close()
            while True:
                self.sample()
                if self.control_eof and self.control is not None and self.control.fileno() in selector.get_map():
                    selector.unregister(self.control)
                    if self.status.get('state') not in TERMINAL_STATES: self.stop()
                if deadline is not None and self.command_returncode is None and process_clock() >= deadline:
                    raise subprocess.TimeoutExpired(self.args, timeout)
                pipes = [key for key in selector.get_map().values() if key.data in ('stdout', 'stderr')]
                if not pipes:
                    self.pipes_drained = True
                    if not self.acknowledged: self.send('drained'); self.acknowledged = True
                if self.control_eof and self.pipes_drained and self.status.get('state') in TERMINAL_STATES:
                    try: process.wait(timeout=max(0, min(1, (self.stop_deadline or status_deadline(self.status) or process_clock() + 1) - process_clock())))
                    except subprocess.TimeoutExpired: pass
                owner_dead = process.poll() is not None
                if owner_dead:
                    if self.fallback_step(): break
                if self.status and self.status.get('processesSettled') and not self.pipes_drained:
                    drain_deadline = drain_deadline or self.drain_deadline()
                    if process_clock() >= drain_deadline:
                        if finishing: raise self.local_failure or ProcessDrainError('Pipe completion is unverified; retain the journal')
                        self.pipe_failure()
                limit = self.stop_deadline or status_deadline(self.status)
                if limit is not None and process_clock() >= limit:
                    raise self.local_failure or ProcessRecoveryError('Settlement budget exhausted before verification; retain the journal')
                for key, _ in selector.select(.025 if owner_dead else PROCESS_SAMPLE_SECONDS):
                    if key.data == 'control':
                        self.sample()
                        if owner_dead: selector.unregister(key.fileobj)
                    elif key.data == 'stdin':
                        try: count = os.write(process.stdin.fileno(), payload[:65536])
                        except BlockingIOError: continue
                        except BrokenPipeError: count = len(payload)
                        payload = payload[count:]
                        if not payload: selector.unregister(process.stdin); process.stdin.close()
                    else:
                        try: chunk = os.read(key.fd, 65536)
                        except BlockingIOError: continue
                        if chunk: yield key.data, chunk
                        else: selector.unregister(key.fileobj); key.fileobj.close()
            if not finishing: self.check_status()

    def lines(self, prompt):
        pending = bytearray()
        for stream, chunk in self.output_chunks(prompt):
            if stream != 'stdout': continue
            pending.extend(chunk)
            while b'\n' in pending:
                line, _, pending = pending.partition(b'\n'); yield line.decode('utf-8', errors='replace')
        if pending: yield pending.decode('utf-8', errors='replace')


def managed_run(args, cwd, env, timeout, input, text=True):
    with ManagedChild(args, cwd, env, stdin=input is not None, text=text) as child:
        captured = {'stdout': bytearray(), 'stderr': bytearray()}
        for stream, chunk in child.output_chunks(input, timeout): captured[stream].extend(chunk)
        def output(name):
            data = bytes(captured[name])
            if not text: return data
            pipe = getattr(child.process, name)
            return data.decode(pipe.encoding, errors=pipe.errors).replace('\r\n', '\n').replace('\r', '\n')
        return subprocess.CompletedProcess(args, child.command_returncode, output('stdout'), output('stderr'))

__all__ = ['OperationalError', 'ProcessRecoveryError', 'ProcessObservationError', 'ProcessDrainError', 'CLOCK_DOMAIN', 'REGISTRY_LIMIT', 'PROCESS_SAMPLE_SECONDS', 'process_clock', 'process_identity', 'group_members', 'merge_members', 'read_process_bytes', 'read_process_json', 'save_process_json', 'save_registry', 'valid_identity', 'read_registry', 'read_supervision', 'new_status', 'status_deadline', 'Termination', 'Settlement', 'terminate_registered', 'supervise', 'ManagedChild', 'managed_run']

if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] != '_supervise': raise SystemExit('Internal supervisor entry point')
    raise SystemExit(supervise(int(sys.argv[2])))
