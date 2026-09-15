#!/usr/bin/env python3
"""Read-only, order-independent identity of explicit build setting values."""
import hashlib
import json
import sys


def identity(values):
    settings = dict(value.split("=", 1) for value in values)
    return hashlib.sha256(json.dumps(settings, sort_keys=True).encode()).hexdigest()[:20]


if __name__ == "__main__":
    print(identity(sys.argv[1:]))
