#!/usr/bin/env python3
"""Structural checks on the shipped planar schematic renderer."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "docs/assets/js/uarch-view.js"
HOME = ROOT / "docs/_layouts/home.html"
EXPLORE = ROOT / "docs/_layouts/explore.html"
STYLE = ROOT / "docs/assets/css/style.scss"


class UarchView2DTest(unittest.TestCase):
    def test_memory_path_places_axi_adapter_before_l2(self) -> None:
        src = VIEW.read_text(encoding="utf-8")
        self.assertIn('["rapt_bus", "rapt_axi_master"]', src)
        self.assertIn('["rapt_axi_master", "rapt_l2"]', src)
        self.assertIn('["rapt_l2", "soc_pmem"]', src)
        self.assertNotIn('["rapt_l2", "rapt_axi_master"]', src)

    def test_shipped_renderer_is_svg_not_3d(self) -> None:
        src = VIEW.read_text(encoding="utf-8")
        self.assertIn('class: "uarch-diagram"', src)
        self.assertIn("viewBox", src)
        self.assertIn("http://www.w3.org/2000/svg", src)
        self.assertNotIn("yaw", src)
        self.assertNotIn("pitch", src)
        self.assertNotIn("rotate(", src)
        self.assertNotIn("getContext(\"2d\")", src)
        self.assertNotIn("uarch-canvas", src)

    def test_layouts_host_diagram_not_canvas(self) -> None:
        home = HOME.read_text(encoding="utf-8")
        explore = EXPLORE.read_text(encoding="utf-8")
        for text in (home, explore):
            self.assertIn('id="uarch-diagram"', text)
            self.assertNotIn("uarch-canvas", text)
            self.assertNotIn("<canvas", text)
        self.assertIn("Branches do not redirect", home)
        self.assertIn("Branches do not redirect", explore)


class LightCodeThemeTest(unittest.TestCase):
    def test_light_code_surface_is_not_the_dark_panel(self) -> None:
        src = STYLE.read_text(encoding="utf-8")
        light, _, rest = src.partition("@mixin dark-tokens")
        dark = rest.split("}", 1)[0]
        self.assertIn("--pre-bg: #fffdf8;", light)
        self.assertIn("--pre-ink: #1c1a17;", light)
        self.assertIn("--pre-bg: #141821;", dark)
        self.assertIn("--pre-ink: #ece8e1;", dark)
        self.assertIn("color: var(--pre-ink);", src)
        self.assertNotIn("color: var(--term-ink);", src.split("pre,")[1][:400])


if __name__ == "__main__":
    unittest.main()
