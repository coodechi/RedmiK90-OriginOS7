#!/usr/bin/env python3
"""
Patch Android build.prop in-place while preserving file permissions, ownership,
and SELinux security.selinux xattr.
"""

import argparse
import os
import sys


def parse_config(conf_path):
    sections = {"remove": [], "set": [], "debug_set": []}
    current = None
    with open(conf_path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                sec = line[1:-1].strip()
                if sec not in sections:
                    raise ValueError(f"Unknown section [{sec}] in {conf_path}")
                current = sec
                continue
            if current is None:
                raise ValueError(f"Entry outside section in {conf_path}: {line}")
            if current == "remove":
                sections[current].append(line)
            else:
                if "=" not in line:
                    raise ValueError(f"Expected key=value in [{current}]: {line}")
                k, v = line.split("=", 1)
                sections[current].append((k.strip(), v.strip()))
    return sections


def patch_prop_file(prop_path, remove_keys, set_pairs, extra_kv_lines=None):
    st = os.lstat(prop_path)
    saved_xattrs = {}
    if hasattr(os, "listxattr"):
        try:
            for name in os.listxattr(prop_path, follow_symlinks=False):
                saved_xattrs[name] = os.getxattr(prop_path, name, follow_symlinks=False)
        except OSError:
            pass

    with open(prop_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        lines = f.readlines()

    remove_set = set(remove_keys)
    set_map = dict(set_pairs)
    seen_set = set()
    out_lines = []

    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k = stripped.split("=", 1)[0].strip()
            if k in remove_set:
                out_lines.append(f"# [K90-PORT REMOVED] {line}")
                continue
            if k in set_map:
                if k not in seen_set:
                    out_lines.append(f"{k}={set_map[k]}\n")
                    seen_set.add(k)
                else:
                    out_lines.append(f"# [K90-PORT DEDUP] {line}")
                continue
        out_lines.append(line)

    # Append any keys that did not already exist in the file
    appended = [(k, v) for k, v in set_pairs if k not in seen_set]
    if appended or extra_kv_lines:
        out_lines.append("\n# === K90 OriginOS 7 Port Overrides ===\n")
        for k, v in appended:
            out_lines.append(f"{k}={v}\n")
        if extra_kv_lines:
            for raw in extra_kv_lines:
                out_lines.append(raw if raw.endswith("\n") else raw + "\n")

    # Write in-place (preserving inode/xattrs where possible) then restore exact metadata
    with open(prop_path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.writelines(out_lines)

    os.chown(prop_path, st.st_uid, st.st_gid)
    os.chmod(prop_path, st.st_mode & 0o7777)
    for name, val in saved_xattrs.items():
        try:
            os.setxattr(prop_path, name, val, follow_symlinks=False)
        except OSError as e:
            print(f"[WARN] Could not restore xattr {name} on {prop_path}: {e}", file=sys.stderr)

    print(
        f"[OK] Patched {prop_path}: removed={len(remove_set)}, "
        f"updated={len(seen_set)}, appended={len(appended)}, "
        f"xattrs_restored={list(saved_xattrs.keys())}"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prop", required=True, help="Path to build.prop")
    ap.add_argument("--config", required=True, help="Path to prop_override.conf")
    ap.add_argument("--debug-adb", action="store_true", help="Apply [debug_set] rules")
    args = ap.parse_args()

    secs = parse_config(args.config)
    set_pairs = list(secs["set"])
    if args.debug_adb:
        set_pairs.extend(secs["debug_set"])
    patch_prop_file(args.prop, secs["remove"], set_pairs)


if __name__ == "__main__":
    main()
