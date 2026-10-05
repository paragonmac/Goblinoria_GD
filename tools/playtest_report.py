#!/usr/bin/env python3
"""Build a compact, local HTML report from autonomous playtest observations."""

from __future__ import annotations

import argparse
import html
import json
import os
from pathlib import Path
from urllib.parse import quote


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def observation_files(root: Path) -> list[Path]:
    directory = root / "observations"
    if not directory.is_dir():
        directory = root
    found: list[Path] = []
    for candidate in sorted(directory.iterdir()) if directory.is_dir() else []:
        if not candidate.is_dir():
            continue
        if (candidate / "observation.json").is_file():
            found.append(candidate / "observation.json")
            continue
        manifest = candidate / "manifest.json"
        snapshot = candidate / "snapshot.json"
        if manifest.is_file() or snapshot.is_file():
            found.append(manifest if manifest.is_file() else snapshot)
    if found:
        return found
    return sorted(root.rglob("observation.json")) if root.exists() else []


def load_observation(path: Path) -> tuple[dict, Path]:
    metadata = read_json(path)
    if path.name == "observation.json":
        bundle = path.parent
        snapshot = read_json(bundle / "snapshot.json")
        nested = snapshot.get("playtest_observation", {})
        if isinstance(nested, dict):
            merged = dict(nested)
            merged.update(metadata)
            metadata = merged
    elif path.name == "manifest.json":
        nested = metadata.get("observation", {})
        metadata = nested if isinstance(nested, dict) else metadata
    else:
        metadata = metadata.get("playtest_observation", metadata)
    return metadata, path.parent


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def relative_href(path: Path, output: Path) -> str:
    try:
        relative = os.path.relpath(path, output.parent)
    except ValueError:
        relative = str(path)
    return quote(relative.replace(os.sep, "/"), safe="/:._-~")


