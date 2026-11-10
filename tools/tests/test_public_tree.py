#!/usr/bin/env python3
"""Exercise public-tree hooks using temporary Git repos and synthetic patterns."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1]
CHECKER = TOOLS / "check_public_tree.py"
HOOKS = TOOLS / "git-hooks"
TOKEN = "synthetic_marker_47"
ZERO = "0" * 40
UNKNOWN = "f" * 40


class PublicTreeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="public-tree-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_") and key != "RAPT_PUBLIC_DENYLIST"
        }
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.rules = self.directory / "rules.txt"
        self.rules.write_text(TOKEN + "\n", encoding="utf-8")
        self.git("init", "--quiet")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        self.git("config", "user.name", "Public Guard Test")
        self.git("config", "user.email", "guard-test@example.invalid")
        self.write("safe.txt", "base\n")
        self.git("add", "--", "safe.txt")
        self.base = self.commit("baseline")

    def command(self, args, data=None, cwd=None, env=None):
        return subprocess.run(
            args, input=data, cwd=cwd or self.repo, env=env or self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def git(self, *args, data=None):
        result = self.command(["git", *args], data=data)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return result.stdout.strip().decode("utf-8")

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self, message):
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def guard(self, *mode, data=None, rules=True, discover=False, env=None):
        args = [sys.executable, str(CHECKER), *mode]
        if rules:
            args += ["--denylist", str(self.rules)]
        if not discover:
            args.append("--no-discover")
        return self.command(args, data=data, env=env)

    def expect(self, result, code):
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        self.assertEqual(result.returncode, code, output)
        self.assertNotIn(TOKEN, output.casefold())
        self.assertEqual(result.stdout, b"")
        return output

    def update(self, new, old, name="main"):
        return f"refs/heads/{name} {new} refs/heads/{name} {old}\n".encode()

    def push(self, new, old):
        return self.guard("--pre-push", data=self.update(new, old))

    def test_index_uses_staged_blobs_in_both_directions(self):
        self.write("safe.txt", TOKEN.upper() + "\n")
        self.git("add", "--", "safe.txt")
        self.write("safe.txt", "clean dirty worktree\n")
        output = self.expect(self.guard("--staged"), 1)
        self.assertIn('index "safe.txt":1: pattern 1', output)
        self.git("add", "--", "safe.txt")
        self.write("safe.txt", TOKEN + "\n")
        self.expect(self.guard("--staged"), 0)

    def test_delete_and_rename_with_spaces_unicode_and_option_prefix(self):
        self.git("mv", "--", "safe.txt", "--name with space \u4e2d.txt")
        self.expect(self.guard("--staged"), 0)
        self.commit("rename file")
        self.git("rm", "--", "--name with space \u4e2d.txt")
        self.expect(self.guard("--staged"), 0)
        tip = self.commit("delete file")
        self.expect(self.push(tip, self.base), 0)

    def test_matching_filename_is_identified_only_by_hash(self):
        self.git("mv", "--", "safe.txt", TOKEN + " name.txt")
        output = self.expect(self.guard("--staged"), 1)
        self.assertIn("path-sha256=", output)
        self.assertIn(":name:1: pattern 1", output)

    def test_filename_newline_tab_and_pathspec_magic_are_literal(self):
        names = ["line\nbreak\tfile.txt", ":(glob)*.txt", "--other.txt"]
        for name in names:
            self.write(name, TOKEN + "\n")
        self.git("--literal-pathspecs", "add", "--", *names)
        output = self.expect(self.guard("--staged"), 1)
        self.assertIn("line\\nbreak\\tfile.txt", output)
        self.assertIn('"--other.txt"', output)
        self.assertIn('":(glob)*.txt"', output)

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks unavailable")
    def test_symlink_target_is_scanned_without_following_link(self):
        (self.repo / "link").symlink_to(TOKEN)
        self.git("add", "--", "link")
        self.expect(self.guard("--staged"), 1)
        (self.repo / "link").unlink()
        (self.directory / "outside.txt").write_text(TOKEN, encoding="utf-8")
        (self.repo / "link").symlink_to("../outside.txt")
        self.git("add", "--", "link")
        self.expect(self.guard("--staged"), 0)

    def test_submodule_path_checked_without_reading_other_repository(self):
        self.git("update-index", "--add", "--cacheinfo", "160000", UNKNOWN, "component x")
        self.expect(self.guard("--staged"), 0)
        self.git("update-index", "--add", "--cacheinfo", "160000", UNKNOWN, TOKEN)
        self.expect(self.guard("--staged"), 1)

    def test_optional_inputs_missing_are_normal(self):
        output = self.expect(self.guard("--staged", rules=False, discover=True), 0)
        self.assertIn("0 patterns", output)

    def test_generic_discovery_uses_only_synthetic_private_file(self):
        self.write("third_party/tape-out/example/denylist.txt", TOKEN + "\n")
        self.write("safe.txt", TOKEN)
        self.git("add", "--", "safe.txt")
        self.expect(self.guard("--staged", rules=False, discover=True), 1)
        self.expect(self.guard("--staged", rules=False), 0)

    def test_environment_denylist_and_repeatable_paths(self):
        self.write("local-rules.txt", "# comment\n\n  " + TOKEN + "  \n")
        env = dict(self.env, RAPT_PUBLIC_DENYLIST="local-rules.txt")
        self.write("safe.txt", TOKEN)
        self.git("add", "--", "safe.txt")
        self.expect(self.guard("--staged", rules=False, env=env), 1)
        self.rules.write_text("unmatched_synthetic_rule\n", encoding="utf-8")
        output = self.expect(self.guard("--staged", env=env), 1)
        self.assertIn("pattern 2", output)

    def test_invalid_explicit_path_regex_and_encoding_are_redacted(self):
        missing = self.directory / TOKEN
        result = self.guard("--staged", "--denylist", str(missing), rules=False)
        self.assertIn("denylist 1", self.expect(result, 2))
        missing.symlink_to(missing)
        result = self.guard("--staged", "--denylist", str(missing), rules=False)
        self.assertIn("denylist 1", self.expect(result, 2))
        self.rules.write_text("# comment\n[" + TOKEN + "\n", encoding="utf-8")
        self.assertIn("line 2: invalid regex", self.expect(self.guard("--staged"), 2))
        self.rules.write_bytes(b"\xff")
        self.assertIn("UTF-8", self.expect(self.guard("--staged"), 2))
        self.rules.write_text(TOKEN + "{9999999999999999999999}\n", encoding="utf-8")
        self.assertIn("invalid regex", self.expect(self.guard("--staged"), 2))
        env = dict(self.env, RAPT_PUBLIC_DENYLIST="")
        self.expect(self.guard("--staged", rules=False, env=env), 2)

    def test_binary_data_and_multiline_patterns_report_line_numbers(self):
        (self.repo / "binary.bin").write_bytes(b"\xff\x00\n" + TOKEN.encode() + b"\x00")
        self.git("add", "--", "binary.bin")
        self.assertIn('"binary.bin":2:', self.expect(self.guard("--staged"), 1))
        self.rules.write_text("^first\\nsecond$\n", encoding="utf-8")
        self.write("safe.txt", "prefix\nFIRST\nSECOND\n")
        self.git("add", "--", "safe.txt")
        self.assertIn('"safe.txt":2:', self.expect(self.guard("--staged"), 1))

    def test_git_errors_and_missing_blobs_fail_closed(self):
        outside = self.directory / "outside"
        outside.mkdir()
        result = self.command(
            [sys.executable, str(CHECKER), "--staged", "--no-discover"], cwd=outside,
        )
        self.assertIn("Git failed", self.expect(result, 2))
        self.git("update-index", "--add", "--cacheinfo", "100644", UNKNOWN, "missing")
        self.assertIn("required blob", self.expect(self.guard("--staged"), 2))

    def test_unmerged_index_fails_explicitly(self):
        oid = self.git("rev-parse", "HEAD:safe.txt")
        self.git("update-index", "--index-info", data=f"100644 {oid} 1\tconflict\n".encode())
        self.assertIn("unmerged", self.expect(self.guard("--staged"), 2))

    def test_proposed_message_is_scanned_and_missing_file_fails(self):
        message = self.directory / "proposed message.txt"
        message.write_text("feat: clean subject\n\n" + TOKEN, encoding="utf-8")
        output = self.expect(self.guard("--commit-message", str(message)), 1)
        self.assertIn("proposed commit message:3: pattern 1", output)
        self.expect(self.guard("--commit-message", str(message) + ".missing"), 2)
        self.expect(self.guard("--commit-message", ""), 2)

    def test_push_detects_intermediate_blob_removed_from_tip(self):
        self.write("temporary.txt", TOKEN)
        self.git("add", "--", "temporary.txt")
        leaked = self.commit("intermediate change")
        self.git("rm", "--", "temporary.txt")
        tip = self.commit("remove intermediate file")
        output = self.expect(self.push(tip, self.base), 1)
        self.assertIn(leaked + ' "temporary.txt"', output)
        self.expect(self.guard("--staged"), 0)

    def test_push_checks_intermediate_commit_messages(self):
        leaked = self.commit("feat: " + TOKEN)
        tip = self.commit("clean tip")
        output = self.expect(self.push(tip, self.base), 1)
        self.assertIn(leaked + " message:1: pattern 1", output)

    def test_git_replace_cannot_hide_a_forbidden_blob(self):
        original = self.git("rev-parse", "HEAD:safe.txt")
        self.write("safe.txt", TOKEN)
        self.git("add", "--", "safe.txt")
        forbidden = self.git("rev-parse", ":safe.txt")
        self.git("replace", forbidden, original)
        self.expect(self.guard("--staged"), 1)

    def test_existing_remote_history_is_excluded(self):
        self.write("old.txt", TOKEN)
        self.git("add", "--", "old.txt")
        remote = self.commit(TOKEN)
        self.git("rm", "--", "old.txt")
        tip = self.commit("remove old content")
        output = self.expect(self.push(tip, remote), 0)
        self.assertIn("1 commits", output)

    def test_new_branch_checks_entire_reachable_history(self):
        inherited = self.commit(TOKEN)
        tip = self.commit("clean tip")
        output = self.expect(self.push(tip, ZERO), 1)
        self.assertIn(inherited + " message", output)
        self.assertIn("3 commits", output)

    def test_forced_update_checks_divergent_commits(self):
        remote = self.commit("remote-only commit")
        self.git("checkout", "--quiet", "-b", "divergent", self.base)
        tip = self.commit(TOKEN)
        output = self.expect(self.push(tip, remote), 1)
        self.assertIn(tip + " message", output)
        self.assertIn("1 commits", output)

    def test_multiple_updates_deduplicate_and_deletions_need_no_old_object(self):
        tip = self.commit("new commit")
        data = self.update(tip, self.base) + self.update(tip, self.base, "other")
        output = self.expect(self.guard("--pre-push", data=data), 0)
        self.assertIn("1 commits", output)
        output = self.expect(self.push(ZERO, UNKNOWN), 0)
        self.assertIn("0 commits", output)
        self.expect(self.guard("--pre-push", data=b""), 0)

    def test_unresolved_revisions_and_bad_push_input_fail(self):
        self.expect(self.push(UNKNOWN, self.base), 2)
        self.expect(self.push(self.base, UNKNOWN), 2)
        self.expect(self.guard("--pre-push", data=b"not an update\n"), 2)
        self.expect(self.push("--bad-option", ZERO), 2)

    def test_shallow_push_fails_but_deletion_is_safe(self):
        (self.repo / ".git/shallow").write_text(self.base + "\n", encoding="ascii")
        self.assertIn("complete local history", self.expect(self.push(self.base, ZERO), 2))
        self.expect(self.push(ZERO, UNKNOWN), 0)

    def test_merge_introduced_blob_is_checked(self):
        self.git("checkout", "--quiet", "-b", "feature")
        self.write("feature.txt", "feature\n")
        self.git("add", "--", "feature.txt")
        self.commit("feature change")
        self.git("checkout", "--quiet", "main")
        self.write("main.txt", "main\n")
        self.git("add", "--", "main.txt")
        self.commit("main change")
        self.git("merge", "--quiet", "--no-ff", "--no-commit", "feature")
        self.write("merge-only.txt", TOKEN)
        self.git("add", "--", "merge-only.txt")
        merged = self.commit("merge changes")
        output = self.expect(self.push(merged, self.base), 1)
        self.assertIn(merged + ' "merge-only.txt"', output)

    def test_annotated_tag_text_and_noncommit_targets(self):
        self.git("tag", "-a", "review", "-m", TOKEN)
        tag = self.git("rev-parse", "review")
        self.assertIn("tag " + tag, self.expect(self.push(tag, ZERO), 1))
        blob = self.git("rev-parse", "HEAD:safe.txt")
        self.expect(self.push(blob, ZERO), 2)

    def test_installed_hooks_block_content_messages_and_push(self):
        self.git("config", "core.hooksPath", str(HOOKS))
        env = dict(self.env, RAPT_PUBLIC_DENYLIST=str(self.rules))
        self.write("safe.txt", TOKEN)
        self.git("add", "--", "safe.txt")
        result = self.command(["git", "commit", "-m", "clean message"], env=env)
        self.expect(result, 1)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        self.write("safe.txt", "clean\n")
        self.git("add", "--", "safe.txt")
        result = self.command(["git", "commit", "-m", TOKEN], env=env)
        self.expect(result, 1)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        result = self.command(["git", "commit", "--quiet", "-m", "clean change"], env=env)
        self.expect(result, 0)
        self.git("config", "core.hooksPath", str(self.directory / "unused-hooks"))
        tip = self.commit(TOKEN)
        result = self.command(
            [str(HOOKS / "pre-push"), "origin", "unused-local-url"],
            data=self.update(tip, self.base), env=env,
        )
        self.expect(result, 1)


if __name__ == "__main__":
    unittest.main()
