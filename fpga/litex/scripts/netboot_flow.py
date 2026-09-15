#!/usr/bin/env python3
"""Fixed-profile orchestration; no flash, SD writes, or implicit network setup."""
import argparse
import contextlib
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import http.server
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import netboot

LITEX = Path(__file__).resolve().parents[1]


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def execute(argv, capture=False):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith(('MAKE', 'MFLAGS', 'RAPT_', 'LINUX_', 'FW_'))}
    return subprocess.run(list(map(str, argv)), check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, env=environment)


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        temporary = Path(stream.name)
    temporary.replace(path)


@contextlib.contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f'Busy: {path}') from None
        yield


def choose(candidates, requested, label):
    if requested:
        return requested
    candidates = sorted(set(candidates))
    require(len(candidates) == 1, f'{label}: expected one candidate, found {candidates}; set it in netboot.local.mk')
    return candidates[0]


def vivado(value):
    found = shutil.which(value)
    if found:
        return found
    require(value == 'vivado', f'Vivado not executable: {value}')
    candidates = [p for base in (Path.home() / 'Vivado', Path('/tools/Xilinx/Vivado'), Path('/opt/Xilinx/Vivado'))
                  for p in base.glob('*/Vivado/bin/vivado') if os.access(p, os.X_OK)]
    candidates += [p for base in (Path('/tools/Xilinx/Vivado'), Path('/opt/Xilinx/Vivado'))
                   for p in base.glob('*/bin/vivado') if os.access(p, os.X_OK)]
    return choose(map(str, candidates), '', 'VIVADO')


def source_identity(make_args):
    """Conservative hardware-input snapshot; runtime orchestration is not RTL."""
    repo = LITEX.parents[1]
    roots = (repo / 'hdl', repo / 'sim/rtl', repo / 'sim/include',
             LITEX / 'mk', LITEX / 'cores', LITEX / 'scripts')
    paths = {LITEX / 'Makefile', *LITEX.glob('*.py'), *LITEX.glob('*.tcl')}
    for root in roots:
        paths.update(p for p in root.rglob('*') if p.suffix in ('.sv', '.svh', '.v', '.vh', '.py', '.mk', '.tcl', '.h', '.S'))
    # Fixing UART/TFTP orchestration does not alter the compiled bitstream.
    # The board, packer, BIOS generation and RTL sources remain covered.
    paths.discard(LITEX / 'scripts/netboot_flow.py')
    digest = hashlib.sha256(json.dumps(make_args).encode())
    for path in sorted(paths):
        digest.update(str(path.relative_to(LITEX.parents[1])).encode() + b'\0')
        digest.update(path.read_bytes())
    return digest.hexdigest()


def network_stats(output):
    match = re.search(r'^\s*eth0:\s*(.*)$', output, re.MULTILINE)
    require(match is not None, 'Missing eth0 counters')
    values = list(map(int, match[1].split()))
    require(len(values) == 16, 'Invalid eth0 counters')
    return {'rx_bytes': values[0], 'rx_errors': values[2], 'rx_dropped': values[3],
            'tx_bytes': values[8], 'tx_errors': values[10], 'tx_dropped': values[11]}


def bundle(context, root):
    payload = Path(context['payload'])
    require(payload.name == 'fw_payload.bin', 'Payload must belong to a release with manifest.json')
    files, record = netboot.prepare(Path(context['firmware']), payload.parent,
                                    int(context['xlen']), context['cross'])
    identity = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    root.mkdir(parents=True, exist_ok=True)
    destination = root / identity
    require(not destination.is_symlink(), 'Refusing symlink bundle')
    if destination.exists():
        require(netboot.verify_bundle(destination) == record, 'Existing bundle provenance mismatch')
    else:
        with tempfile.TemporaryDirectory(dir=root) as scratch:
            staging = Path(scratch) / 'bundle'
            netboot.write_bundle(staging, files, record)
            staging.rename(destination)
    save(root / 'current.json', {'path': str(destination), 'identity': identity})
    return destination


