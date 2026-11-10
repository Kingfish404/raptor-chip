# Public tree guard

Enable the repository hooks from the checkout root:

```sh
git config core.hooksPath tools/git-hooks
```

The executable Python 3 hooks run `tools/check_public_tree.py`. `pre-commit` checks
all index paths and staged blobs, including symlink targets, regardless of dirty
worktree contents. Deleted index entries are absent and submodule paths are checked;
submodule contents must be checked in their own repositories. `commit-msg` checks
the proposed message. `pre-push` checks outgoing commit messages and every changed
path/new blob in each outgoing commit, including intermediate content later removed
and changes against every merge parent. Deleted paths are checked without reading
the removed blobs. Annotated tag text is also checked.

Keep private patterns outside tracked files. Set `RAPT_PUBLIC_DENYLIST` to one UTF-8
file, or pass repeatable `--denylist FILE` arguments for manual checks. Relative
denylist paths are relative to the checkout root. By default the checker also looks
for optional `third_party/tape-out/*/denylist.txt` files. `--no-discover` disables
that lookup. No private input is required on a fresh checkout; the summary states
the number of active patterns, which may be zero.

Each nonblank, noncomment line contains one case-insensitive Python regular
expression. Leading/trailing whitespace is stripped; comments start with `#` after
stripping. Expressions use multiline anchors and search the full decoded contents;
explicit newline expressions work too. Non-UTF-8 blob bytes are preserved with
Python's surrogate-escape decoding. The first match of each pattern is reported
per object/path, with a line number. Numbering follows input order, excluding blank
and comment lines. Invalid explicit paths, unreadable files, invalid UTF-8 denylists,
invalid regexes and Git errors fail the check.

Reports omit patterns and matched text. Paths are JSON-escaped; a matching filename
is identified by its SHA-256 instead of its text. Denylist errors identify the input
number and line without printing the private path or regex. Exit codes are 0 for a
completed check with no findings, 1 for findings and 2 for an incomplete check.

For existing remote refs, push checks cover commits reachable from the new tip but
not the old remote tip, including forced updates. The old tip must resolve locally;
fetch missing history before retrying. New refs conservatively check their entire
reachable history. Deletions have no outgoing content. Non-commit targets and shallow
repositories with outgoing commits fail explicitly. Multiple updates are deduplicated.

Manual checks and synthetic regression tests:

```sh
python3 tools/check_public_tree.py --staged --denylist /path/to/private/denylist.txt
python3 tools/check_public_tree.py --commit-message /path/to/proposed-message.txt
python3 -m unittest discover -s tools/tests -p 'test_public_tree.py'
```

The guard scans Git data, not untracked files, dirty unstaged content, external LFS
payloads or submodule repositories. Commit author/signature metadata is not scanned.
It detects configured patterns, not every form of confidential information. Client
hooks can be bypassed; review and server-side policy remain separate requirements.
