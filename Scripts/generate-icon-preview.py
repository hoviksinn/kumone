#!/usr/bin/env python3
"""Regenerate the README's flat SVG preview from the editable .icon package.

The app uses actool's native Liquid Glass rendition, not this flat preview.
Only Python's standard library is needed; no image tool runs in CI.
"""
import json
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def element(name, **attributes):
    return ET.Element(f"{{{SVG}}}{name}", attributes)


def color(value):
    space, components = value.split(":", 1)
    if space != "srgb":
        raise ValueError("The flat preview expects sRGB icon background colors")
    red, green, blue, _ = (float(value) for value in components.split(","))
    return "#" + "".join(f"{round(component * 255):02x}" for component in (red, green, blue))


manifest = json.loads((ROOT / "AppIcon.icon/icon.json").read_text())
preview = element("svg", width="1024", height="1024", viewBox="0 0 1024 1024")
title = element("title")
title.text = "且听 — Original placeholder icon (flat preview)"
preview.append(title)
definitions = element("defs")
gradient = element("linearGradient", id="background", x1="0", y1="0", x2="1", y2="1")
for offset, value in zip(("0%", "100%"), manifest["fill"]["linear-gradient"]):
    gradient.append(element("stop", offset=offset, **{"stop-color": color(value)}))
definitions.append(gradient)
preview.append(definitions)
preview.append(element("rect", width="1024", height="1024", rx="220", fill="url(#background)"))
for group in manifest["groups"]:
    for layer in group["layers"]:
        artwork = ET.parse(ROOT / "AppIcon.icon/Assets" / layer["image-name"]).getroot()
        preview.extend(artwork)
ET.indent(preview, space="  ")
(ROOT / "docs/qieting-icon.svg").write_text(ET.tostring(preview, encoding="unicode") + "\n")
