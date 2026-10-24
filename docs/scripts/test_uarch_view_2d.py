#!/usr/bin/env python3
"""Structural checks on the shipped planar schematic renderer."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / "docs/assets/js/explore-view.js"
WIDGET = ROOT / "docs/_includes/architecture-explorer.html"
HOME = ROOT / "docs/_layouts/home.html"
EXPLORE = ROOT / "docs/_layouts/explore.html"
STYLE = ROOT / "docs/assets/css/style.scss"


class UarchView2DTest(unittest.TestCase):
    def test_shipped_renderer_is_svg_not_3d(self) -> None:
        src = VIEW.read_text(encoding="utf-8")
        self.assertIn("class: 'architecture-svg'", src)
        self.assertIn("viewBox", src)
        self.assertIn("http://www.w3.org/2000/svg", src)
        self.assertNotIn("yaw", src)
        self.assertNotIn("pitch", src)
        self.assertNotIn("rotate(", src)
        self.assertNotIn("getContext(\"2d\")", src)
        self.assertNotIn("uarch-canvas", src)

    def test_home_and_explore_share_the_complete_component(self) -> None:
        for layout in (HOME, EXPLORE):
            text = layout.read_text(encoding="utf-8")
            self.assertEqual(text.count("{% include architecture-explorer.html %}"), 1)
            self.assertNotIn('id="uarch-diagram"', text)
        widget = WIDGET.read_text(encoding="utf-8")
        self.assertIn('id="uarch-diagram"', widget)
        self.assertIn("Branches do not redirect", widget)
        self.assertIn("data-cycle-play", widget)
        self.assertIn("data-cycle-step", widget)
        self.assertIn('id="cycle-slider"', widget)
        self.assertIn("Functional connections, not cycle timing", widget)
        self.assertFalse((ROOT / "docs/assets/js/uarch-view.js").exists())


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
