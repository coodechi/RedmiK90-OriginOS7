#!/usr/bin/env python3
"""
Compare K90 (vendor/odm) VINTF manifests against iQOO Neo 11 (system/system_ext/product)
compatibility matrices and report required (optional="false") HALs missing on K90.
"""

import glob
import os
import sys
import xml.etree.ElementTree as ET


def collect_vendor_hals(vintf_dir):
    hals = {}  # (format, name) -> set(versions)
    for xml_path in sorted(glob.glob(os.path.join(vintf_dir, "**", "*.xml"), recursive=True)):
        try:
            tree = ET.parse(xml_path)
            root = tree.getroot()
        except Exception as e:
            print(f"[WARN] Failed parsing vendor XML {xml_path}: {e}")
            continue
        if root.tag != "manifest":
            continue
        for hal in root.findall("hal"):
            fmt = hal.attrib.get("format", "hidl")
            name_el = hal.find("name")
            if name_el is None or not name_el.text:
                continue
            name = name_el.text.strip()
            versions = set()
            for v in hal.findall("version"):
                if v.text:
                    versions.add(v.text.strip())
            for fq in hal.findall("fqname"):
                if fq.text and "@" in fq.text:
                    versions.add(fq.text.strip().split("::")[0].lstrip("@"))
            hals.setdefault((fmt, name), set()).update(versions or {"1"})
    return hals


def collect_framework_requirements(vintf_dir):
    reqs = []
    for xml_path in sorted(glob.glob(os.path.join(vintf_dir, "**", "*.xml"), recursive=True)):
        try:
            tree = ET.parse(xml_path)
            root = tree.getroot()
        except Exception as e:
            print(f"[WARN] Failed parsing framework XML {xml_path}: {e}")
            continue
        if root.tag != "compatibility-matrix":
            continue
        rel = os.path.relpath(xml_path, vintf_dir)
        for hal in root.findall("hal"):
            fmt = hal.attrib.get("format", "hidl")
            opt = hal.attrib.get("optional", "false").lower() == "true"
            name_el = hal.find("name")
            if name_el is None or not name_el.text:
                continue
            name = name_el.text.strip()
            versions = [v.text.strip() for v in hal.findall("version") if v.text]
            reqs.append({
                "file": rel,
                "format": fmt,
                "name": name,
                "optional": opt,
                "versions": versions,
            })
    return reqs


def main():
    if len(sys.argv) != 3:
        print("Usage: vintf_diff.py <k90_vendor_vintf_dir> <neo11_fw_vintf_dir>")
        sys.exit(1)

    vendor_hals = collect_vendor_hals(sys.argv[1])
    fw_reqs = collect_framework_requirements(sys.argv[2])

    print(f"K90 Vendor/ODM HALs found: {len(vendor_hals)}")
    print(f"Neo 11 Framework Matrix HAL entries found: {len(fw_reqs)}")

    missing_required = []
    missing_optional = []
    for r in fw_reqs:
        key = (r["format"], r["name"])
        if key not in vendor_hals:
            if not r["optional"]:
                missing_required.append(r)
            else:
                missing_optional.append(r)

    print("\n=== CRITICAL: Required (optional=false) HALs missing on K90 ===")
    if not missing_required:
        print("  (None found!)")
    else:
        seen = set()
        for r in missing_required:
            sig = (r["file"], r["format"], r["name"])
            if sig in seen:
                continue
            seen.add(sig)
            print(f"  [REQUIRED MISSING] {r['format']:<4s} {r['name']} versions={r['versions']} (from {r['file']})")

    print(f"\n=== Optional (optional=true) HALs missing on K90: {len(missing_optional)} entries ===")
    vivo_opt = sorted({r["name"] for r in missing_optional if "vivo" in r["name"].lower() or "bbk" in r["name"].lower()})
    if vivo_opt:
        print("  Vivo/BBK optional HALs:")
        for n in vivo_opt:
            print(f"    - {n}")


if __name__ == "__main__":
    main()
