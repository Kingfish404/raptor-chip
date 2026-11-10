"""The same native DMI/SBA target API over simulated pins or one explicit JTAG probe."""

import json
import math
import os
from pathlib import Path
import re
import select
import socket
import struct
import subprocess
import sys
import threading
import time

from .client import Board, BringupError, IDCODE
from .native_flash import uint32

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "fpga/arty-a7-t100/scripts"


class TransportError(BringupError):
    """The transport disappeared; callers must establish mutation ownership before recovery."""


class NativeTarget(Board):
    def __init__(self):
        super().__init__(None)
        self.dmi_log = None
        self.dmi_sequence = 0

    def record(self, phase, address, value, result=None, error=None):
        if self.dmi_log is not None:
            row = {"sequence": self.dmi_sequence, "host_time_ns": time.monotonic_ns(),
                   "phase": phase, "address": address,
                   "write_value": value, "result": result, "error": error}
            self.dmi_log.write(json.dumps(row) + "\n")
            self.dmi_log.flush()

    def dmi(self, address, value=None):
        self.dmi_sequence += 1
        self.record("request", address, value)
        try:
            result = super().dmi(address, value)
        except BringupError as error:
            self.record("error", address, value, error=str(error))
            raise
        self.record("response", address, value, result=result)
        return result

    def command(self, *args, **kwargs):
        raise BringupError("RPB1 bridge commands do not address the native chip")

    def write_register(self, number, value):
        uint32(value)
        if type(number) is not int or not 0 <= number <= 0xffff:
            raise ValueError("invalid abstract register number")
        self.dmi(0x16, 0x700)
        self.dmi(4, value)
        self.dmi(0x17, (2 << 20) | (1 << 17) | (1 << 16) | number)
        for _ in range(100):
            status = self.dmi(0x16)
            if status & 0x700:
                raise BringupError(f"abstract register write failed: {status:08x}")
            if not status & 0x1000:
                return
        raise BringupError("abstract register write timed out")

    def reset_halt(self):
        self.dmi(0x10, 1)
        self.dmi(0x10, 0x80000003)
        for _ in range(100):
            if self.dmi(0x11) & 0x3300 == 0x3000:
                break
        else:
            raise BringupError("hart never became unavailable during ndmreset")
        self.dmi(0x10, 0x80000001)
        for _ in range(100):
            if self.dmi(0x11) & 0x300 == 0x300:
                return
        raise BringupError("hart did not halt after ndmreset release")


