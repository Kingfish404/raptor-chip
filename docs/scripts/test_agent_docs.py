#!/usr/bin/env python3
"""Build the real Jekyll site and check its agent-facing outputs offline."""

from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


DOCS = Path(__file__).resolve().parents[1]
ORIGIN = "https://docs.example.test"
LINK = re.compile(r"\]\(([^\s)]+)\)")


def front_matter(text: str) -> tuple[dict[str, str], str]:
    """Read the flat route metadata; leave the full documentation body intact."""
    match = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        return {}, text
    fields = {}
    for line in match[1].splitlines():
        key, separator, value = line.partition(": ")
        if separator:
            fields[key] = value
    return fields, text[match.end():]


def without_link_destinations(text: str) -> str:
    return LINK.sub("](URL)", text).strip()


class AgentDocsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workspace = tempfile.TemporaryDirectory(prefix="raptor-agent-docs-")
        cls.addClassCleanup(cls.workspace.cleanup)
        root = Path(cls.workspace.name)
        cls.sites = []
        bundle = shlex.split(os.environ.get("BUNDLE", "bundle"))
        for index, baseurl in enumerate(("/raptor-chip", "", "/preview/docs")):
            config = root / f"config-{index}.yml"
            config.write_text(f'url: {ORIGIN}\nbaseurl: "{baseurl}"\n', encoding="utf-8")
            output = root / f"site-{index}"
            result = subprocess.run(
                bundle + [
                    "exec", "jekyll", "build", "--disable-disk-cache", "--trace",
                    "--config", f"{DOCS / '_config.yml'},{config}",
                    "--destination", str(output),
                ],
                cwd=DOCS, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            if result.returncode or "YAML Exception" in result.stdout:
                raise RuntimeError(result.stdout)
            cls.sites.append((baseurl, output))
        cls.exports = []
        for path in DOCS.glob("*.txt"):
            metadata, _ = front_matter(path.read_text(encoding="utf-8"))
            if metadata.get("layout") == "markdown":
                cls.exports.append(metadata)
        cls.canonical = [doc for doc in cls.exports if "nav_order" in doc]

    def test_every_document_has_one_index_entry(self) -> None:
        sources = [doc["markdown_source"] for doc in self.canonical]
        self.assertEqual(len(sources), len(set(sources)))
        self.assertEqual(set(sources), {path.name for path in DOCS.glob("*.md")})
        for baseurl, output in self.sites:
            with self.subTest(baseurl=baseurl):
                index = (output / "llms.txt").read_text(encoding="utf-8")
                self.assertTrue(index.startswith("# Raptor\n"))
                self.assertIn("\n> ", index)
                self.assertIn("\n## Documentation\n", index)
                self.assertLess(len(index), 50_000)
                expected = {ORIGIN + baseurl + doc["permalink"] for doc in self.canonical}
                self.assertEqual(set(LINK.findall(index)), expected)
                self.assertEqual(len(LINK.findall(index)), len(self.canonical))

    def test_markdown_preserves_complete_source(self) -> None:
        for baseurl, output in self.sites:
            for doc in self.exports:
                with self.subTest(baseurl=baseurl, page=doc["permalink"]):
                    path = output / doc["permalink"].lstrip("/")
                    markdown = path.read_text(encoding="utf-8")
                    directive, separator, body = markdown.partition("\n\n")
                    self.assertTrue(separator)
                    self.assertTrue(directive.startswith("> "))
                    self.assertIn(f"]({ORIGIN}{baseurl}/llms.txt)", directive)
                    self.assertNotIn("{%", markdown)
                    self.assertNotIn("{{", markdown)
                    self.assertNotIn("<!DOCTYPE", markdown)
                    source = (DOCS / doc["markdown_source"]).read_text(encoding="utf-8")
                    _, source_body = front_matter(source)
                    self.assertTrue(source_body.strip(), "Markdown must contain documentation")
                    self.assertEqual(
                        without_link_destinations(body), without_link_destinations(source_body),
                    )
                    self.assertLess(len(markdown), 50_000, "Split long pages before truncation")

    def test_markdown_links_are_absolute_and_local_targets_exist(self) -> None:
        for baseurl, output in self.sites:
            for doc in self.exports:
                path = output / doc["permalink"].lstrip("/")
                for link in LINK.findall(path.read_text(encoding="utf-8")):
                    with self.subTest(baseurl=baseurl, page=doc["permalink"], link=link):
                        url = urlsplit(link)
                        self.assertIn(url.scheme, ("https", "http"))
                        if url.netloc != urlsplit(ORIGIN).netloc:
                            continue
                        self.assertTrue(url.path.startswith(baseurl + "/"))
                        local = unquote(url.path[len(baseurl):]).lstrip("/")
                        target = output / (local or "index.html")
                        self.assertTrue(target.is_file(), f"Missing local target: {target}")
                        if url.fragment and target.suffix == ".md":
                            html = target.with_suffix("")
                            if html.suffix != ".html":
                                html = html.with_suffix(".html")
                            fragment = unquote(url.fragment)
                            self.assertIn(f'id="{fragment}"', html.read_text(encoding="utf-8"))

    def test_html_discovery_sitemap_and_aliases(self) -> None:
        for baseurl, output in self.sites:
            expected_html = set()
            for doc in self.canonical:
                route = doc["permalink"]
                html_route = "/" if route == "/index.md" else route.removesuffix(".md")
                expected_html.add(ORIGIN + baseurl + html_route)
                path = output / (html_route.lstrip("/") or "index.html")
                html = path.read_text(encoding="utf-8")
                with self.subTest(baseurl=baseurl, page=html_route):
                    self.assertIn('type="text/markdown"', html)
                    self.assertIn(f'href="{ORIGIN}{baseurl}{route}"', html)
                    self.assertIn(f'href="{baseurl}/llms.txt"', html[:html.index("<main")])
                    alias = path.with_suffix(".md")
                    self.assertTrue(alias.is_file(), f"Missing conventional .md alias: {alias}")
            sitemap = ET.parse(output / "sitemap.xml")
            locations = sitemap.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")
            self.assertEqual({node.text for node in locations}, expected_html)
            self.assertEqual(len(locations), len(self.canonical))


if __name__ == "__main__":
    unittest.main()
