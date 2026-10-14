"""Common runner for the multi-hart NEMU checks.

A check builds private native/reference binaries per XLEN, runs commands whose
logs and verdicts are appended to ``results.json``, and stops at the first
failure. Fault injection replays each corrupted journal both offline and
through a live pipe, where the reference must reject it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

from lib.build import (ROOT, build_nemu, build_reference, build_replay_driver, compile_guest, dtb_path,
                       guest_source)
from lib.journal import JournalError, check_journal
from lib.stream import finish_processes, supervise

SANITIZER_ERRORS = (b'runtime error:', b'WARNING: ThreadSanitizer')

PRODUCER = '''#!/usr/bin/env python3
"""Stand-in DUT that streams a saved journal to --diff-stream-fd."""
import os
import sys
descriptor = int(next(arg.split('=')[1] for arg in sys.argv if arg.startswith('--diff-stream-fd=')))
try:
    with open(sys.argv[-1], 'rb') as source:
        while block := source.read(65536):
            while block:
                block = block[os.write(descriptor, block):]
except BrokenPipeError:
    pass
os.close(descriptor)
'''


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else Path(data).read_bytes()).hexdigest()


def clean(output):
    return not any(error in output for error in SANITIZER_ERRORS)


def wfi_waits(output):
    return sum(map(int, re.findall(rb'wfi_waits=(\d+)', output)))


def parser(description, repeat=3, sanitizers=('undefined', 'thread')):
    result = argparse.ArgumentParser(description=description)
    result.add_argument('--output', type=Path)
    result.add_argument('--xlen', type=int, choices=(32, 64), nargs='+', default=[32, 64])
    result.add_argument('--repeat', type=int, default=repeat)
    result.add_argument('--sanitize', choices=sanitizers)
    result.add_argument('--disable-aslr', action='store_true')
    return result


class Check:
    """Session state, build artifacts and result bookkeeping for one check."""

    def __init__(self, args, name):
        if args.repeat < 1:
            raise SystemExit('--repeat must be positive')
        self.args = args
        self.name = name
        self.work = (args.output or ROOT / 'verify/build' / ('nemu-' + name)).resolve()
        self.work.mkdir(parents=True, exist_ok=True)
        self.session = Path(tempfile.mkdtemp(prefix='run-', dir=self.work))
        self.prefix = ['setarch', platform.machine(), '-R'] if args.disable_aslr else []
        self.environment = dict(os.environ, NEMU_HOME=str(ROOT / 'nemu'), UBSAN_OPTIONS='halt_on_error=1',
                                TSAN_OPTIONS='halt_on_error=1')
        self.results = []
        self.xlen = None
        self.hashes = {}
        self.details = {}
        self.timeout = 120
        self._producer = None

    def target(self, xlen, reference=True, driver=True):
        """Build the per-XLEN artifacts and select the XLEN for later results."""
        self.xlen = xlen
        self.directory = self.session / f'rv{xlen}'
        self.directory.mkdir()
        self.build = self.work / f'rv{xlen}'
        self.dtb = dtb_path(xlen)
        self.binary = build_nemu(self.build / 'nemu', xlen=xlen, sanitize=self.args.sanitize)
        self.hashes = {'native_sha256': sha256(self.binary)}
        if reference:
            self.reference = build_reference(self.build / 'nemu', self.build / 'reference', xlen, self.args.sanitize)
            self.hashes['reference_sha256'] = sha256(self.reference)
        if driver:
            self.driver = build_replay_driver(self.build / 'nemu-journal-replay', self.args.sanitize)
            self.hashes['driver_sha256'] = sha256(self.driver)
        return self

    def save(self, name, passed, **details):
        self.results.append(dict(name=name, xlen=self.xlen, passed=bool(passed), sanitizer=self.args.sanitize,
                                 **self.hashes, **self.details, **details))
        (self.session / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')
        print(f'RV{self.xlen} {name}: {"PASS" if passed else "FAIL"}', flush=True)
        if not passed:
            raise SystemExit('see ' + str(self.session / 'results.json'))

    def run(self, name, command, expect=0, markers=(b'status=OK',), timeout=None, environment=None, stdin=None,
            **details):
        """Run a command; ``expect`` is 0, 1 or 'nonzero'. Returns the merged output.

        With ``stdin`` the command gets those bytes and its own process group, which
        a timeout kills as a whole.
        """
        command = list(map(str, [*self.prefix, *command]))
        timeout = timeout or self.timeout
        environment = dict(self.environment, **(environment or {}))
        if stdin is None:
            result = subprocess.run(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=timeout)
            output, returncode = result.stdout, result.returncode
        else:
            process = subprocess.Popen(command, stdin=subprocess.PIPE, env=environment, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                output, _ = process.communicate(stdin, timeout=timeout)
            except subprocess.TimeoutExpired:
                finish_processes({'command': process})
                output, _ = process.communicate()
            finally:
                finish_processes({'command': process})
            returncode = process.returncode
        log = self.directory / (name + '.log')
        log.write_bytes(output)
        status = returncode != 0 if expect == 'nonzero' else returncode == expect
        if isinstance(markers, bytes):
            markers = (markers,)
        self.save(name, status and all(marker in output for marker in markers) and clean(output),
                  command=command, returncode=returncode, log=str(log), log_sha256=sha256(output), **details)
        return output

    def record(self, name, options, image, program=None, **details):
        """Capture ``image`` to a journal file and return (journal, output)."""
        journal = self.directory / (name + '.njr')
        journal.unlink(missing_ok=True)
        output = self.run(name + '-record', [program or self.binary, '-b', '-n', *options,
                                             '--diff-record=' + str(journal), '-t', self.dtb, image], **details)
        return journal, output

    def replay(self, name, journal, expect=0, markers=(b'status=OK',), **details):
        return self.run(name, [self.driver, self.reference, journal], expect, markers,
                        journal_sha256=sha256(journal), **details)

    def live(self, name, options, accepted=True, producer=None, expect=None, timeout=None, pipe_bytes=4096,
             reference_rejects=True):
        """Check DUT and reference over a bounded pipe; ``expect`` vets the reference summary.

        A rejected run normally requires the reference itself to fail; pass
        ``reference_rejects=False`` when the producer is expected to stop first.
        """
        result = supervise(producer or self.binary, self.reference, self.driver, list(map(str, options)),
                           self.directory / name, timeout=timeout or self.timeout, pipe_bytes=pipe_bytes, prefix=self.prefix,
                           environment=self.environment)
        passed = (result['status'] == 'OK') == accepted
        if accepted:
            passed &= expect is None or bool(expect(result['summaries']['ref']))
        elif reference_rejects:
            passed &= result['returncodes']['ref'] == 1
            passed &= 'NEMU_REPLAY_FAIL' in (self.directory / name / 'ref.log').read_text()
        for role in ('dut', 'ref'):
            passed &= clean((self.directory / name / (role + '.log')).read_bytes())
        self.save(name, passed, result=result)
        return result

    def guest(self, name, sources, harts, defines=(), c=False):
        sources = [source if isinstance(source, Path) else guest_source(source) for source in sources]
        return compile_guest(self.directory / (name + '.elf'), sources, self.xlen, harts, defines, c)

    def snapshot(self, *names):
        """Copy guest sources into the session so results identify the exact payload."""
        copies = []
        for name in names:
            copy = self.session / name
            copy.write_bytes(guest_source(name).read_bytes())
            copies.append(copy)
        self.details['payload_source_sha256'] = {copy.name: sha256(copy) for copy in copies}
        return copies

    def producer(self):
        if self._producer is None:
            self._producer = self.session / 'journal-producer'
            self._producer.write_text(PRODUCER)
            self._producer.chmod(0o700)
        return self._producer

    def faults(self, source, corrupt, faults, markers=None, inspect=False, live=True):
        """Reject each corruption of ``source`` offline and, when ``live``, through a pipe.

        ``corrupt(source, destination, fault)`` may return whether the memory-only
        checker still accepts the journal; ``inspect`` instead requires that checker
        to reject every fault in ``inspect`` (or all faults when True).
        """
        for fault in faults:
            corrupted = self.directory / ('fault-' + fault + '.njr')
            consistent = corrupt(source, corrupted, fault)
            if inspect is True or (inspect and fault in inspect):
                try:
                    check_journal(corrupted)
                    rejected = False
                except JournalError:
                    rejected = True
                self.save('inspect-fault-' + fault, rejected)
            marker = (markers or {}).get(fault, b'NEMU_REPLAY_FAIL')
            details = {} if consistent is None else dict(memory_checker_accepts=consistent)
            self.replay('fault-' + fault, corrupted, 1, marker, **details)
            if live:
                self.live('stream-fault-' + fault, [corrupted], False, self.producer())

    def finish(self, label):
        print(f'NEMU_{label}_VALIDATION results=' + str(self.session / 'results.json'), flush=True)