class SimTarget(NativeTarget):
    def __init__(self, executable, image, log, timeout=120, trace_dmi=False):
        super().__init__()
        self.timeout = timeout
        self.exchange_lock = threading.Lock()
        self.log = Path(log).open("w")
        if trace_dmi:
            self.dmi_log = Path(log).with_suffix(".dmi.jsonl").open("w")
        self.process = subprocess.Popen(
            [str(Path(executable).resolve()), f"+NATIVE_FLASH_IMAGE={Path(image).resolve()}"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)

    def exchange(self, operation, count=0, value=0, data=0):
        with self.exchange_lock:
            return self._exchange(operation, count, value, data)

    def _exchange(self, operation, count, value, data):
        self.process.stdin.write(struct.pack("<BBII", ord(operation), count, value, data))
        self.process.stdin.flush()
        reply = bytearray()
        deadline = time.monotonic() + self.timeout
        descriptor = self.process.stdout.fileno()
        while len(reply) < 4:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
                raise BringupError("native pin simulation response timed out")
            chunk = os.read(descriptor, 4 - len(reply))
            if not chunk:
                raise BringupError("native pin simulator exited; inspect its RTL log")
            reply.extend(chunk)
        return struct.unpack("<I", reply)[0]

    def jtag(self, tms, tdi):
        if not tms or len(tms) != len(tdi):
            raise ValueError("JTAG needs equal nonempty lists")
        result = []
        for start in range(0, len(tms), 32):
            ms, di = tms[start:start + 32], tdi[start:start + 32]
            word = self.exchange("J", len(ms), sum(int(b) << n for n, b in enumerate(ms)),
                                 sum(int(b) << n for n, b in enumerate(di)))
            result.extend((word >> bit) & 1 for bit in range(len(ms)))
        return result

    def statistics(self):
        names = {"programs": "P", "erases": "E", "octal_frames": "F",
                 "last_program_physical": "A", "last_erase_physical": "Z"}
        result = {name: self.exchange(command) for name, command in names.items()}
        result["simulation_time_ps"] = self.exchange("T") | (self.exchange("H") << 32)
        result["host_ds_oe"] = self.exchange("D")
        result["pin_measurements"] = self.pin_measurements()
        return result

    def pin_measurements(self):
        def signed(value):
            return value - (1 << 32) if value & (1 << 31) else value
        lanes = [{"lane": lane, "min_ps": signed(self.exchange("M", lane)),
                  "max_ps": signed(self.exchange("M", lane + 8)),
                  "samples": self.exchange("M", lane + 16),
                  "rising_samples": self.exchange("M", lane + 36),
                  "falling_samples": self.exchange("M", lane + 44)} for lane in range(8)]
        names = ("ck_half_min_ps", "ck_half_max_ps", "ck_intervals", "tx_setup_min_ps",
                 "tx_hold_min_ps", "host_release_to_target_drive_min_ps",
                 "target_release_to_host_drive_min_ps", "reserved",
                 "cs_setup_min_ps", "cs_hold_min_ps", "cs_high_min_ps", "reset_low_min_ps")
        timing = {name: self.exchange("M", 24 + index) for index, name in enumerate(names)
                  if name != "reserved"}
        core_names = ("core_period_min_ps", "core_period_max_ps", "core_periods")
        timing.update({name: self.exchange("M", 52 + index)
                       for index, name in enumerate(core_names)})
        return {"dq_minus_ds": lanes, "timing": timing, "scope": "actual simulated pin arrivals"}

    def console(self):
        data = bytearray()
        for _ in range(4096):
            word = self.exchange("U")
            if not word & 0x100:
                break
            data.append(word & 255)
        return bytes(data)

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()
        if self.dmi_log is not None:
            self.dmi_log.close()


class OpenOcdTarget(NativeTarget):
    """Private local control connection, one explicit probe, no FPGA/Flash programming."""

    def __init__(self, serial, log, executable="openocd", speed_khz=500, timeout=10,
                 trace_dmi=False, tap_config=None):
        super().__init__()
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", serial):
            raise ValueError("give the explicit authorized probe serial")
        if not 1 <= speed_khz <= 500:
            raise ValueError("initial native 10 MHz board tests allow TCK at most 500 kHz")
        self.serial, self.timeout = serial, timeout
        self.batch_sba = not trace_dmi
        self.socket = None
        self.metrics_path = Path(log).with_suffix(".transport.json")
        self.metrics = {"rpc_calls": 0, "read_words": 0, "write_words": 0,
                        "read_blocks": 0, "write_blocks": 0, "trace_dmi": trace_dmi}
        self.log = Path(log).open("w")
        if trace_dmi:
            self.dmi_log = Path(log).with_suffix(".dmi.jsonl").open("w")
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        command = [executable, "-s", str(SCRIPTS), "-c", f"set RAPT_PROBE_SERIAL {serial}",
                   "-f", str(tap_config or SCRIPTS / "tap.cfg"),
                   "-f", str(Path(__file__).with_name("sba_batch.tcl")),
                   "-c", f"adapter speed {speed_khz}",
                   "-c", "bindto 127.0.0.1", "-c", "gdb_port disabled",
                   "-c", "telnet_port disabled", "-c", f"tcl_port {port}", "-c", "init"]
        Path(log).with_suffix(".command.json").write_text(json.dumps(command, indent=2)
                                                        + "\n")
        # A pipe lifeline reaches the guard even if this interpreter is SIGKILLed.
        guard = [sys.executable, str(Path(__file__).with_name("process_guard.py")),
                 "--grace", "5", "--", *command]
        self.process = subprocess.Popen(guard, stdin=subprocess.PIPE, stdout=self.log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + timeout
            while True:
                if self.process.poll() is not None:
                    raise TransportError("OpenOCD exited before probe connection; inspect its log")
                try:
                    self.socket = socket.create_connection(("127.0.0.1", port), timeout=0.1)
                    self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    self.socket.settimeout(timeout)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TransportError("OpenOCD probe connection timed out") from None
                    time.sleep(0.05)
        except BaseException:
            self.close()
            raise

    def rpc(self, command):
        # Commands are constructed only from validated integers and fixed procedure names.
        script = f"set rc [catch {{{command}}} value]; list $rc $value\x1a"
        self.metrics["rpc_calls"] += 1
        data = bytearray()
        try:
            self.socket.sendall(script.encode())
            while not data.endswith(b"\x1a"):
                part = self.socket.recv(4096)
                if not part:
                    raise TransportError("OpenOCD disconnected; no automatic retry")
                data.extend(part)
                if len(data) > 65536:
                    raise BringupError("unexpected OpenOCD response length")
        except OSError as error:
            raise TransportError(f"OpenOCD transport failed; no automatic retry: {error}") from error
        code, _, value = data[:-1].decode().partition(" ")
        if code != "0":
            raise BringupError(f"OpenOCD command failed: {value}")
        return value.strip()

    def idcode(self):
        # A shared chip reset can reset the TAP behind OpenOCD's cached state.
        # arp_init uses TMS/TCK only; it never asserts the chip/Flash reset line.
        self.rpc("jtag arp_init")
        self.rpc("irscan rapt.tap 1")
        value = int(self.rpc("expr 0x[drscan rapt.tap 32 0]"), 0)
        if value != IDCODE:
            raise BringupError(f"unexpected native CPU TAP IDCODE {value:08x}")
        return value

    def sba_read_words(self, address, count, timeout):
        from .native_flash import Sba32
        Sba32.address(address)
        if type(count) is not int or count <= 0 or address + 4 * count - 4 > 0xffffffff:
            raise ValueError("invalid SBA block length")
        words = []
        for first in range(0, count, 256):
            length = min(256, count - first)
            reply = self.rpc(f"rapt_batch_read {address + 4 * first} {length} "
                             f"{max(1, math.ceil(timeout * 1000))}")
            if reply.startswith("{") and reply.endswith("}"):
                reply = reply[1:-1]
            fields = reply.split()
            if len(fields) != length or any(not re.fullmatch(r"[0-9a-fA-F]{8}", w)
                                            for w in fields):
                raise BringupError("invalid batched SBA read response; no retry")
            words.extend(int(word, 16) for word in fields)
            self.metrics["read_blocks"] += 1
            self.metrics["read_words"] += length
        return words

    def sba_write_words(self, address, words, timeout):
        from .native_flash import Sba32
        Sba32.address(address)
        words = list(words)
        if not words or address + 4 * len(words) - 4 > 0xffffffff:
            raise ValueError("invalid SBA block length")
        for word in words:
            uint32(word)
        for first in range(0, len(words), 256):
            block = words[first:first + 256]
            values = " ".join(str(word) for word in block)
            reply = self.rpc(f"rapt_batch_write {address + 4 * first} {{{values}}} "
                             f"{max(1, math.ceil(timeout * 1000))}")
            if reply != str(len(block)):
                raise BringupError("invalid batched SBA write response; physical outcome uncertain")
            self.metrics["write_blocks"] += 1
            self.metrics["write_words"] += len(block)

    def dmi(self, address, value=None):
        if type(address) is not int or not 0 <= address < 128:
            raise ValueError("DMI address out of range")
        if value is not None:
            uint32(value)
        operation = 1 if value is None else 2
        self.dmi_sequence += 1
        self.record("request", address, value)
        try:
            result = int(self.rpc(f"rapt_dmi {address} {value or 0} {operation}"), 0)
        except BringupError as error:
            self.record("error", address, value, error=str(error))
            raise
        self.record("response", address, value, result=result)
        return result

    def close(self):
        try:
            connection, self.socket = self.socket, None
            if connection is not None:
                try:
                    connection.settimeout(1)
                    connection.sendall(b"shutdown\x1a")
                except OSError:
                    pass
                finally:
                    connection.close()
        finally:
            try:
                if hasattr(self, "process"):
                    # This also runs if a deadline interrupts socket shutdown.
                    try:
                        if self.process.stdin and not self.process.stdin.closed:
                            self.process.stdin.close()
                    finally:
                        self.reap_guard()
            finally:
                try:
                    self.metrics_path.write_text(json.dumps(self.metrics, indent=2) + "\n")
                finally:
                    self.log.close()
                    if self.dmi_log is not None:
                        self.dmi_log.close()

    def reap_guard(self):
        try:
            self.process.wait(timeout=12)
        except BaseException as error:
            # A deadline during wait must also terminate and reap the owned guard.
            # Its handler closes the privileged guard's lifeline before exiting.
            try:
                self.process.terminate()
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=5)
            except BaseException:
                self.process.kill()
                self.process.wait(timeout=5)
                raise
            if not isinstance(error, subprocess.TimeoutExpired):
                raise
