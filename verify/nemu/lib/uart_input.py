#!/usr/bin/env python3
"""Test terminal peer: send RX bytes only after the guest's readiness prompts."""
import os
import subprocess
import sys
import time


def main():
    descriptor = next((int(argument.split('=', 1)[1]) for argument in sys.argv[1:]
                       if argument.startswith('--diff-stream-fd=')), None)
    process = subprocess.Popen([os.environ['NEMU_UART_BINARY'], *sys.argv[1:]],
                               pass_fds=(() if descriptor is None else (descriptor,)),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if descriptor is not None:
        os.close(descriptor)
    prompts = [(b'@UART:RX-M@\n', b'KL'), (b'@UART:RX-S@\n', b'\x80\xff')]
    received = b''
    sent = 0
    try:
        while chunk := process.stdout.read1(4096):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            received += chunk
            if sent < len(prompts) and prompts[sent][0] in received:
                time.sleep(0.05)
                process.stdin.write(prompts[sent][1])
                process.stdin.flush()
                sent += 1
                received = b''
            received = received[-64:]
        code = process.wait()
        return code if code else (0 if sent == len(prompts) else 1)
    finally:
        process.stdin.close()
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    sys.exit(main())
