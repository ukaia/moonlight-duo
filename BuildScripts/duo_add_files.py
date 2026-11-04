#!/usr/bin/env python3
"""Add the Limelight/Modern sources to the iOS "Moonlight" target and apply the
Duo build settings. Idempotent: files already referenced are skipped."""
import hashlib, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "Moonlight.xcodeproj", "project.pbxproj")
MODERN = os.path.join(ROOT, "Limelight", "Modern")
PARENT_GROUP = "FB290CF919B2C406004C83CF"   # Moonlight (path = Limelight)
IOS_SOURCES = "FB290CEA19B2C406004C83CF"    # Sources phase of the iOS target
BUNDLE_ID = "com.moonlight-duo.Moonlight"
IOS_CONFIGS = ["FB290D2119B2C406004C83CF", "FB290D2219B2C406004C83CF"]  # Debug, Release

def oid(seed):
    return hashlib.sha1(("duo:" + seed).encode()).hexdigest()[:24].upper()

src = open(PBX).read()
files = sorted(f for f in os.listdir(MODERN) if f.endswith((".swift", ".m", ".h")))
group_id = oid("group:Modern")

def ftype(name):
    return {"swift": "sourcecode.swift", "m": "sourcecode.c.objc", "h": "sourcecode.c.h"}[name.rsplit(".", 1)[1]]

new_refs, new_builds, group_children, phase_entries = [], [], [], []
for f in files:
    ref, bld = oid("ref:" + f), oid("build:" + f)
    if ref in src:
        continue
    new_refs.append(f'\t\t{ref} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype(f)}; path = {f}; sourceTree = "<group>"; }};\n')
    group_children.append(f"\t\t\t\t{ref} /* {f} */,\n")
    if not f.endswith(".h"):
        new_builds.append(f"\t\t{bld} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {f} */; }};\n")
        phase_entries.append(f"\t\t\t\t{bld} /* {f} in Sources */,\n")

if new_refs:
    src = src.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + "".join(new_refs), 1)
if new_builds:
    src = src.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n" + "".join(new_builds), 1)

if group_id not in src:
    group = (f"\t\t{group_id} /* Modern */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
             + "".join(group_children) + "\t\t\t);\n\t\t\tpath = Modern;\n\t\t\tsourceTree = \"<group>\";\n\t\t};\n")
    src = src.replace("/* Begin PBXGroup section */\n", "/* Begin PBXGroup section */\n" + group, 1)
    src = re.sub(rf"({PARENT_GROUP} /\* Moonlight \*/ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)",
                 rf"\g<1>\t\t\t\t{group_id} /* Modern */,\n", src, count=1)
elif group_children:
    src = re.sub(rf"({group_id} /\* Modern \*/ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)",
                 lambda m: m.group(1) + "".join(group_children), src, count=1)

if phase_entries:
    src = re.sub(rf"({IOS_SOURCES} /\* Sources \*/ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)",
                 lambda m: m.group(1) + "".join(phase_entries), src, count=1)

# Build settings for the iOS app target only.
for cfg in IOS_CONFIGS:
    start = src.index(f"\t\t{cfg} /*")
    end = src.index("\t\t};\n", start)
    block = src[start:end]
    # A bundle ID of its own, so it installs next to the App Store Moonlight.
    block = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = "[^"]*";', f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";', block)
    block = block.replace('IPHONEOS_DEPLOYMENT_TARGET = "$(RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET)";',
                          'IPHONEOS_DEPLOYMENT_TARGET = 26.0;')
    # Old projects never set it, so Swift `#if DEBUG` code would silently compile out.
    if cfg == IOS_CONFIGS[0] and "SWIFT_ACTIVE_COMPILATION_CONDITIONS" not in block:
        block = block.replace("\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER =", "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER =", 1)
    src = src[:start] + block + src[end:]

open(PBX, "w").write(src)
print(f"added {len(new_refs)} file refs, {len(phase_entries)} sources")
