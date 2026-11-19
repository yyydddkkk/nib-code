#!/usr/bin/env python3
"""Regenerate benchmark SVGs from docs/benchmarks/data.json (stdlib only)."""

import json
from pathlib import Path
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif'
WIDTH = 880
LABEL = 124
BAR = 136
# (nib blue, text, muted text, other bars)
PALETTES = {
    "light": ("#1865EE", "#1f2328", "#59636e", "#B4BBC3"),
    "dark": ("#4C8DFF", "#e6edf3", "#9198a1", "#3D444D"),
}


def text(svg, x, y, value, color, bold=False, anchor="start"):
    node = ET.SubElement(svg, "text", {
        "x": str(x), "y": str(y), "fill": color,
        "text-anchor": anchor, "font-weight": "700" if bold else "400",
    })
    node.text = value


def chart(height):
    return ET.Element("svg", {
        "xmlns": "http://www.w3.org/2000/svg", "width": str(WIDTH),
        "height": str(height), "viewBox": f"0 0 {WIDTH} {height}",
        "font-family": FONT, "font-size": "13",
    })


def bars(rows, key, unit, blue, foreground, muted, gray):
    svg = chart(32 * len(rows) + 12)
    maximum = max(row[key] for row in rows)
    span = WIDTH - BAR - 96
    for i, row in enumerate(sorted(rows, key=lambda row: row[key])):
        y = 20 + 32 * i
        nib = row["name"] == "nib"
        width = max(3, row[key] / maximum * span)
        text(svg, LABEL, y + 5, row.get("short", row["name"]), blue if nib else muted, nib, "end")
        ET.SubElement(svg, "rect", {
            "x": str(BAR), "y": str(y - 9), "width": f"{width:.1f}",
            "height": "18", "rx": "3", "fill": blue if nib else gray,
        })
        text(svg, BAR + width + 10, y + 5, f'{row[key]:,} {unit}', blue if nib else foreground, nib)
    return svg


def costs(rows, blue, foreground, muted, gray):
    svg = chart(32 * len(rows) + 52)
    maximum = max(row["codex"] for row in rows)
    start, span = BAR + 70, WIDTH - BAR - 70 - 80
    for i, row in enumerate(sorted(rows, key=lambda row: row["nib"])):
        y = 20 + 32 * i
        left = start + row["nib"] / maximum * span
        right = start + row["codex"] / maximum * span
        text(svg, LABEL, y + 5, row["task"], muted, anchor="end")
        ET.SubElement(svg, "line", {
            "x1": f"{left:.1f}", "x2": f"{right:.1f}", "y1": str(y), "y2": str(y),
            "stroke": gray, "stroke-width": "2",
        })
        for x, color in [(right, gray), (left, blue)]:
            ET.SubElement(svg, "circle", {"cx": f"{x:.1f}", "cy": str(y), "r": "5", "fill": color})
        text(svg, left - 12, y + 5, f'${row["nib"]:.3f}', blue, True, "end")
        text(svg, right + 12, y + 5, f'${row["codex"]:.3f}', foreground)
    y = 32 * len(rows) + 30
    for x, label, color, dot in [(BAR + 6, "nib", blue, blue), (BAR + 66, "Codex CLI", muted, gray)]:
        ET.SubElement(svg, "circle", {"cx": str(x), "cy": str(y - 4), "r": "5", "fill": dot})
        text(svg, x + 12, y, label, color, label == "nib")
    return svg


def versus(comparison, blue, foreground, muted, gray):
    pct = comparison["headline_percent"]
    rows = [
        ("Wall time", comparison["median_wall_seconds"], lambda v: f"{v} s", f'{pct["faster"]}% faster'),
        ("Cost per task", comparison["cost_usd_per_task"], lambda v: f"${v:.3f}", f'{pct["cheaper"]}% cheaper'),
        ("Requests", comparison["median_requests"], lambda v: f"{v}", f'{pct["fewer_requests"]}% fewer'),
        ("Input tokens", comparison["input_tokens_per_task"], lambda v: f"{v // 1000}k", f'{pct["fewer_input_tokens"]}% fewer'),
    ]
    svg = chart(52 * len(rows) + 40)
    span = WIDTH - BAR - 96 - 120
    for i, (label, values, fmt, delta) in enumerate(rows):
        y = 20 + 52 * i
        maximum = max(values.values())
        text(svg, LABEL, y + 16, label, muted, anchor="end")
        for offset, key, color in [(0, "nib", blue), (22, "codex", gray)]:
            width = max(3, values[key] / maximum * span)
            ET.SubElement(svg, "rect", {
                "x": str(BAR), "y": str(y + offset - 7), "width": f"{width:.1f}",
                "height": "14", "rx": "3", "fill": color,
            })
            text(svg, BAR + width + 10, y + offset + 5, fmt(values[key]),
                 blue if key == "nib" else foreground, key == "nib")
        text(svg, WIDTH - 8, y + 16, delta, blue, True, "end")
    y = 52 * len(rows) + 22
    for x, label, color, dot in [(BAR + 6, "nib", blue, blue), (BAR + 66, "Codex CLI", muted, gray)]:
        ET.SubElement(svg, "circle", {"cx": str(x), "cy": str(y - 4), "r": "5", "fill": dot})
        text(svg, x + 12, y, label, color, label == "nib")
    return svg


def main():
    data = json.loads((ROOT / "docs/benchmarks/data.json").read_text())
    output = ROOT / "docs/assets"
    output.mkdir(parents=True, exist_ok=True)
    nib_ten_rss_mb = round(data["current_nib"]["ten_rss_kib"] * 1024 / 1_000_000, 1)
    memory = [
        dict(row, ten_rss_mb=nib_ten_rss_mb) if row["name"] == "nib" else row
        for row in data["footprint"]
    ]
    prompt = [
        dict(row, short="nib (shared)", prompt_tokens=data["current_nib"]["shared_prompt_tokens"])
        if row["name"] == "nib" else row
        for row in data["footprint"]
    ]
    for theme, palette in PALETTES.items():
        charts = {
            "memory": bars(memory, "ten_rss_mb", "MB", *palette),
            "prompt": bars(prompt, "prompt_tokens", "tokens", *palette),
            "cost": costs(data["comparison"]["task_cost_usd"], *palette),
            "versus": versus(data["comparison"], *palette),
        }
        for name, svg in charts.items():
            width, height = map(float, svg.attrib["viewBox"].split()[2:])
            for node in svg:
                if node.tag == "text":
                    assert 0 < float(node.attrib["x"]) < width
                    assert 0 < float(node.attrib["y"]) < height
            ET.indent(svg)
            path = output / f"bench-{name}-{theme}.svg"
            ET.ElementTree(svg).write(path, encoding="utf-8", xml_declaration=True)
            ET.parse(path)


if __name__ == "__main__":
    main()