def tftp_get(address, name, timeout=5):
    """Read a small manifest through the real TFTP service, not just its filesystem."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        packet, target = b'\x00\x01' + name.encode() + b'\0octet\0', (address, 69)
        sock.sendto(packet, target)
        result, block, peer = bytearray(), 1, None
        retries = 0
        while True:
            try:
                data, source = sock.recvfrom(65536)
            except socket.timeout:
                retries += 1
                require(retries <= 3, 'TFTP manifest transfer timed out')
                sock.sendto(packet, target)
                continue
            require(source[0] == address and (peer is None or source == peer), 'Unexpected TFTP peer')
            peer = source
            require(len(data) >= 4 and data[:2] == b'\x00\x03', 'TFTP error or unsupported response')
            number = int.from_bytes(data[2:4], 'big')
            if number == block - 1 and block > 1:
                retries += 1
                require(retries <= 3, 'Repeated TFTP duplicate block')
                sock.sendto(packet, target)
                continue
            require(number == block, 'Unexpected TFTP block')
            retries = 0
            result.extend(data[4:])
            require(len(result) <= 65536, 'TFTP manifest too large')
            packet, target = b'\x00\x04' + data[2:4], peer
            sock.sendto(packet, target)
            if len(data) < 516:
                return bytes(result)
            block += 1


class Console:
    def __init__(self, device, log):
        import serial
        self.port = serial.Serial(device, 115200, timeout=0.2, exclusive=True)
        self.log = log.open('ab')
        self.pending = ''

    def close(self):
        self.port.close()
        self.log.close()

    def send(self, command):
        self.port.write(command.encode() + b'\r')

    def wait(self, pattern, timeout, on_data=None, cancel=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(cancel is None or not cancel.is_set(), 'UART wait cancelled after loader failure')
            match = re.search(pattern, self.pending)
            if match:
                result = self.pending[:match.end()]
                self.pending = self.pending[match.end():]
                return result
            data = self.port.read(max(1, self.port.in_waiting))
            if data:
                self.log.write(data)
                self.log.flush()
                text = data.decode(errors='replace')
                print(text, end='', flush=True)
                self.pending = (self.pending + text)[-262144:]
                # Match the terminal text, retaining raw bytes in the log.
                # Strip after accumulation so split CSI sequences also work.
                self.pending = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', self.pending)
                if on_data:
                    on_data(self.pending)
        raise TimeoutError(f'UART timeout waiting for {pattern}; see capture log, do not infer a deadlock')

    def command(self, command, timeout=120):
        token = 'RAPT_' + os.urandom(8).hex()
        self.send(command + f"; printf '\\n{token}:%s\\n' \"$?\"")
        output = self.wait(r'\n' + token + r':\d+\r*\n', timeout)
        require(re.search(r'\n' + token + r':0\r*\n', output), f'Board command failed: {command}')
        return output


def load_to_bios(port, load):
    """Read/respond during programming: autoboot may expire before Vivado exits."""
    port.port.reset_input_buffer()
    port.pending = ''
    interrupted = False
    cancelled = threading.Event()
    def interrupt(text):
        nonlocal interrupted
        if not interrupted and 'Press Q or ESC' in text:
            port.port.write(b'Q')
            interrupted = True
    with ThreadPoolExecutor(max_workers=1) as reader:
        prompt = reader.submit(port.wait, r'litex>\s*', 180, interrupt, cancelled)
        try:
            load()
            prompt.result()
        finally:
            cancelled.set()


def bios_ip_commands(soc, server_ip):
    """Use dynamic commands only when compiled in; validate static BIOS IPs."""
    network = ipaddress.IPv4Network(server_ip + '/24', strict=False)
    local_ip = str(network.network_address + (50 if server_ip != str(network.network_address + 50) else 51))
    header = (soc / 'software/include/generated/soc.h').read_text()
    if re.search(r'^#define ETH_DYNAMIC_IP\b', header, re.MULTILINE):
        return ['eth_local_ip ' + local_ip, 'eth_remote_ip ' + server_ip]
    source = (soc / 'bios-src/boot.c').read_text()
    for name, macro, expected in (('local_ip', 'LOCALIP', local_ip), ('remote_ip', 'REMOTEIP', server_ip)):
        parts = [re.search(r'^#define ' + macro + str(i) + r'\s+(\d+)\s*$', header, re.MULTILINE)
                 for i in range(1, 5)]
        if any(parts):
            require(all(parts), 'Incomplete compiled BIOS IP constants')
            actual = '.'.join(p[1] for p in parts)
        else:
            match = re.search(name + r'\[4\]\s*=\s*\{(\d+,\s*\d+,\s*\d+,\s*\d+)\}', source)
            require(match, 'Cannot identify static BIOS IP; enable ETH_DYNAMIC_IP')
            actual = '.'.join(p.strip() for p in match[1].split(','))
        require(actual == expected, f'Static BIOS {name} is {actual}, requested {expected}; rebuild with dynamic IP support')
    return []


def wait_linux_login(port, timeout):
    output = port.wait(r'buildroot login:\s*|litex>\s*|Kernel panic - not syncing', timeout)
    require(re.search(r'buildroot login:\s*$', output),
            'Netboot returned to BIOS or Linux panicked; inspect the UART log')


def validate_timing_coverage(report):
    for check in ('no_clock', 'unconstrained_internal_endpoints'):
        counts = re.findall(r'checking ' + check + r'\s+\((\d+)\)', report)
        require(counts and all(int(count) == 0 for count in counts),
                f'Final timing coverage is missing or incomplete: {check}')


def validate_network_delta(before, after, lldp_drops=0):
    for key in ('rx_errors', 'tx_errors', 'tx_dropped'):
        require(after[key] == before[key], f'Network counter increased: {key}')
    delta = after['rx_dropped'] - before['rx_dropped']
    require(delta == lldp_drops,
            f'Unexplained RX drops: {delta}, traced LLDP protocol discards: {lldp_drops}')


class DropTrace:
    """Private trace instance: account only observed unhandled LLDP frames."""
    def __init__(self, port):
        self.port = port
        self.path = '/tmp/raptor-drop-' + os.urandom(8).hex()
        self.instance = self.path + '/instances/' + self.path.rsplit('/', 1)[-1]
        self.started = False
        self.mounted = False
        self.created = False
        self.enabled = False

    def __enter__(self):
        return self

    def start(self):
        self.port.command(f'mkdir {self.path}')
        self.started = True
        self.port.command(f'mount -t tracefs tracefs {self.path}')
        self.mounted = True
        self.port.command(f'mkdir {self.instance}')
        self.created = True
        event = self.instance + '/events/skb/kfree_skb'
        fmt = self.port.command('cat ' + event + '/format')
        reason = re.search(r'\{\s*(\d+),\s*"UNHANDLED_PROTO"\s*\}', fmt)
        require(reason, 'Kernel does not expose UNHANDLED_PROTO drop reason')
        self.port.command(f"echo 'reason == {reason[1]}' > {event}/filter && echo 1 > {event}/enable")
        self.enabled = True

    def sample(self, extra=''):
        # Bracket the statistics read with two trace snapshots. Retry if an
        # event crosses the sample boundary, so it cannot cancel an unrelated
        # RX drop inside the measured interval.
        trace = self.instance + '/trace'
        for attempt in range(3):
            output = self.port.command(f'cat {trace}; cat /proc/net/dev; cat {trace}' + extra)
            totals = re.findall(r'entries-in-buffer/entries-written:\s*(\d+)/(\d+)', output)
            require(len(totals) == 2, 'Missing drop trace snapshots')
            require(all(a == b for a, b in totals), 'Drop trace overflow; cannot account for RX discards')
            if totals[0] == totals[1]:
                break
        else:
            raise RuntimeError('Unstable drop trace sample boundary')
        # Trace includes only protocol-unhandled events, not normal TX frees.
        final_trace = output.rsplit('# tracer:', 1)[-1]
        events = re.findall(r'protocol=(\d+) location=\S+ reason: UNHANDLED_PROTO', final_trace)
        count = sum(protocol == '35020' for protocol in events)
        return network_stats(output), count

    def __exit__(self, kind, value, traceback):
        if not self.started:
            return
        commands = []
        if self.enabled:
            commands.append(f'echo 0 > {self.instance}/events/skb/kfree_skb/enable')
        if self.created:
            commands.append(f'rmdir {self.instance}')
        if self.mounted:
            commands.append(f'umount {self.path}')
        commands.append(f'rmdir {self.path}')
        self.port.command(' && '.join(commands))
        self.port.send('exit')
        self.port.wait(r'buildroot login:\s*', 30)


class Flow:
    def __init__(self, args):
        self.args = args
        self.root = args.root.resolve()
        self.work = self.root / f'rv{args.xlen}' / 'netboot'
        self.make_args = list(args.make_args)
        require(all('=' in a and not a.startswith('-') for a in self.make_args), 'Invalid Make profile arguments')
        for index, value in enumerate(self.make_args):
            if value.startswith('VIVADO=') and args.action in ('check', 'build', 'load', 'run', 'test'):
                self.make_args[index] = 'VIVADO=' + vivado(value.split('=', 1)[1])
        self.context = json.loads(self.make('netboot-flow-context', capture=True).stdout)
        require(int(self.context['xlen']) == args.xlen, 'Profile XLEN mismatch')
        for address in (args.server_ip, args.host_ip):
            ip = ipaddress.IPv4Address(address)
            require(not (ip.is_unspecified or ip.is_multicast or ip.is_loopback), 'Invalid board-facing address')
            network = ipaddress.IPv4Network(address + '/24', strict=False)
            require(ip not in (network.network_address, network.broadcast_address), 'Invalid /24 host address')
        require(args.server_ip != args.host_ip, 'BIOS and Linux host addresses must differ')

    def make(self, target, capture=False):
        return execute(['make', '--no-print-directory', '-s', '-C', LITEX, target, *self.make_args], capture)

    def gate(self, building=False):
        self.idle_output()
        report = Path(self.context['soc']) / 'gateware/mlk_cu08_ku15p_timing.rpt'
        require(report.is_file(),
                'No final timing report; build this exact profile successfully before loading')
        validate_timing_coverage(report.read_text())
        self.make('fpga-bitstream-current')
        self.make('fpga-timing-ok')
        if not building:
            receipt = self.work / 'build.json'
            require(receipt.is_file(), 'No completed workflow build receipt; run the matching -build target')
            record = json.loads(receipt.read_text())
            require(record['source'] == source_identity(self.make_args), 'Sources changed since workflow build')
            require(record['bit_sha256'] == self.bit_hash(), 'Bitstream changed since workflow build')

    def bit_hash(self):
        return netboot.digest((Path(self.context['soc']) / 'gateware/mlk_cu08_ku15p.bit').read_bytes())

    def idle_output(self):
        expected = ('--output-dir=' + self.context['soc']).encode()
        for process in Path('/proc').glob('[0-9]*/cmdline'):
            try:
                command = process.read_bytes().split(b'\0')
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
            require(expected not in command, 'Another LiteX build owns this output directory; wait for it to finish')

    def ensure_payload(self):
        payload = Path(self.context['payload'])
        if payload.is_file():
            return
        names = {32: 'linux-riscv-rv32-qemu-rv32-buildroot-v6.18.50',
                 64: 'linux-riscv-rv64-qemu-rv64-fast-buildroot-v6.18.50'}
        linux = LITEX.parents[1] / 'linux'
        require(payload == linux / 'build' / names[self.args.xlen] / 'fw_payload.bin',
                'Custom payload is missing; no automatic download to custom locations')
        target = 'download-rv32gc-fpga' if self.args.xlen == 32 else 'download-rv64gc'
        with lock(self.root / 'release.lock'):
            execute(['make', '-C', linux, target])
        require(payload.is_file(), 'Release target did not produce the fixed profile payload')

    def serial_device(self):
        candidates = [str(p) for p in Path('/dev/serial/by-id').glob('*')
                      if 'MiLianKe' in p.name and 'if01' in p.name]
        device = choose(candidates, self.args.uart, 'NETBOOT_UART')
        require(Path(device).exists(), f'UART missing: {device}')
        return str(Path(device).resolve())

    def interface(self):
        links = json.loads(execute(['ip', '-j', '-4', 'addr'], True).stdout)
        routes = json.loads(execute(['ip', '-j', '-4', 'route', 'show', 'default'], True).stdout)
        routes += json.loads(execute(['ip', '-j', '-6', 'route', 'show', 'default'], True).stdout)
        uplinks = {r.get('dev') for r in routes}
        candidates = [p['ifname'] for p in links if p['ifname'] not in uplinks and any(
            a.get('local') in (self.args.host_ip, self.args.server_ip) for a in p.get('addr_info', []))]
        if not candidates:
            candidates = [p['ifname'] for p in links if p['ifname'] not in uplinks
                          and (Path('/sys/class/net') / p['ifname'] / 'device').exists()
                          and 'LOWER_UP' in p.get('flags', [])]
        name = choose(candidates, self.args.interface, 'NETBOOT_INTERFACE')
        require(name not in uplinks and name != 'lo', 'Refusing to modify/use the default-route interface')
        matches = [p for p in links if p['ifname'] == name]
        require(len(matches) == 1, f'Interface missing: {name}')
        current = matches[0]
        link = json.loads(execute(['ip', '-j', 'link', 'show', 'dev', name], True).stdout)[0]
        current['address'] = link['address']
        return name, current

    def host(self, restore=False):
        state = self.root / 'host-state.json'
        with lock(self.root / 'host.lock'):
            if restore:
                if not state.exists():
                    print('No saved host setup; nothing changed')
                    return
                old = json.loads(state.read_text())
                require(not self.args.interface or self.args.interface == old['interface'], 'Host state belongs to another interface')
                self.args.interface = old['interface']
                name, current = self.interface()
                require(name == old['interface'], 'Host state belongs to another interface')
                require(current['address'] == old['mac'], 'Interface identity changed')
                present = {a['local'] + '/' + str(a['prefixlen']) for a in current.get('addr_info', [])}
                if old['managed'] == 'yes' or not old['was_up']:
                    require(present <= set(old.get('original_addresses', []) + old['added']),
                            'New external IPv4 configuration detected; refusing to restore management/link state')
                if old.get('dhcp'):
                    pid = old['dhcp']['pid']
                    process = Path('/proc') / str(pid)
                    if process.exists():
                        require((process / 'cmdline').read_bytes().hex() == old['dhcp']['command'],
                                'DHCP PID identity changed; refusing to stop another process')
                        require((process / 'stat').read_text().split()[21] == old['dhcp']['start'], 'DHCP PID was reused')
                        execute(['sudo', 'kill', '-TERM', str(pid)])
                elif old.get('dhcp_intent'):
                    # A launch interrupted before PID capture is deliberately not
                    # guessed at: retain the journal for explicit inspection.
                    require(not Path(old['dhcp_intent']).exists(),
                            'DHCP launch interrupted before identity capture; inspect the recorded pidfile before restoring')
                for address in old['added']:
                    present = {a['local'] + '/' + str(a['prefixlen']) for a in current.get('addr_info', [])}
                    if address in present:
                        execute(['sudo', 'ip', 'addr', 'del', address, 'dev', name])
                if old['managed'] == 'yes':
                    execute(['sudo', 'nmcli', 'device', 'set', name, 'managed', 'yes'])
                if not old['was_up']:
                    execute(['sudo', 'ip', 'link', 'set', name, 'down'])
                state.unlink()
                print('Restored only the addresses/management changed by this workflow')
                return
            name, current = self.interface()
            if state.exists():
                previous = json.loads(state.read_text())
                require(previous['interface'] == name and previous['mac'] == current['address'], 'Another interface setup is recorded')
                require(previous.get('complete'), 'Recorded setup is incomplete; restore and retry')
                expected = {self.args.server_ip, self.args.host_ip}
                require(expected <= {a['local'] for a in current.get('addr_info', [])}, 'Recorded setup is incomplete; restore and retry')
                print('Setup already recorded; restore before changing configuration')
                return
            managed = execute(['nmcli', '-g', 'GENERAL.NM-MANAGED', 'device', 'show', name], True).stdout.strip()
            require(managed in ('yes', 'no'), 'Cannot determine NetworkManager ownership')
            existing = {a['local'] + '/' + str(a['prefixlen']) for a in current.get('addr_info', [])}
            added = [ip + '/24' for ip in (self.args.server_ip, self.args.host_ip) if ip + '/24' not in existing]
            require(managed != 'yes' or not existing, 'Managed interface already has IPv4 state; configure the dedicated interface explicitly')
            save(state, {'interface': name, 'mac': current['address'], 'managed': managed,
                         'was_up': 'UP' in current.get('flags', []), 'added': [], 'original_addresses': sorted(existing)})
            if managed == 'yes':
                execute(['sudo', 'nmcli', 'device', 'set', name, 'managed', 'no'])
            for address in added:
                # Journal intent first, so interruption cannot leave an unrecorded addition.
                record = json.loads(state.read_text())
                record['added'].append(address)
                save(state, record)
                execute(['sudo', 'ip', 'addr', 'add', address, 'dev', name])
            execute(['sudo', 'ip', 'link', 'set', name, 'up'])
            processes = execute(['ps', '-eo', 'args='], True).stdout.splitlines()
            shared = False
            for line in processes:
                if not line.split() or Path(line.split()[0]).name != 'dnsmasq':
                    continue
                words = shlex.split(line)
                if words and Path(words[0]).name == 'dnsmasq':
                    shared |= ('--listen-address=' + self.args.host_ip in words or '--interface=' + name in words) and any(
                        word.startswith('--dhcp-range=') for word in words)
            if not shared:
                daemon = shutil.which('dnsmasq') or '/usr/sbin/dnsmasq'
                require(Path(daemon).is_file(), 'Install dnsmasq or provide a DHCP service, then restore/retry')
                pidfile = self.root / ('netboot-dnsmasq-' + os.urandom(8).hex() + '.pid')
                require(not pidfile.exists() and not pidfile.is_symlink(), 'Existing DHCP pidfile needs inspection')
                network = ipaddress.IPv4Network(self.args.host_ip + '/24', strict=False)
                require(ipaddress.IPv4Address(self.args.host_ip) not in (network.network_address, network.broadcast_address), 'Invalid DHCP host address')
                require(int(ipaddress.IPv4Address(self.args.host_ip)) - int(network.network_address) < 10, 'Host address overlaps default DHCP pool')
                record = json.loads(state.read_text())
                record['dhcp_intent'] = str(pidfile)
                save(state, record)
                execute(['sudo', daemon, '--conf-file=/dev/null', '--no-hosts', '--port=0', '--bind-interfaces',
                         '--interface=' + name, '--listen-address=' + self.args.host_ip,
                         f'--dhcp-range={network.network_address + 10},{network.network_address + 200},255.255.255.0,1h',
                         '--dhcp-option=3', '--dhcp-option=6', '--pid-file=' + str(pidfile),
                         '--dhcp-leasefile=' + str(self.root / 'netboot-dnsmasq.leases')])
                pid = int(pidfile.read_text().strip())
                process = Path('/proc') / str(pid)
                record = json.loads(state.read_text())
                record['dhcp'] = {'pid': pid, 'command': (process / 'cmdline').read_bytes().hex(),
                                  'start': (process / 'stat').read_text().split()[21]}
                save(state, record)
            record = json.loads(state.read_text())
            record['complete'] = True
            save(state, record)
            print('Dedicated addresses prepared; no default route, NAT or firewall rules changed')
            print('Matching DHCP service reused or local-only DHCP started; Internet gateway/DNS are separate')

    def prepare_bundle(self):
        with lock(self.work / 'bundle.lock'):
            path = bundle(self.context, self.work / 'bundles')
        print(f'BUNDLE={path}')
        return path

    def deployment(self, path):
        record = netboot.verify_bundle(path)
        relative = Path('raptor-netboot') / f'rv{self.args.xlen}' / path.name
        boot = json.loads((path / 'boot.json').read_text())
        served = {str(relative / name) if name != 'addr' else name: value for name, value in boot.items()}
        return relative, (json.dumps(served, indent=2) + '\n').encode(), record

    def serve(self):
        self.interface()
        path = self.prepare_bundle()
        relative, boot, _ = self.deployment(path)
        root = self.args.tftp_root.resolve()
        require(root == Path('/srv/tftp'), 'Only the dedicated /srv/tftp deployment root is supported')
        destination = root / relative
        for parent in [root, *list(destination.parents)[:-1], destination]:
            require(not parent.is_symlink(), f'Refusing symlink deployment: {parent}')
        with lock(self.root / 'tftp.lock'):
            execute(['sudo', 'install', '-d', '-m', '0755', destination])
            for name in ('fw_payload.bin', 'soc.dtb', 'stage0.bin'):
                target = destination / name
                require(not target.is_symlink(), 'Refusing a symlink served file')
                if target.exists():
                    require(netboot.digest(target.read_bytes()) == netboot.digest((path / name).read_bytes()), 'Existing served data differs')
                else:
                    execute(['sudo', 'install', '-m', '0444', path / name, target])
            manifest = self.work / 'served-boot.json'
            manifest.write_bytes(boot)
            target = destination / 'boot.json'
            require(not target.exists() or target.read_bytes() == boot, 'Existing served manifest differs')
            require(not target.is_symlink(), 'Refusing a symlink manifest')
            execute(['sudo', 'install', '-m', '0444', manifest, target])
        try:
            require(tftp_get(self.args.server_ip, str(relative / 'boot.json')) == boot, 'Served manifest mismatch')
        except (OSError, RuntimeError) as exc:
            listeners = execute(['ss', '-H', '-lun', 'sport = :69'], True).stdout.strip()
            require(not listeners, f'UDP/69 is occupied but does not serve this bundle: {exc}; existing daemon untouched')
            daemon = shutil.which('in.tftpd') or '/usr/sbin/in.tftpd'
            require(Path(daemon).is_file(), 'Install tftpd-hpa before starting this service')
            print('Starting foreground TFTP; keep this terminal open. Ctrl-C stops this service.', flush=True)
            execute(['sudo', daemon, '--listen', '--foreground', '--ipv4', '--address',
                     self.args.server_ip + ':69', '--secure', '--blocksize', '512', root])
            return
        print('PASS: existing TFTP service serves the verified, namespaced bundle')

    @contextlib.contextmanager
    def console(self):
        device = self.serial_device()
        self.work.mkdir(parents=True, exist_ok=True)
        # OS serial exclusive lock is shared across profiles, not only one output directory.
        port = Console(device, self.work / f'console-{time.time_ns()}.log')
        try:
            yield port
        finally:
            port.close()

    def boot(self):
        self.gate()
        path = self.prepare_bundle()
        relative, boot, _ = self.deployment(path)
        require(tftp_get(self.args.server_ip, str(relative / 'boot.json')) == boot, 'Run serve for this exact bundle first')
        with self.console() as port:
            load_to_bios(port, lambda: self.make('fpga-load'))
            # BIOS IPs are independent of Linux DHCP. Configure them explicitly
            # using the compiled BIOS commands, with no gateware rebuild needed.
            for command in bios_ip_commands(Path(self.context['soc']), self.args.server_ip):
                port.send(command)
                reply = port.wait(r'litex>\s*', 20)
                require('Command not found' not in reply, 'BIOS lacks Ethernet IP commands')
            port.send('netboot ' + str(relative / 'boot.json'))
            wait_linux_login(port, self.args.timeout)
            port.send('root')
            port.wait(r'(?:\r*\n)# ', 60)
            session = os.urandom(16).hex()
            port.command("printf '%s\\n' " + session + ' > /tmp/raptor-netboot-session')
            port.send('exit')
            port.wait(r'buildroot login:\s*', 30)
        save(self.work / 'boot.json', {'bundle': path.name, 'time': time.time(),
                                      'session': session,
                                      'bit_sha256': netboot.digest((Path(self.context['soc']) / 'gateware/mlk_cu08_ku15p.bit').read_bytes())})
        print('PASS: uninterrupted Linux initialization reached login; serial released')

    def test(self):
        self.gate()
        boot_record = self.work / 'boot.json'
        require(boot_record.exists(), 'Run this profile successfully before testing')
        require(json.loads(boot_record.read_text())['bit_sha256'] == netboot.digest(
            (Path(self.context['soc']) / 'gateware/mlk_cu08_ku15p.bit').read_bytes()), 'Boot record is stale')
        expected = bytes(range(256)) * 4096
        expected_hash = hashlib.sha256(expected).hexdigest()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/test.bin':
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(expected)))
                self.end_headers()
                self.wfile.write(expected)
        self.interface()
        server = http.server.HTTPServer((self.args.host_ip, 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with self.console() as port, DropTrace(port) as drops:
                port.send('')
                prompt = port.wait(r'buildroot login:\s*|(?:\r*\n)# ', 20)
                if 'buildroot login:' in prompt:
                    port.send('root')
                    port.wait(r'(?:\r*\n)# ', 60)
                session = port.command('cat /tmp/raptor-netboot-session')
                require(json.loads(boot_record.read_text())['session'] in session, 'Board was rebooted/replaced since run')
                info = port.command('uname -m; ip -4 addr show eth0')
                require(f'riscv{self.args.xlen}' in info, 'Running Linux XLEN differs')
                match = re.search(r'inet (\d+\.\d+\.\d+\.\d+)/', info)
                require(match, 'Linux has no IPv4 lease')
                address = match[1]
                require(ipaddress.IPv4Address(address) in ipaddress.IPv4Network(self.args.host_ip + '/24', strict=False)
                        and address != self.args.host_ip, 'Linux lease is not on the dedicated LAN')
                drops.start()
                before, lldp_before = drops.sample()
                port.command('ping -c 5 ' + self.args.host_ip)
                execute(['ping', '-I', self.args.host_ip, '-c', '5', '-W', '3', address])
                output = port.command(f'wget -q -O /tmp/raptor-netboot-test.bin http://{self.args.host_ip}:{server.server_port}/test.bin && sha256sum /tmp/raptor-netboot-test.bin')
                require(expected_hash in output, 'HTTP data checksum mismatch')
                with socket.socket() as receiver:
                    receiver.bind((self.args.host_ip, 0))
                    receiver.listen(1)
                    receiver.settimeout(120)
                    received = bytearray()
                    errors = []
                    def receive():
                        try:
                            connection, peer = receiver.accept()
                            with connection:
                                require(peer[0] == address, 'Unexpected upload peer')
                                connection.settimeout(120)
                                while len(received) < len(expected):
                                    chunk = connection.recv(min(65536, len(expected) - len(received)))
                                    if not chunk:
                                        break
                                    received.extend(chunk)
                        except Exception as exc:
                            errors.append(str(exc))
                    upload = threading.Thread(target=receive, daemon=True)
                    upload.start()
                    port.command(f'nc -w 5 {self.args.host_ip} {receiver.getsockname()[1]} < /tmp/raptor-netboot-test.bin', 150)
                    upload.join(130)
                    require(not upload.is_alive() and not errors and received == expected,
                            f'TCP upload verification failed: {errors}, {len(received)} bytes')
                after, lldp_after = drops.sample('; cat /proc/interrupts; ip route; cat /etc/resolv.conf')
                validate_network_delta(before, after, lldp_after - lldp_before)
                for key in ('rx_bytes', 'tx_bytes'):
                    require(after[key] - before[key] >= len(expected), f'Insufficient traffic: {key}')
                if self.args.internet:
                    port.command('wget -O /tmp/raptor-internet-test.html http://example.com/', 120)
            save(self.work / 'test.json', {'xlen': self.args.xlen, 'address': address,
                                          'download_bytes': len(expected), 'upload_bytes': len(received), 'sha256': expected_hash,
                                          'before': before, 'after': after, 'boot': json.loads(boot_record.read_text()),
                                          'lldp_protocol_discards': lldp_after - lldp_before,
                                          'internet': self.args.internet, 'time': time.time()})
        finally:
            server.shutdown()
            server.server_close()
            worker.join()
        print('PASS: Linux XLEN, bidirectional ping and 1 MiB HTTP/TCP roundtrip checksum')

    def run(self):
        action = self.args.action
        if action == 'info':
            print(json.dumps(self.context, indent=2))
        elif action == 'check':
            require(importlib.util.find_spec('serial') is not None, 'Install pyserial in NETBOOT_PYTHON environment')
            for tool in ('verilator', 'dtc', 'fdtget', self.context['cross'] + 'gcc', self.context['cross'] + 'nm', self.context['cross'] + 'objcopy'):
                require(shutil.which(tool), f'Missing tool: {tool}')
            require(Path(self.context['payload']).is_file(), 'Missing release: run the paired -build target to acquire the default payload, or provide the custom release')
            print('UART=' + self.serial_device())
            print('INTERFACE=' + self.interface()[0])
            print('PASS: preflight only; not a bitstream/network acceptance result')
        elif action == 'build':
            self.idle_output()
            self.ensure_payload()
            before = source_identity(self.make_args)
            self.make('fpga-build')
            self.gate(building=True)
            require(before == source_identity(self.make_args), 'Sources changed during build; receipt withheld, rebuild stable sources')
            self.prepare_bundle()
            save(self.work / 'build.json', {'source': before, 'bit_sha256': self.bit_hash(), 'time': time.time()})
        elif action == 'bundle':
            self.prepare_bundle()
        elif action == 'load':
            self.gate()
            with self.console():
                self.make('fpga-load')
        elif action == 'serve':
            self.serve()
        elif action == 'run':
            self.boot()
        elif action == 'test':
            self.test()
        elif action.startswith('host-'):
            self.host(action == 'host-restore')
        elif action == 'console':
            with self.console() as port:
                import select
                while True:
                    readable, _, _ = select.select([sys.stdin, port.port], [], [], 0.2)
                    if sys.stdin in readable:
                        text = sys.stdin.readline()
                        if not text:
                            break
                        port.send(text.rstrip('\n'))
                    if port.port in readable:
                        data = port.port.read(max(1, port.port.in_waiting))
                        port.log.write(data)
                        print(data.decode(errors='replace'), end='', flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('info', 'check', 'build', 'bundle', 'load', 'serve', 'run', 'test', 'console', 'host-setup', 'host-restore'))
    parser.add_argument('--xlen', type=int, choices=(32, 64), required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--interface', default='')
    parser.add_argument('--uart', default='')
    parser.add_argument('--server-ip', default='192.168.1.100')
    parser.add_argument('--host-ip', default='192.168.50.1')
    parser.add_argument('--tftp-root', type=Path, default=Path('/srv/tftp'))
    parser.add_argument('--timeout', type=int, default=2400)
    parser.add_argument('--internet', action='store_true')
    arguments = list(sys.argv[1:] if argv is None else argv)
    separator = arguments.index('--')
    args = parser.parse_args(arguments[:separator])
    args.make_args = arguments[separator + 1:]
    flow = Flow(args)
    if args.action in ('check', 'info', 'serve') or args.action.startswith('host-'):
        flow.run()
    else:
        with lock(flow.work / 'workflow.lock'):
            flow.run()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Interrupted; serial released. Use host-restore for recorded host changes.', file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
