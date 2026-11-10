"""Run the real OpenOCD batch path against native simulated JTAG pins, without USB."""

from pathlib import Path
import socket
import threading

from .client import BringupError
from .native_links import OpenOcdTarget, SCRIPTS, SimTarget


class RemotePins:
    def __init__(self, model):
        self.model = model
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen(1)
        self.listener.settimeout(0.1)
        self.client = None
        self.stopping = False
        self.error = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            while not self.stopping:
                try:
                    self.client, _ = self.listener.accept()
                    break
                except socket.timeout:
                    pass
            if self.stopping:
                return
            self.client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.client.settimeout(0.1)
            tdo = 0
            while not self.stopping:
                try:
                    data = self.client.recv(4096)
                except socket.timeout:
                    continue
                if not data:
                    return
                reply = bytearray()
                for char in data:
                    if ord("0") <= char <= ord("7"):
                        tdo = self.model.exchange("B", value=char - ord("0"))
                    elif char == ord("R"):
                        reply.append(ord("1") if tdo else ord("0"))
                    elif char == ord("Q"):
                        return
                    elif char not in b"Bbrstu":
                        raise BringupError(f"unsupported remote-bitbang byte {char}")
                if reply:
                    self.client.sendall(reply)
        except (OSError, BringupError) as error:
            if not self.stopping:
                self.error = str(error)

    def close(self):
        self.stopping = True
        if self.client is not None:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.client.close()
        self.listener.close()
        self.thread.join(timeout=2)


class OpenOcdSimTarget(OpenOcdTarget):
    def __init__(self, executable, image, log, timeout=180, openocd="openocd", trace_dmi=False):
        self.closed = False
        self.model = SimTarget(executable, image, log, timeout)
        self.pins = RemotePins(self.model)
        config = Path(log).with_suffix(".remote.cfg")
        helpers = (SCRIPTS / "tap.cfg").read_text().split("proc rapt_dmi", 1)[1]
        config.write_text("adapter driver remote_bitbang\nremote_bitbang host 127.0.0.1\n"
                          f"remote_bitbang port {self.pins.port}\ntransport select jtag\n"
                          "reset_config none\n"
                          "jtag newtap rapt tap -irlen 5 -expected-id 0x10001913\n"
                          "proc rapt_dmi" + helpers)
        try:
            super().__init__("SIM", Path(log).with_suffix(".openocd.log"), openocd,
                             500, timeout, trace_dmi, config)
        except BaseException:
            self.close()
            raise

    def exchange(self, *args, **kwargs):
        return self.model.exchange(*args, **kwargs)

    def console(self):
        return self.model.console()

    def statistics(self):
        result = self.model.statistics()
        result["transport"] = self.metrics.copy()
        return result

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if hasattr(self, "process"):
                super().close()
        finally:
            self.pins.close()
            self.model.close()
