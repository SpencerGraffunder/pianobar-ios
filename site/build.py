#!/usr/bin/env python3
"""Render a redirect stub: the downloads hub moved to the user site.

The iOS downloads page now lives at https://spencergraffunder.github.io/
(it is the one site for all projects). This stub only exists so the old
pianobar-ios Pages URL keeps working. The original release-fed hub
renderer lives in this file's git history.

Usage: python3 site/build.py --out _site
"""

import argparse
import pathlib
import sys

REDIRECT = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=https://spencergraffunder.github.io/#ios-apps">
<link rel="canonical" href="https://spencergraffunder.github.io/">
<title>Moved — iOS downloads</title>
<style>body{font:16px/1.6 -apple-system,sans-serif;background:#0d1117;color:#e6edf3;
display:grid;place-items:center;min-height:100vh;margin:0}
a{color:#58a6ff}</style>
</head>
<body>
<p>iOS downloads moved to <a href="https://spencergraffunder.github.io/#ios-apps">
spencergraffunder.github.io</a> — the one site for all projects.</p>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--releases-dir", default="releases")  # accepted, unused
    ap.add_argument("--out", default="_site")
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "index.html").write_text(REDIRECT)
    print(f"wrote {out / 'index.html'} (redirect stub)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
