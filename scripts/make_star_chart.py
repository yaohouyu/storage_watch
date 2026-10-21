#!/usr/bin/env python3
"""Render a GitHub star-history curve into site/assets/stars.svg.

Uses real stargazer timestamps when GH_TOKEN / GITHUB_TOKEN is available.
Before the repository gets its first star it renders a labelled placeholder,
so the README never points at a broken image.

Usage: python3 scripts/make_star_chart.py [owner/repo]
"""
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import urllib.request

REPO = os.environ.get("STAR_CHART_REPO", "yaohouyuterry/storage_watch")
OUT = pathlib.Path(__file__).resolve().parents[1] / "site/assets/stars.svg"


def api(url: str) -> object | None:
    headers = {
        # star+json adds `starred_at`, needed to draw a curve rather than a flat count.
        "Accept": "application/vnd.github.star+json",
        "User-Agent": "storage-watch-star-chart",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
            return json.load(response)
    except Exception:
        return None


def star_timestamps(repo: str) -> list[dt.datetime]:
    stamps: list[dt.datetime] = []
    for page in range(1, 41):  # GitHub caps stargazers at 400 pages
        data = api(f"https://api.github.com/repos/{repo}/stargazers?per_page=100&page={page}")
        if not isinstance(data, list) or not data:
            break
        for item in data:
            if isinstance(item, dict) and item.get("starred_at"):
                stamps.append(dt.datetime.fromisoformat(item["starred_at"].replace("Z", "+00:00")))
        if len(data) < 100:
            break
    return sorted(stamps)


def build_svg(points: list[tuple[dt.datetime, int]], width: int = 900, height: int = 340) -> str:
    left, right, top, bottom = 58, 24, 34, 46
    plot_w, plot_h = width - left - right, height - top - bottom
    font = "-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif"

    if not points:
        return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<rect width="100%" height="100%" rx="16" fill="#0D1411"/>
<text x="{width/2}" y="{height/2-10}" text-anchor="middle" fill="#E8FFF6" font-family="{font}" font-size="22" font-weight="600">等待第一颗星</text>
<text x="{width/2}" y="{height/2+22}" text-anchor="middle" fill="#7FA694" font-family="{font}" font-size="14">github.com/{REPO}</text>
</svg>
'''

    start, end = points[0][0], points[-1][0]
    if end <= start:
        end = start + dt.timedelta(days=1)
    max_stars = max(count for _, count in points)
    y_max = max(5, int(max_stars * 1.15))
    span = (end - start).total_seconds() or 1
    x_of = lambda when: left + plot_w * (when - start).total_seconds() / span
    y_of = lambda count: top + plot_h * (1 - count / y_max)

    line = " ".join(f"{x_of(when):.1f},{y_of(count):.1f}" for when, count in points)
    area = f"{left},{top + plot_h} " + line + f" {x_of(points[-1][0]):.1f},{top + plot_h}"

    grids = []
    for i in range(6):
        value = round(y_max * i / 5)
        y = y_of(value)
        grids.append(
            f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="#26332D"/>'
            f'<text x="{left - 12}" y="{y + 4:.1f}" text-anchor="end" fill="#6E8A7D" font-size="11">{value}</text>'
        )
    labels = []
    for i in range(5):
        when = start + (end - start) * i / 4
        labels.append(
            f'<text x="{x_of(when):.1f}" y="{height - 16}" text-anchor="middle" '
            f'fill="#6E8A7D" font-size="11">{when.strftime("%Y-%m-%d")}</text>'
        )

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<defs>
  <linearGradient id="fill" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#5FD1A8" stop-opacity="0.38"/>
    <stop offset="1" stop-color="#5FD1A8" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="stroke" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#5FD1A8"/><stop offset="1" stop-color="#9FE3C9"/>
  </linearGradient>
</defs>
<rect width="100%" height="100%" rx="16" fill="#0D1411"/>
{''.join(grids)}
<polygon points="{area}" fill="url(#fill)"/>
<polyline points="{line}" fill="none" stroke="url(#stroke)" stroke-width="2.5"
          stroke-linejoin="round" stroke-linecap="round"/>
{''.join(labels)}
<text x="{left}" y="22" fill="#E8FFF6" font-family="{font}" font-size="13" font-weight="600">{max_stars} stars</text>
</svg>
'''


def main() -> None:
    stamps = star_timestamps(REPO)
    points = [(stamps[0], 1)] + [(stamp, i + 1) for i, stamp in enumerate(stamps[1:], start=1)] if stamps else []
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(build_svg(points), encoding="utf-8")
    print(f"wrote {OUT} ({len(stamps)} stars)")


if __name__ == "__main__":
    main()
