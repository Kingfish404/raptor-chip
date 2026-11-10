#!/usr/bin/env python3
"""Check Git index, commit messages and outgoing commits against private regexes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


class GuardError(Exception):
    """An incomplete check must fail without exposing Git or regex input."""


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise GuardError("invalid arguments; use --help for usage")


def is_oid(value):
    return re.fullmatch(rb"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", value) is not None


def is_zero(value):
    return value == b"0" * len(value)


class Git:
    def __init__(self):
        self.env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
        self.command = ["git", "--no-replace-objects"]
        root = self.run("locating the repository", "rev-parse", "--show-toplevel")
        if not root.endswith(b"\n"):
            raise GuardError("invalid repository location")
        self.root = Path(os.fsdecode(root[:-1]))
        self.command += ["-C", str(self.root)]

    def run(self, operation, *args):
        result = subprocess.run(
            self.command + list(args), env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        if result.returncode:
            raise GuardError("Git failed while " + operation)
        return result.stdout

    def commit(self, oid):
        resolved = self.run(
            "resolving a push revision", "rev-parse", "--verify", "--end-of-options",
            oid.decode("ascii") + "^{commit}",
        ).strip()
        if not is_oid(resolved):
            raise GuardError("invalid resolved commit")
        return resolved


def patterns_from(args, root):
    paths = [Path(path) for path in args.denylist]
    configured = os.environ.get("RAPT_PUBLIC_DENYLIST")
    if configured is not None:
        if not configured:
            raise GuardError("RAPT_PUBLIC_DENYLIST is empty")
        paths.append(Path(configured))
    paths = [path if path.is_absolute() else root / path for path in paths]
    if not args.no_discover:
        paths += sorted(root.glob("third_party/tape-out/*/denylist.txt"))
    patterns = []
    seen = set()
    for source, path in enumerate(paths, 1):
        try:
            path = path.resolve()
            if path in seen:
                continue
            seen.add(path)
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError, RuntimeError):
            raise GuardError(f"denylist {source} could not be read as UTF-8") from None
        for line, text in enumerate(lines, 1):
            text = text.strip()
            if not text or text.startswith("#"):
                continue
            try:
                patterns.append(re.compile(text, re.IGNORECASE | re.MULTILINE))
            except (re.error, OverflowError, RecursionError):
                raise GuardError(f"denylist {source}, line {line}: invalid regex") from None
    return patterns


def index_entries(git):
    data = git.run("reading the index", "ls-files", "--stage", "-z")
    entries = []
    for record in data.split(b"\0"):
        if not record:
            continue
        metadata, separator, path = record.partition(b"\t")
        fields = metadata.split()
        if not separator or len(fields) != 3 or not is_oid(fields[1]):
            raise GuardError("invalid index entry")
        mode, oid, stage = fields
        if stage != b"0" or is_zero(oid):
            raise GuardError("unmerged or missing index object")
        entries.append((mode, oid, path))
    return entries


def changed_entries(git, commit):
    data = git.run(
        "reading changed paths", "diff-tree", "--root", "-m", "-r", "--no-commit-id",
        "--no-renames", "--no-ext-diff", "--no-abbrev", "--raw", "-z",
        commit.decode("ascii"), "--",
    )
    records = data.split(b"\0")
    if records.pop() != b"" or len(records) % 2:
        raise GuardError("invalid changed-path records")
    entries = set()
    for index in range(0, len(records), 2):
        fields = records[index].split()
        if len(fields) != 5 or not fields[0].startswith(b":") or not is_oid(fields[3]):
            raise GuardError("invalid changed-path entry")
        entries.add((fields[1], fields[3], records[index + 1]))
    return sorted(entries)


class Checker:
    def __init__(self, git, patterns):
        self.git = git
        self.patterns = patterns
        self.blob_hits = {}
        self.findings = set()
        self.entries = 0
        self.commits = 0

    def hits(self, data):
        text = data.decode("utf-8", errors="surrogateescape")
        result = []
        for number, pattern in enumerate(self.patterns, 1):
            match = pattern.search(text)
            if match:
                result.append((number, text.count("\n", 0, match.start()) + 1))
        return result

    def report(self, label, hits):
        for number, line in hits:
            finding = f"{label}:{line}: pattern {number}"
            if finding not in self.findings:
                self.findings.add(finding)
                print("public-tree: " + finding, file=sys.stderr)

    def text(self, label, data):
        self.report(label, self.hits(data))

    @staticmethod
    def read_blob(process, oid):
        process.stdin.write(oid + b"\n")
        process.stdin.flush()
        fields = process.stdout.readline().split()
        if len(fields) != 3 or fields[0] != oid or fields[1] != b"blob":
            raise GuardError("Git could not read a required blob")
        try:
            size = int(fields[2])
        except ValueError:
            raise GuardError("invalid Git blob size") from None
        if size < 0:
            raise GuardError("invalid Git blob size")
        data = process.stdout.read(size)
        if len(data) != size or process.stdout.read(1) != b"\n":
            raise GuardError("incomplete Git blob")
        return data

    def files(self, revision, entries):
        with subprocess.Popen(
            self.git.command + ["cat-file", "--batch"], env=self.git.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ) as process:
            for mode, oid, path in entries:
                self.entries += 1
                name_hits = self.hits(path)
                if name_hits:
                    identity = "path-sha256=" + hashlib.sha256(path).hexdigest()
                else:
                    identity = json.dumps(os.fsdecode(path), ensure_ascii=True)
                label = revision + " " + identity
                self.report(label + ":name", name_hits)
                # Deleted entries have no new blob; gitlinks name another repository.
                if mode in (b"000000", b"160000"):
                    continue
                if mode not in (b"100644", b"100755", b"120000") or is_zero(oid):
                    raise GuardError("unsupported Git entry")
                if oid not in self.blob_hits:
                    self.blob_hits[oid] = self.hits(self.read_blob(process, oid))
                self.report(label, self.blob_hits[oid])
            process.stdin.close()
            if process.wait():
                raise GuardError("Git failed while reading blobs")

    def tag(self, oid):
        # Annotated tags carry additional public text outside the commit message.
        while self.git.run("reading a push object", "cat-file", "-t", oid.decode()) == b"tag\n":
            data = self.git.run("reading a tag", "cat-file", "tag", oid.decode())
            self.text("tag " + oid.decode(), data)
            header = data.split(b"\n", 1)[0].split()
            if len(header) != 2 or header[0] != b"object" or not is_oid(header[1]):
                raise GuardError("invalid tag target")
            oid = header[1]

    def push(self, data):
        updates = []
        for line in data.splitlines():
            fields = line.split()
            if len(fields) != 4 or not is_oid(fields[1]) or not is_oid(fields[3]):
                raise GuardError("invalid pre-push update")
            if not is_zero(fields[1]):
                updates.append((fields[1], fields[3]))
        if updates and self.git.run(
            "checking repository depth", "rev-parse", "--is-shallow-repository",
        ).strip() != b"false":
            raise GuardError("push checks require complete local history")
        checked = set()
        for local, remote in updates:
            tip = self.git.commit(local)
            exclusions = [] if is_zero(remote) else ["^" + self.git.commit(remote).decode()]
            self.tag(local)
            commits = self.git.run(
                "enumerating outgoing commits", "rev-list", "--reverse", "--topo-order",
                tip.decode(), *exclusions, "--",
            ).splitlines()
            for commit in commits:
                if not is_oid(commit):
                    raise GuardError("invalid outgoing commit")
                if commit in checked:
                    continue
                checked.add(commit)
                self.commits += 1
                raw = self.git.run("reading a commit", "cat-file", "commit", commit.decode())
                _, separator, message = raw.partition(b"\n\n")
                if not separator:
                    raise GuardError("invalid commit object")
                label = "commit " + commit.decode()
                self.text(label + " message", message)
                self.files(label, changed_entries(self.git, commit))


def main(argv=None):
    parser = Parser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true", help="check all index paths and blobs")
    mode.add_argument("--commit-message", metavar="FILE", help="check a proposed commit message")
    mode.add_argument("--pre-push", action="store_true", help="read Git ref updates from stdin")
    parser.add_argument("--denylist", action="append", default=[], metavar="FILE")
    parser.add_argument("--no-discover", action="store_true", help="disable optional discovery")
    try:
        args = parser.parse_args(argv)
        git = Git()
        checker = Checker(git, patterns_from(args, git.root))
        if args.staged:
            checker.files("index", index_entries(git))
        elif args.commit_message is not None:
            checker.text("proposed commit message", Path(args.commit_message).read_bytes())
        else:
            checker.push(sys.stdin.buffer.read())
        print(
            f"public-tree: {checker.entries} entries, {checker.commits} commits, "
            f"{len(checker.patterns)} patterns; {len(checker.findings)} findings",
            file=sys.stderr,
        )
        return 1 if checker.findings else 0
    except GuardError as error:
        print("public-tree: error: " + str(error), file=sys.stderr)
    except (OSError, ValueError):
        print("public-tree: error: could not complete the check", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
