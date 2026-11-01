#!/usr/bin/env python3
"""Render the iOS hub downloads page (_site/index.html) from GitHub Release metadata.

Reads `releases/<repo>.json` files fetched by the site workflow (GitHub
`releases/latest` API payloads; a missing file means "no release yet") and
emits a static page whose download buttons link straight to the release
assets — bare .ipa files, never zip-wrapped Actions artifacts.

Usage: python3 site/build.py --releases-dir releases --out _site
"""

import argparse
import datetime as dt
import html
import json
import pathlib
import sys

APPS = [
    {
        "repo": "SpencerGraffunder/pianobar-ios",
        "name": "pianobar-ios",
        "blurb": "SwiftUI client for pianobar — Last.fm radio in your pocket: "
                 "play, skip, ban, throttle, and love tracks from the grid.",
    },
    {
        "repo": "SpencerGraffunder/key-decoder",
        "name": "KeyDecoder",
        "blurb": "Point the camera at a key on the reference card: perspective "
                 "correction and computer vision read the key's bitting code "
                 "so a locksmith (or you) can cut a copy.",
    },
]

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iOS apps · Spencer Graffunder</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📱</text></svg>">
<style>
  :root {{ color-scheme: dark; }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 2.5rem 1.25rem 4rem;
    background: #0d1117; color: #e6edf3;
    font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }}
  main {{ max-width: 720px; margin: 0 auto; }}
  h1 {{ font-size: 1.9rem; margin: 0 0 .25rem; letter-spacing: -.02em; }}
  .sub {{ color: #8b949e; margin: 0 0 2.25rem; }}
  .card {{
    background: #161b22; border: 1px solid #30363d; border-radius: 12px;
    padding: 1.4rem 1.5rem; margin-bottom: 1.25rem;
  }}
  .card h2 {{ margin: 0 0 .4rem; font-size: 1.25rem; }}
  .card p {{ margin: 0 0 1.1rem; color: #adbac7; }}
  .row {{ display: flex; flex-wrap: wrap; align-items: center; gap: .75rem; }}
  a.btn {{
    display: inline-block; padding: .55rem 1.15rem; border-radius: 8px;
    background: #238636; color: #fff; text-decoration: none; font-weight: 600;
  }}
  a.btn:hover {{ background: #2ea043; }}
  a.alt {{ color: #58a6ff; text-decoration: none; }}
  a.alt:hover {{ text-decoration: underline; }}
  .meta {{ color: #8b949e; font-size: .85rem; }}
  .none {{ color: #8b949e; font-style: italic; }}
  footer {{ margin-top: 2.5rem; color: #8b949e; font-size: .85rem; }}
  footer p {{ margin: .35rem 0; }}
</style>
</head>
<body>
<main>
  <h1>iOS apps</h1>
  <p class="sub">Side-loadable builds, refreshed automatically from each project's
     latest GitHub Release.</p>
{cards}
  <footer>
    <p>Files are plain <code>.ipa</code> — re-sign with
       <a class="alt" href="https://sideloadly.io/">Sideloadly</a> or
       <a class="alt" href="https://sidestore.io/">AltStore</a> using your Apple ID,
       then install. Free Apple IDs re-sign for 7 days at a time.</p>
    <p>Page rebuilt automatically whenever a release is published
       (build <code>{stamp}</code>).</p>
  </footer>
</main>
</body>
</html>
"""

CARD = """  <section class="card">
    <h2>{name}</h2>
    <p>{blurb}</p>
    <div class="row">
      {download}
      <a class="alt" href="https://github.com/{repo}">Repository</a>
      <a class="alt" href="https://github.com/{repo}/releases">All releases</a>
    </div>
    <p class="meta">{meta}</p>
  </section>
"""


def human_size(n: int) -> str:
    mb = n / (1024 * 1024)
    return f"{mb:.1f} MB" if mb >= 1 else f"{n / 1024:.0f} KB"


def render_card(app: dict, releases_dir: pathlib.Path) -> str:
    slug = app["repo"].split("/")[-1]
    path = releases_dir / f"{slug}.json"
    download, meta = "", "No release published yet."
    if path.is_file():
        try:
            rel = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            rel = {}
        ipa = next((a for a in rel.get("assets", []) if a["name"].endswith(".ipa")), None)
        if ipa:
            tag = rel.get("tag_name", "?")
            published = rel.get("published_at", "")
            try:
                when = dt.datetime.strptime(published, "%Y-%m-%dT%H:%M:%SZ")
                published = when.strftime("%b %d, %Y")
            except ValueError:
                pass
            download = (f'<a class="btn" href="{html.escape(ipa["browser_download_url"])}">'
                        f'Download {html.escape(ipa["name"])}</a>')
            meta = f"{html.escape(tag)} · {human_size(ipa.get('size', 0))} · published {html.escape(published)}"
    return CARD.format(
        name=html.escape(app["name"]), blurb=html.escape(app["blurb"]),
        repo=html.escape(app["repo"]), download=download or
        '<span class="none">No release yet</span>', meta=meta,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--releases-dir", default="releases")
    ap.add_argument("--out", default="_site")
    args = ap.parse_args()

    releases_dir = pathlib.Path(args.releases_dir)
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cards = "\n".join(render_card(app, releases_dir) for app in APPS)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    (out / "index.html").write_text(PAGE.format(cards=cards, stamp=stamp))
    print(f"wrote {out / 'index.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