def as_lines(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    if value is None or value == "":
        return []
    return [str(value)]


def checkpoint_state(observation: dict) -> dict:
    control = observation.get("control", {})
    queries = observation.get("queries", {})
    return {
        "simulation steps": control.get("simulation_steps"),
        "tool": control.get("player_mode"),
        "rotation": control.get("stair_rotation"),
        "preview": [{"cell": row.get("position"), "valid": row.get("metadata", {}).get("valid"),
                     "block": row.get("metadata", {}).get("stair_material")}
                    for row in observation.get("rendering", {}).get("previews", [])],
        "cells": {str(row.get("pos")): row.get("result", {}).get("block", row.get("result", {}).get("error"))
                  for row in queries.get("cells", [])},
        "workers": {str(row.get("id")): row.get("result", {}).get("state", {}).get("position", row.get("result", {}).get("error"))
                    for row in queries.get("workers", [])},
        "tasks": {str(row.get("id")): row.get("result", {}).get("state", {}).get("status", row.get("result", {}).get("error"))
                  for row in queries.get("tasks", [])},
    }


def render_card(observation: dict, bundle: Path, output: Path, previous: dict | None = None) -> str:
    label = esc(observation.get("label", observation.get("operation_id", "observation")))
    operation_id = esc(observation.get("operation_id", ""))
    action = esc(observation.get("action", "observe"))
    readiness = observation.get("readiness", {})
    if not isinstance(readiness, dict):
        readiness = {}
    coherence = observation.get("coherence", {})
    if not isinstance(coherence, dict):
        coherence = {}
    screenshot = observation.get("screenshot", {})
    if not isinstance(screenshot, dict):
        screenshot = {}
    image = bundle / "screenshot.png"
    image_block = '<div class="no-image">image unavailable: %s</div>' % esc(screenshot.get("reason", "not captured"))
    if image.is_file():
        image_block = '<a href="%s"><img src="%s" alt="%s" loading="lazy"></a>' % (
            esc(relative_href(image, output)),
            esc(relative_href(image, output)),
            label,
        )
    actions = as_lines(observation.get("actions", []))
    observations = as_lines(observation.get("observations", []))
    unmet = as_lines(readiness.get("unmet", []))
    body = [
        '<article class="card">',
        '<div class="thumb">%s</div>' % image_block,
        '<div class="card-body"><h3>%s</h3>' % label,
        '<p class="meta">action <code>%s</code> · operation <code>%s</code></p>' % (action, operation_id),
        '<p>readiness: <strong>%s</strong>; coherence: <strong>%s</strong></p>' % (
            esc(readiness.get("label", "unknown")),
            "yes" if coherence.get("coherent", False) else "no",
        ),
    ]
    if unmet:
        body.append('<p class="unmet">unmet checks: %s</p>' % ", ".join(esc(item) for item in unmet))
    if actions:
        body.append('<details><summary>actions (%d)</summary><ul>%s</ul></details>' % (
            len(actions), "".join("<li>%s</li>" % esc(item) for item in actions)))
    if observations:
        body.append('<details open><summary>observations (%d)</summary><ul>%s</ul></details>' % (
            len(observations), "".join("<li>%s</li>" % esc(item) for item in observations)))
    current = checkpoint_state(observation)
    differences = [(key, previous.get(key), value) for key, value in current.items()
                   if previous is not None and previous.get(key) != value]
    if differences:
        body.append('<details><summary>State changes (%d)</summary><ul>%s</ul></details>' % (
            len(differences), "".join('<li><strong>%s</strong>: %s &rarr; %s</li>' %
                                      (esc(key), esc(json.dumps(before)), esc(json.dumps(after)))
                                      for key, before, after in differences)))
    body.append('<p><a href="%s">State JSON</a> · <a href="%s">Capture manifest</a></p>' % (
        esc(relative_href(bundle / "snapshot.json", output)), esc(relative_href(bundle / "manifest.json", output))))
    body.append('<p class="path">bundle: <code>%s</code></p>' % esc(str(bundle)))
    body.append("</div></article>")
    return "".join(body)


def render_acceptance_field(acceptance: dict, name: str) -> str:
    value = acceptance.get(name)
    if value is None:
        return ""
    status = ""
    findings: object = value
    if isinstance(value, dict):
        status = str(value.get("status", value.get("state", "")))
        findings = value.get("findings", value.get("observations", value.get("items", [])))
    lines = findings if isinstance(findings, list) else as_lines(findings)
    title = name.replace("_", " ")
    parts = ['<div class="acceptance"><strong>%s</strong>' % esc(title)]
    if status:
        parts.append(' <span class="meta">status: %s</span>' % esc(status))
    if lines:
        items = []
        for line in lines:
            if isinstance(line, dict):
                label = str(line.get("kind", "finding")).replace("_", " ")
                suffix = line.get("state", line.get("matches", line.get("rotation", "")))
                items.append('<li><details><summary>%s: %s</summary><pre>%s</pre></details></li>' % (
                    esc(label), esc(suffix), esc(json.dumps(line, indent=2))))
            else:
                items.append("<li>%s</li>" % esc(line))
        parts.append('<ul>%s</ul>' % "".join(items))
    else:
        parts.append('<p class="empty">no recorded findings</p>')
    parts.append("</div>")
    return "".join(parts)


def build_report(root: Path, output: Path) -> str:
    observations: list[tuple[dict, Path]] = []
    for path in observation_files(root):
        observation, bundle = load_observation(path)
        if observation:
            observations.append((observation, bundle))
    card_parts = []
    previous = None
    for observation, bundle in observations:
        card_parts.append(render_card(observation, bundle, output, previous))
        previous = checkpoint_state(observation)
    cards = "".join(card_parts)
    if not cards:
        cards = '<p class="empty">No completed observations found under <code>%s</code>.</p>' % esc(str(root))
    acceptance = read_json(root / "acceptance.json")
    harness_acceptance = render_acceptance_field(acceptance, "harness_findings")
    if "harness_result" in acceptance:
        checks = acceptance.get("checks", [])
        harness_acceptance = '<p><strong>%s</strong> · %d/%d checks passed. <a href="%s">Acceptance details</a></p>' % (
            esc(acceptance["harness_result"]), sum(bool(check.get("passed")) for check in checks), len(checks),
            esc(relative_href(root / "acceptance.json", output)))
        if acceptance.get("error"):
            harness_acceptance += '<p class="unmet">%s</p>' % esc(acceptance["error"])
        background = acceptance.get("background_control", {})
        if background:
            harness_acceptance += '<p>Other application kept foreground: %s. Independent synthetic pointer movement observed: %s.</p>' % (
                esc(background.get("unfocused_throughout")), esc(background.get("pointer_independence_observed")))
    if not harness_acceptance:
        harness_acceptance = render_acceptance_field(acceptance, "harness")
    gameplay_acceptance = render_acceptance_field(acceptance, "gameplay_findings")
    if not gameplay_acceptance:
        gameplay_acceptance = render_acceptance_field(acceptance, "gameplay")
    if not harness_acceptance:
        harness_acceptance = '<p class="empty">No recorded harness findings.</p>'
    if not gameplay_acceptance:
        gameplay_acceptance = '<p class="empty">No recorded gameplay findings.</p>'
    return """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Goblinoria playtest report</title><style>
:root{color-scheme:dark;font:14px system-ui,sans-serif;background:#151719;color:#e7e9eb}
body{margin:0 auto;max-width:1280px;padding:20px}h1,h2{margin:0 0 10px}h2{margin-top:28px}
.contact{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(460px,100%%),1fr));gap:12px}
.card{background:#22262a;border:1px solid #3b4248;border-radius:7px;overflow:hidden;min-height:190px}
.thumb{background:#0e1011;width:100%%;display:flex;align-items:center;justify-content:center}
.thumb a{display:block;width:100%%}.thumb img{display:block;width:100%%;max-height:360px;object-fit:contain}.no-image{padding:12px;color:#aab1b7;text-align:center;font-size:12px}
.card-body{padding:12px;overflow-wrap:anywhere}.card h3{margin:0 0 5px;font-size:16px}.meta,.path{color:#aab1b7;font-size:12px}code{font-family:ui-monospace,monospace;font-size:.9em}
pre{white-space:pre-wrap;overflow-wrap:anywhere}
.unmet{color:#ffba7a}details{margin-top:8px}summary{cursor:pointer}ul{margin:5px 0 0;padding-left:20px}table{width:100%%;border-collapse:collapse;background:#22262a}th,td{padding:7px;text-align:left;border:1px solid #3b4248;vertical-align:top}.empty{color:#aab1b7}
</style></head><body><h1>Goblinoria playtest report</h1>
<p>Observations: %d · source: <code>%s</code></p>
<h2>Harness findings</h2>%s<h2>Gameplay findings</h2>%s
<h2>Actions and observations</h2><section class="contact">%s</section>
	</body></html>""" % (
        len(observations), esc(str(root)), harness_acceptance, gameplay_acceptance, cards,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_root", type=Path, help="playtest run directory containing observations/")
    parser.add_argument("-o", "--output", type=Path, help="output HTML path (default: RUN_ROOT/playtest_report.html)")
    args = parser.parse_args()
    root = args.run_root
    output = args.output or root / "playtest_report.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(build_report(root, output), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
