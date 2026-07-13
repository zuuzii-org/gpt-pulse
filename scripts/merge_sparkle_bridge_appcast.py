#!/usr/bin/env python3
"""Merge one pinned bridge item into a newly generated Sparkle appcast."""

from __future__ import annotations

import argparse
import copy
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = f"{{{SPARKLE_NAMESPACE}}}"
ET.register_namespace("sparkle", SPARKLE_NAMESPACE)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", required=True, type=Path)
    parser.add_argument("--bridge", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--current-build", required=True)
    parser.add_argument("--bridge-build", required=True)
    parser.add_argument("--minimum-update-build", required=True)
    parser.add_argument("--channel-title", required=True)
    return parser.parse_args()


def channel(root: ET.Element) -> ET.Element:
    result = root.find("channel")
    if result is None:
        raise ValueError("appcast has no channel")
    return result


def item_build(item: ET.Element) -> str:
    version = item.find(f"{SPARKLE}version")
    if version is not None and version.text:
        return version.text.strip()
    enclosure = item.find("enclosure")
    if enclosure is None:
        return ""
    return (enclosure.get(f"{SPARKLE}version") or "").strip()


def require_single_item(root: ET.Element, expected_build: str) -> ET.Element:
    items = channel(root).findall("item")
    matches = [item for item in items if item_build(item) == expected_build]
    if len(items) != 1 or len(matches) != 1:
        raise ValueError(
            f"expected exactly one item for build {expected_build}, "
            f"found {len(matches)} among {len(items)} items"
        )
    return matches[0]


def validate_enclosure(item: ET.Element, label: str) -> None:
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError(f"{label} item has no enclosure")
    if not (enclosure.get("url") or "").strip():
        raise ValueError(f"{label} enclosure has no URL")
    if not (enclosure.get(f"{SPARKLE}edSignature") or "").strip():
        raise ValueError(f"{label} enclosure has no EdDSA signature")
    length = (enclosure.get("length") or "").strip()
    if not length.isdigit() or int(length) <= 0:
        raise ValueError(f"{label} enclosure has an invalid length")


def merge(args: argparse.Namespace) -> None:
    current_tree = ET.parse(args.current)
    bridge_tree = ET.parse(args.bridge)
    current_item = require_single_item(current_tree.getroot(), args.current_build)
    bridge_item = require_single_item(bridge_tree.getroot(), args.bridge_build)
    validate_enclosure(current_item, "current")
    validate_enclosure(bridge_item, "bridge")

    minimum_update = current_item.find(f"{SPARKLE}minimumUpdateVersion")
    actual_minimum = "" if minimum_update is None else (minimum_update.text or "").strip()
    if actual_minimum != args.minimum_update_build:
        raise ValueError(
            "current item minimumUpdateVersion "
            f"is {actual_minimum!r}, expected {args.minimum_update_build!r}"
        )
    if bridge_item.find(f"{SPARKLE}minimumUpdateVersion") is not None:
        raise ValueError("bridge item must remain available without minimumUpdateVersion")

    current_channel = channel(current_tree.getroot())
    title = current_channel.find("title")
    if title is None:
        title = ET.Element("title")
        current_channel.insert(0, title)
    title.text = args.channel_title

    for item in current_channel.findall("item"):
        current_channel.remove(item)
    current_channel.append(copy.deepcopy(current_item))
    current_channel.append(copy.deepcopy(bridge_item))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    current_tree.write(args.output, encoding="utf-8", xml_declaration=True)


def main() -> int:
    try:
        merge(parse_arguments())
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"merge_sparkle_bridge_appcast: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
