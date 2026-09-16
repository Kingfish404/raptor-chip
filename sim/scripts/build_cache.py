#!/usr/bin/env python3
"""Content-address build options and publish a compatible simulator pathname."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    fingerprint = sub.add_parser("fingerprint")
    fingerprint.add_argument("--config", type=Path, required=True)
    fingerprint.add_argument("options", nargs="*")
    publish = sub.add_parser("publish")
    publish.add_argument("source", type=Path)
    publish.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.action == "fingerprint":
        digest = hashlib.sha256()
        digest.update(args.config.read_bytes() if args.config.exists() else b"unconfigured")
        for option in args.options:
            digest.update(b"\0" + option.encode())
        print(digest.hexdigest()[:20])
        return
    source = args.source.resolve(strict=True)
    destination = args.destination.absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() and destination.resolve() == source:
        return
    # Atomic publication does not overwrite an executable inode in use by an
    # existing run. Only this helper's own temporary pathname is cleaned up.
    fd, name = tempfile.mkstemp(prefix=".publish-", dir=destination.parent)
    os.close(fd)
    temporary = Path(name)
    temporary.unlink()
    try:
        temporary.symlink_to(os.path.relpath(source, destination.parent))
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
