#!/usr/bin/env python3
"""Register new Swift files in SpotlessMac.xcodeproj.

Usage:
  scripts/xcodeproj-add.py app Memory SpotlessMac/Memory/Foo.swift [...]
  scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/FooTests.swift [...]

The group is looked up by name; a missing app subgroup is created under the
SpotlessMac group. IDs are derived from the file path, so re-running is a no-op.
"""
import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "SpotlessMac.xcodeproj" / "project.pbxproj"
SOURCES_PHASE = {"app": "BB000002000000000000BB00", "tests": "BB100002000000000000BB00"}
APP_ROOT_GROUP = "AA000003000000000000AA00"


def make_id(kind: str, key: str) -> str:
    return hashlib.md5(f"{kind}:{key}".encode()).hexdigest()[:24].upper()


def insert_after(text: str, marker: str, line: str) -> str:
    index = text.index(marker) + len(marker)
    return text[:index] + "\n" + line + text[index:]


def add_child(text: str, group_id: str, child_line: str) -> str:
    match = re.search(re.escape(group_id) + r" /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(", text)
    if not match:
        raise SystemExit(f"group {group_id} not found")
    return text[:match.end()] + "\n" + child_line + text[match.end():]


def find_group(text: str, name: str):
    match = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(name) + r" \*/ = \{\n\t\t\tisa = PBXGroup;", text)
    return match.group(1) if match else None


def ensure_group(text: str, name: str):
    group_id = find_group(text, name)
    if group_id:
        return text, group_id
    group_id = make_id("group", name)
    block = (f"\t\t{group_id} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
             f"\t\t\tpath = {name};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
    text = insert_after(text, "/* Begin PBXGroup section */", block)
    text = add_child(text, APP_ROOT_GROUP, f"\t\t\t\t{group_id} /* {name} */,")
    return text, group_id


def main() -> None:
    target, group_name, *files = sys.argv[1:]
    text = PROJECT.read_text()
    text, group_id = ensure_group(text, group_name)
    for file in files:
        name = Path(file).name
        ref_id, build_id = make_id("ref", file), make_id("build", file)
        if ref_id in text:
            continue
        text = insert_after(text, "/* Begin PBXFileReference section */",
                            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
                            f"path = {name}; sourceTree = \"<group>\"; }};")
        text = insert_after(text, "/* Begin PBXBuildFile section */",
                            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};")
        text = add_child(text, group_id, f"\t\t\t\t{ref_id} /* {name} */,")
        phase = SOURCES_PHASE[target]
        marker = f"{phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = ("
        if marker not in text:
            raise SystemExit(f"sources phase {phase} not found")
        text = insert_after(text, marker, f"\t\t\t\t{build_id} /* {name} in Sources */,")
    PROJECT.write_text(text)


if __name__ == "__main__":
    main()
