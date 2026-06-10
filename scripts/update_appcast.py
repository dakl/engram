#!/usr/bin/env python3
"""Insert a new release entry into the Sparkle appcast feed.

Stdlib only — runs on the CI runner without uv (see ADR 0010). Prepends a
newest-first <item> to docs/appcast.xml, creating the feed if it does not yet
exist.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY_FEED = (
    '<?xml version="1.0" standalone="yes"?>\n'
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
    "  <channel>\n"
    "    <title>Engram</title>\n"
    "  </channel>\n"
    "</rss>\n"
)


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    ET.SubElement(item, "pubDate").text = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, sparkle("version")).text = args.version
    ET.SubElement(item, sparkle("shortVersionString")).text = args.short_version
    if args.min_system:
        ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.min_system
    # Turn ".../releases/download/<tag>/<file>.zip" into the human release page.
    release_page = args.url.replace("/releases/download/", "/releases/tag/").rsplit("/", 1)[0]
    ET.SubElement(item, "description").text = f"Engram {args.short_version}. Release notes: {release_page}"

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set(sparkle("edSignature"), args.signature)
    enclosure.set("length", args.length)
    enclosure.set("type", "application/octet-stream")
    return item


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--version", required=True, help="CFBundleVersion / build number")
    parser.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--url", required=True, help="enclosure download URL")
    parser.add_argument("--signature", required=True, help="sparkle:edSignature")
    parser.add_argument("--length", required=True, help="archive byte length")
    parser.add_argument("--min-system", default="", help="minimum macOS version (optional)")
    args = parser.parse_args()

    if not args.appcast.exists():
        args.appcast.write_text(EMPTY_FEED)

    tree = ET.parse(args.appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("appcast has no <channel>")

    # Newest first: insert after the channel's metadata, before existing items.
    first_item_index = next(
        (i for i, child in enumerate(channel) if child.tag == "item"),
        len(channel),
    )
    channel.insert(first_item_index, build_item(args))

    ET.indent(tree, space="  ")
    tree.write(args.appcast, encoding="unicode", xml_declaration=False)
    args.appcast.write_text(
        '<?xml version="1.0" standalone="yes"?>\n' + args.appcast.read_text().lstrip()
    )
    print(f"appcast updated with {args.short_version} (build {args.version})")


if __name__ == "__main__":
    main()
