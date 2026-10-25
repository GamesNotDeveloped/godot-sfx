#!/usr/bin/env python3
"""Moves .tres/.tscn files from gnd_sfx's GDScript classes to its native ones (GDExtension).

A resource or node that had `script = ExtResource(<addons/gnd_sfx/sfx_*.gd>)` becomes the native type
itself, and typed arrays of those scripts become arrays of the native class. Scripts that extend
the classes (an SfxGeneratorPlayback subclass) are left alone - rename their create_state/update/
cleanup to _create_state/_update/_cleanup by hand.

Usage: tools/migrate_tres.py <file or directory>...   (rewrites in place, prints what it changed)
"""

import re
import sys
from pathlib import Path

CLASSES = {
    "sfx_bank.gd": "SfxBank",
    "sfx_event.gd": "SfxEvent",
    "sfx_clip.gd": "SfxClip",
    "sfx_track.gd": "SfxTrack",
    "sfx_automation.gd": "SfxAutomation",
    "sfx_parameter_modulation.gd": "SfxParameterModulation",
    "sfx_spatial_config.gd": "SfxSpatialConfig",
    "sfx_generator_playback.gd": "SfxGeneratorPlayback",
    "sfx_player.gd": "SfxPlayer",
    "sfx_player_3d.gd": "SfxPlayer3D",
}
# what scripts that extend these classes extend: their resources take the native type too
NATIVE_BASES = {"SfxGeneratorPlayback"}
ANY_SCRIPT = re.compile(r'^\[ext_resource type="Script"[^\]]*path="res://([^"]+)"[^\]]*id="([^"]+)"\]', re.M)
EXT = re.compile(r'^\[ext_resource type="Script"[^\]]*path="res://(?:.*/)?addons/gnd_sfx/(sfx_[a-z_0-9]+\.gd)"[^\]]*id="([^"]+)"\]\n', re.M)
HEADER = re.compile(r'^\[(gd_resource|sub_resource|node|resource)\b([^\]]*)\]$')
SCRIPT = re.compile(r'^script = ExtResource\("([^"]+)"\)$')


def subclass_bases(text, project):
    """id -> native base, for the scripts of `text` that extend a migrated class"""
    bases = {}
    for path, id_ in ANY_SCRIPT.findall(text):
        script = project / path if project else None
        if script and script.is_file():
            m = re.search(r"^extends\s+(\w+)", script.read_text(), re.M)
            if m and m.group(1) in NATIVE_BASES:
                bases[id_] = m.group(1)
    return bases


def retype_subclasses(text, bases):
    lines = text.split("\n")
    header = None
    for i, line in enumerate(lines):
        if HEADER.match(line):
            header = i
        elif (m := SCRIPT.match(line)) and m.group(1) in bases and header is not None:
            lines[header] = re.sub(r' type="Resource"', f' type="{bases[m.group(1)]}"', lines[header], count=1)
    return "\n".join(lines)


def migrate(text, project=None):
    text = retype_subclasses(text, subclass_bases(text, project))
    ids = {m.group(2): CLASSES[m.group(1)] for m in EXT.finditer(text) if m.group(1) in CLASSES}
    if not ids:
        return text
    # the editor's "custom type" marks name the scripts by uid
    uids = {u for m in EXT.finditer(text) if m.group(1) in CLASSES for u in re.findall(r'uid="([^"]+)"', m.group(0))}
    text = "\n".join(line for line in text.split("\n")
            if not any(line == f'metadata/_custom_type_script = "{uid}"' for uid in uids))
    text = EXT.sub(lambda m: "" if m.group(1) in CLASSES else m.group(0), text)
    for id_, cls in ids.items():
        text = text.replace(f'Array[ExtResource("{id_}")]', f"Array[{cls}]")
    lines = text.split("\n")
    header = None  # index of the section header the current lines belong to
    root_class = None
    for i, line in enumerate(lines):
        if HEADER.match(line):
            header = i
            continue
        m = SCRIPT.match(line)
        if not m or m.group(1) not in ids or header is None:
            continue
        cls = ids[m.group(1)]
        lines[i] = None
        kind = HEADER.match(lines[header]).group(1)
        if kind == "resource":
            root_class = cls
        elif kind == "node":
            lines[header] = re.sub(r' type="[^"]*"', f' type="{cls}"', lines[header])
        else:
            lines[header] = re.sub(r' type="[^"]*"', f' type="{cls}"', lines[header], count=1)
    if root_class:
        lines[0] = re.sub(r' type="[^"]*"', f' type="{root_class}"', lines[0], count=1)
        lines[0] = re.sub(r' script_class="[^"]*"', "", lines[0])
    return "\n".join(line for line in lines if line is not None)


def project_of(path):
    return next((p for p in path.resolve().parents if (p / "project.godot").is_file()), None)


def main(paths):
    for root in map(Path, paths):
        files = [root] if root.is_file() else [*root.rglob("*.tres"), *root.rglob("*.tscn")]
        for path in files:
            text = path.read_text()
            migrated = migrate(text, project_of(path))
            if migrated != text:
                path.write_text(migrated)
                print(f"migrated {path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
