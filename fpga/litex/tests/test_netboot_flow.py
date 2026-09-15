"""Host-only flow contracts; never load a board or change host networking."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import pty
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import netboot_flow as flow


class NetbootFlowTest(unittest.TestCase):
    def test_unique_devices(self):
        self.assertEqual(flow.choose(['b', 'b'], '', 'UART'), 'b')
        self.assertEqual(flow.choose(['a', 'b'], '/explicit', 'UART'), '/explicit')
        for candidates in ([], ['a', 'b']):
            with self.assertRaises(RuntimeError):
                flow.choose(candidates, '', 'UART')

    def test_lock_excludes_second_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lock'
            with flow.lock(path):
                with self.assertRaises(RuntimeError):
                    with flow.lock(path):
                        pass
            with flow.lock(path):
                pass

    def test_atomic_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'sub/state.json'
            flow.save(path, {'a': 1})
            flow.save(path, {'a': 2})
            self.assertEqual(json.loads(path.read_text()), {'a': 2})

    def test_runtime_edit_does_not_change_hardware_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            litex = root / 'fpga/litex'
            (litex / 'scripts').mkdir(parents=True)
            (root / 'hdl').mkdir()
            (litex / 'Makefile').write_text('fixed build settings')
            rtl = root / 'hdl/core.sv'
            rtl.write_text('module core; endmodule')
            runtime = litex / 'scripts/netboot_flow.py'
            runtime.write_text('old UART reader')
            with patch.object(flow, 'LITEX', litex):
                before = flow.source_identity([])
                runtime.write_text('new UART reader')
                self.assertEqual(before, flow.source_identity([]))
                rtl.write_text('module core; wire changed; endmodule')
                self.assertNotEqual(before, flow.source_identity([]))

    def test_gate_before_load(self):
        item = object.__new__(flow.Flow)
        item.args = argparse.Namespace(action='load')
        item.gate = Mock(side_effect=RuntimeError('timing'))
        item.make = Mock()
        item.console = Mock()
        with self.assertRaisesRegex(RuntimeError, 'timing'):
            item.run()
        item.make.assert_not_called()
        item.console.assert_not_called()

    def test_failed_build_never_packages(self):
        item = object.__new__(flow.Flow)
        item.args = argparse.Namespace(action='build')
        item.make = Mock(side_effect=RuntimeError('route failed'))
        item.idle_output = Mock()
        item.ensure_payload = Mock()
        item.make_args = []
        item.gate = Mock()
        item.prepare_bundle = Mock()
        with self.assertRaises(RuntimeError):
            item.run()
        item.gate.assert_not_called()
        item.prepare_bundle.assert_not_called()

    def test_gate_rejects_missing_or_incomplete_timing_coverage(self):
        good = '1. checking no_clock (0)\n4. checking unconstrained_internal_endpoints (0)\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'gateware').mkdir()
            report = root / 'gateware/mlk_cu08_ku15p_timing.rpt'
            item = object.__new__(flow.Flow)
            item.context = {'soc': str(root)}
            item.idle_output = Mock()
            item.make = Mock()
            for contents in ('All user specified timing constraints are met',
                             good.replace('no_clock (0)', 'no_clock (1)'),
                             good.replace('endpoints (0)', 'endpoints (5)'),
                             good + '1. checking no_clock (2)\n'):
                report.write_text(contents)
                with self.assertRaisesRegex(RuntimeError, 'coverage'):
                    item.gate(building=True)
                item.make.assert_not_called()
            report.write_text(good)
            item.gate(building=True)
            self.assertEqual([call.args[0] for call in item.make.call_args_list],
                             ['fpga-bitstream-current', 'fpga-timing-ok'])

    def test_network_counter_parser(self):
        result = flow.network_stats('noise\n  eth0: 1100000 1 0 0 0 0 0 0 1200000 2 0 0 0 0 0 0\r\n')
        self.assertEqual(result['rx_bytes'], 1100000)
        self.assertEqual(result['tx_bytes'], 1200000)
        with self.assertRaises(RuntimeError):
            flow.network_stats('no interface')

    def test_only_observed_lldp_discards_are_accounted(self):
        before = dict(rx_errors=0, rx_dropped=20, tx_errors=0, tx_dropped=0)
        after = dict(before, rx_dropped=22)
        flow.validate_network_delta(before, after, 2)
        for count in (0, 1, 3):
            with self.assertRaisesRegex(RuntimeError, 'Unexplained'):
                flow.validate_network_delta(before, after, count)
        for key in ('rx_errors', 'tx_errors', 'tx_dropped'):
            with self.assertRaises(RuntimeError):
                flow.validate_network_delta(before, dict(after, **{key: 1}), 2)

    def test_drop_trace_rejects_overflow(self):
        port = Mock()
        observer = flow.DropTrace(port)
        port.command.return_value = ('# tracer: nop\nentries-in-buffer/entries-written: 1/2\n'
                                     'eth0: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n') * 2
        with self.assertRaisesRegex(RuntimeError, 'overflow'):
            observer.sample()
        snapshot = ('# tracer: nop\nentries-in-buffer/entries-written: 2/2\n'
            'protocol=35020 location=__netif_receive_skb_core+0x1 reason: UNHANDLED_PROTO\n'
            'protocol=12345 location=__netif_receive_skb_core+0x1 reason: UNHANDLED_PROTO\n'
            'eth0: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n')
        port.command.return_value = snapshot * 2
        self.assertEqual(observer.sample()[1], 1)
        port.command.return_value = snapshot + snapshot.replace('2/2', '3/3')
        with self.assertRaisesRegex(RuntimeError, 'Unstable'):
            observer.sample()

    def test_drop_trace_cleanup_owns_only_created_resources(self):
        port = Mock()
        observer = flow.DropTrace(port)
        self.assertNotEqual(observer.instance, flow.DropTrace(port).instance)
        port.command.side_effect = [None, RuntimeError('mount failed'), None]
        with self.assertRaisesRegex(RuntimeError, 'mount failed'):
            with observer:
                observer.start()
        self.assertEqual(port.command.call_args.args[0], 'rmdir ' + observer.path)

    def test_tftp_retries_and_duplicate_block(self):
        sock = Mock()
        sock.__enter__ = Mock(return_value=sock)
        sock.__exit__ = Mock(return_value=False)
        first = b'\0\3\0\1' + b'a' * 512
        peer = ('192.168.1.100', 12345)
        sock.recvfrom.side_effect = [TimeoutError(), (first, peer), (first, peer), (b'\0\3\0\2last', peer)]
        with patch.object(flow.socket, 'socket', return_value=sock):
            self.assertEqual(flow.tftp_get(peer[0], 'boot.json'), b'a' * 512 + b'last')
        self.assertEqual(sock.sendto.call_count, 5)

    def test_tftp_unexpected_peer_rejected(self):
        sock = Mock()
        sock.__enter__ = Mock(return_value=sock)
        sock.__exit__ = Mock(return_value=False)
        sock.recvfrom.return_value = (b'\0\3\0\1data', ('192.168.1.101', 1234))
        with patch.object(flow.socket, 'socket', return_value=sock), self.assertRaisesRegex(RuntimeError, 'peer'):
            flow.tftp_get('192.168.1.100', 'boot.json')

    def test_host_restore_preserves_original_addresses(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = object.__new__(flow.Flow)
            item.root = Path(tmp)
            item.args = argparse.Namespace(interface='')
            item.interface = Mock(return_value=('board', {'address': 'aa', 'addr_info': [
                {'local': '192.168.1.100', 'prefixlen': 24}, {'local': '192.168.50.1', 'prefixlen': 24}]}))
            flow.save(item.root / 'host-state.json', {'interface': 'board', 'mac': 'aa', 'managed': 'no',
                      'was_up': True, 'added': ['192.168.50.1/24']})
            with patch.object(flow, 'execute') as execute:
                item.host(restore=True)
                execute.assert_called_once_with(['sudo', 'ip', 'addr', 'del', '192.168.50.1/24', 'dev', 'board'])
                item.host(restore=True)
                self.assertEqual(execute.call_count, 1)

    def test_host_restore_identity_mismatch_is_nonmutating(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = object.__new__(flow.Flow)
            item.root = Path(tmp)
            item.args = argparse.Namespace(interface='')
            item.interface = Mock(return_value=('board', {'address': 'bb'}))
            flow.save(item.root / 'host-state.json', {'interface': 'board', 'mac': 'aa'})
            with patch.object(flow, 'execute') as execute, self.assertRaisesRegex(RuntimeError, 'identity'):
                item.host(restore=True)
            execute.assert_not_called()

    def test_host_setup_journals_before_mutation_and_reuses_dhcp(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = object.__new__(flow.Flow)
            item.root = Path(tmp)
            item.args = argparse.Namespace(interface='board', server_ip='192.168.1.100', host_ip='192.168.50.1')
            current = {'address': 'aa', 'flags': ['UP'], 'addr_info': []}
            item.interface = Mock(return_value=('board', current))
            mutations = []
            def execute(argv, capture=False):
                if argv[0] == 'nmcli':
                    return Mock(stdout='no\n')
                if argv[0] == 'ps':
                    return Mock(stdout="unrelated 'unbalanced shell\n/usr/sbin/dnsmasq --interface=board --dhcp-range=192.168.50.10,192.168.50.200,1h\n")
                mutations.append(argv)
                if argv[:4] == ['sudo', 'ip', 'addr', 'add']:
                    self.assertIn(argv[4], json.loads((item.root / 'host-state.json').read_text())['added'])
                    current['addr_info'].append({'local': argv[4].split('/')[0], 'prefixlen': 24})
                return Mock(stdout='')
            with patch.object(flow, 'execute', side_effect=execute):
                item.host()
                self.assertEqual(len(mutations), 3)
                item.host()
                self.assertEqual(len(mutations), 3)
                record = json.loads((item.root / 'host-state.json').read_text())
                self.assertTrue(record['complete'])
                self.assertNotIn('dhcp', record)
                item.host(restore=True)
                self.assertEqual(len(mutations), 5)

    def test_serve_does_not_hold_workflow_lock(self):
        instance = Mock()
        with patch.object(flow, 'Flow', return_value=instance), patch.object(flow, 'lock') as lock:
            flow.main(['serve', '--xlen', '64', '--root', '/tmp/netboot-test', '--'])
            lock.assert_not_called()
            instance.run.assert_called_once()

    def test_console_real_pty_command_and_exclusion(self):
        import serial
        master, slave = pty.openpty()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                port = flow.Console(os.ttyname(slave), Path(tmp) / 'uart.log')
                try:
                    with self.assertRaises(serial.SerialException):
                        flow.Console(os.ttyname(slave), Path(tmp) / 'other.log')
                    def board():
                        command = b''
                        while not command.endswith(b'\r'):
                            command += os.read(master, 1024)
                        token = flow.re.search(rb'RAPT_[0-9a-f]+', command)[0]
                        os.write(master, b'hello\r\n' + token + b':0\r\r\n# ')
                    worker = threading.Thread(target=board, daemon=True)
                    worker.start()
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertIn('hello', port.command('echo hello', timeout=3))
                    worker.join(3)
                    self.assertFalse(worker.is_alive())
                finally:
                    port.close()
        finally:
            os.close(master)
            os.close(slave)

    def test_bios_static_and_dynamic_ip_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            soc = Path(tmp)
            header = soc / 'software/include/generated/soc.h'
            header.parent.mkdir(parents=True)
            source = soc / 'bios-src/boot.c'
            source.parent.mkdir()
            source.write_text('local_ip[4] = {192, 168, 1, 50}; remote_ip[4] = {192, 168, 1, 100};')
            header.write_text('')
            self.assertEqual(flow.bios_ip_commands(soc, '192.168.1.100'), [])
            with self.assertRaisesRegex(RuntimeError, 'Static BIOS'):
                flow.bios_ip_commands(soc, '192.168.1.101')
            header.write_text('#define REMOTEIP1 10\n#define REMOTEIP2 0\n#define REMOTEIP3 0\n#define REMOTEIP4 1\n')
            with self.assertRaisesRegex(RuntimeError, 'Static BIOS'):
                flow.bios_ip_commands(soc, '192.168.1.100')
            header.write_text('#define ETH_DYNAMIC_IP\n')
            self.assertEqual(flow.bios_ip_commands(soc, '192.168.2.100'),
                             ['eth_local_ip 192.168.2.50', 'eth_remote_ip 192.168.2.100'])

    def test_console_colored_prompt_split_across_reads(self):
        port = object.__new__(flow.Console)
        port.pending = ''
        port.log = io.BytesIO()
        port.port = Mock(in_waiting=1)
        chunks = [b'\x1b[92;', b'1mlitex\x1b[', b'0m> ']
        port.port.read.side_effect = chunks
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(port.wait(r'litex>\s*', 1), 'litex> ')
        self.assertEqual(port.log.getvalue(), b''.join(chunks))

    def test_autoboot_reader_runs_during_load(self):
        port = Mock()
        started, interrupted = threading.Event(), threading.Event()
        port.port.write.side_effect = lambda data: interrupted.set()
        def receive(pattern, timeout, callback, cancel):
            self.assertTrue(started.wait(2))
            callback('Press Q or ESC to abort boot completely')
            callback('Press Q or ESC to abort boot completely\nlitex>')
            return 'litex>'
        port.wait.side_effect = receive
        def load():
            started.set()
            self.assertTrue(interrupted.wait(2), 'Q must be sent while loader is still running')
        flow.load_to_bios(port, load)
        port.port.write.assert_called_once_with(b'Q')
        port.port.reset_input_buffer.assert_called_once()

    def test_failed_loader_cancels_uart_reader(self):
        port = Mock()
        stopped = threading.Event()
        def receive(pattern, timeout, callback, cancel):
            self.assertTrue(cancel.wait(2))
            stopped.set()
            raise RuntimeError('cancelled')
        port.wait.side_effect = receive
        with self.assertRaisesRegex(RuntimeError, 'JTAG failed'):
            flow.load_to_bios(port, Mock(side_effect=RuntimeError('JTAG failed')))
        self.assertTrue(stopped.is_set())

    def test_netboot_failure_does_not_wait_for_full_init_timeout(self):
        port = Mock()
        for output in ('TFTP failed\r\nlitex> ', 'Kernel panic - not syncing'):
            port.wait.return_value = output
            with self.assertRaisesRegex(RuntimeError, 'Netboot returned'):
                flow.wait_linux_login(port, 2400)
        port.wait.return_value = 'normal full init\r\nbuildroot login: '
        flow.wait_linux_login(port, 2400)

    def test_no_receipt_blocks_legacy_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = object.__new__(flow.Flow)
            item.work = Path(tmp)
            item.context = {'soc': tmp}
            item.make = Mock()
            item.idle_output = Mock()
            (Path(tmp) / 'gateware').mkdir()
            (Path(tmp) / 'gateware/mlk_cu08_ku15p_timing.rpt').write_text(
                '1. checking no_clock (0)\n4. checking unconstrained_internal_endpoints (0)\n')
            with self.assertRaisesRegex(RuntimeError, 'receipt'):
                item.gate()

    def test_changed_sources_block_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            item = object.__new__(flow.Flow)
            item.work = Path(tmp)
            item.context = {'soc': tmp}
            item.make = Mock()
            item.make_args = []
            item.idle_output = Mock()
            (Path(tmp) / 'gateware').mkdir()
            (Path(tmp) / 'gateware/mlk_cu08_ku15p_timing.rpt').write_text(
                '1. checking no_clock (0)\n4. checking unconstrained_internal_endpoints (0)\n')
            flow.save(item.work / 'build.json', {'source': 'old'})
            with patch.object(flow, 'source_identity', return_value='new'), self.assertRaisesRegex(RuntimeError, 'Sources changed'):
                item.gate()

    def test_bundle_reuse_and_input_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            context = {'firmware': str(root), 'payload': str(root / 'fw_payload.bin'), 'xlen': '64', 'cross': 'riscv-'}
            record = {'source_sha256': {'a': 'one'}}
            def write(destination, files, provenance):
                destination.mkdir()
                (destination / 'bundle.json').write_text(json.dumps(provenance))
            with patch.object(flow.netboot, 'prepare', return_value=({}, record)), patch.object(
                    flow.netboot, 'write_bundle', side_effect=write) as writer, patch.object(
                    flow.netboot, 'verify_bundle', return_value=record):
                first = flow.bundle(context, root / 'bundles')
                self.assertEqual(first, flow.bundle(context, root / 'bundles'))
                self.assertEqual(writer.call_count, 1)
                record['source_sha256']['a'] = 'two'
                self.assertNotEqual(first, flow.bundle(context, root / 'bundles'))
                self.assertEqual(writer.call_count, 2)

    def test_bundle_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            context = {'firmware': str(root), 'payload': str(root / 'fw_payload.bin'), 'xlen': '32', 'cross': 'riscv-'}
            record = {'a': 1}
            def write(destination, files, provenance):
                destination.mkdir()
            with patch.object(flow.netboot, 'prepare', return_value=({}, record)), patch.object(flow.netboot, 'write_bundle', side_effect=write):
                flow.bundle(context, root / 'bundles')
                with patch.object(flow.netboot, 'verify_bundle', return_value={'a': 2}):
                    with self.assertRaises(RuntimeError):
                        flow.bundle(context, root / 'bundles')

    def test_default_route_interface_rejected(self):
        item = object.__new__(flow.Flow)
        item.args = argparse.Namespace(interface='uplink', host_ip='192.168.50.1', server_ip='192.168.1.100')
        results = [Mock(stdout=json.dumps([{'ifname': 'uplink', 'addr_info': []}])),
                   Mock(stdout=json.dumps([{'dev': 'uplink'}])), Mock(stdout='[]')]
        with patch.object(flow, 'execute', side_effect=results):
            with self.assertRaisesRegex(RuntimeError, 'default-route'):
                item.interface()

    def test_namespaced_tftp_manifest(self):
        item = object.__new__(flow.Flow)
        item.args = argparse.Namespace(xlen=64)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'fingerprint'
            root.mkdir()
            (root / 'boot.json').write_text(json.dumps({'stage0.bin': '0x80000000', 'addr': '0x80000000'}))
            with patch.object(flow.netboot, 'verify_bundle', return_value={}):
                relative, raw, _ = item.deployment(root)
            self.assertEqual(str(relative), 'raptor-netboot/rv64/fingerprint')
            self.assertEqual(json.loads(raw), {'raptor-netboot/rv64/fingerprint/stage0.bin': '0x80000000', 'addr': '0x80000000'})

    def test_command_nonzero_rejected(self):
        port = object.__new__(flow.Console)
        port.send = Mock()
        port.wait = Mock(return_value='\nRAPT_0000000000000000:1\r\r\n')
        with patch.object(flow.os, 'urandom', return_value=b'\0' * 8):
            with self.assertRaises(RuntimeError):
                port.command('false')
            port.wait.return_value = '\nRAPT_0000000000000000:0\r\r\n'
            port.command('true')


if __name__ == '__main__':
    unittest.main()
