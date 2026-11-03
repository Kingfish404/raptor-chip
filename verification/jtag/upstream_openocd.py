#!/usr/bin/env python3
"""Translate upstream port command spelling for OpenOCD 0.12 compatibility."""
import argparse
import os

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--openocd', required=True)
args, command = ap.parse_known_args()
for index, word in enumerate(command):
    if index and command[index - 1] in ('--command', '-c'):
        for name in ('gdb', 'tcl', 'telnet'):
            prefix = name + ' port '
            if word.startswith(prefix):
                command[index] = name + '_port ' + word[len(prefix):]
                break
os.execvp(args.openocd, [args.openocd] + command)
