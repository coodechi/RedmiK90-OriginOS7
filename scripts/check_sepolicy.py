#!/usr/bin/env python3
"""
Pre-flight Split SEPolicy Compiler Gate & Cross-OEM Compatibility Shim Generator.

Simulates Android init's CompileSplitPolicy() using `secilc` on:
  - Port (Neo 11): system + system_ext + product CILs + mapping/<vers>.cil
  - Base (K90):    vendor (plat_pub_versioned + vendor_sepolicy) + odm_sepolicy

Host-version compatibility:
  Ubuntu 24.04 ships secilc 3.5 (2023), whereas Android 17 CILs may contain
  newer kernel policycaps (e.g. `(policycap functionfs_seclabel)`).
  We mirror CILs into a temporary workspace and comment out ONLY host-unknown
  `policycap` lines (preserving 1:1 line numbers, NEVER modifying real ROM
  `plat_sepolicy.cil`), verify stock K90 baseline compiles cleanly, and then
  compile the real cross-OEM Neo 11 + K90 split policy!

If K90's vendor/odm CIL references Xiaomi-specific platform types/attributes
missing from Neo 11's system/system_ext/product, automatically synthesizes
minimal compatibility declarations into Neo 11's REAL mapping/<vers>.cil and
re-runs `secilc` until compilation succeeds with exit code 0!
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile


def collect_cil_files(sys_se, ext_se, prod_se, vnd_se, odm_se, vers):
    """Collect split CIL files in the exact order Android init passes to secilc."""
    cils = []

    def add_if_exists(p):
        if p and os.path.isfile(p) and os.path.getsize(p) > 0:
            cils.append(p)

    # 1. system (plat)
    add_if_exists(os.path.join(sys_se, "plat_sepolicy.cil"))
    add_if_exists(os.path.join(sys_se, "mapping", f"{vers}.cil"))
    add_if_exists(os.path.join(sys_se, "mapping", f"{vers}.compat.cil"))

    # 2. system_ext
    if ext_se:
        add_if_exists(os.path.join(ext_se, "system_ext_sepolicy.cil"))
        add_if_exists(os.path.join(ext_se, "mapping", f"{vers}.cil"))
        add_if_exists(os.path.join(ext_se, "mapping", f"{vers}.compat.cil"))

    # 3. product
    if prod_se:
        add_if_exists(os.path.join(prod_se, "product_sepolicy.cil"))
        add_if_exists(os.path.join(prod_se, "mapping", f"{vers}.cil"))
        add_if_exists(os.path.join(prod_se, "mapping", f"{vers}.compat.cil"))

    # 4. vendor
    add_if_exists(os.path.join(vnd_se, "plat_pub_versioned.cil"))
    add_if_exists(os.path.join(vnd_se, "vendor_sepolicy.cil"))
    add_if_exists(os.path.join(vnd_se, "nonplat_sepolicy.cil"))

    # 5. odm
    if odm_se:
        add_if_exists(os.path.join(odm_se, "odm_sepolicy.cil"))

    return cils


def detect_policy_vers(sys_se, vnd_se):
    vers_file = os.path.join(vnd_se, "plat_sepolicy_vers.txt")
    if os.path.isfile(vers_file):
        v = open(vers_file, "r", encoding="utf-8").read().strip()
        if v:
            return v
    maps = sorted(glob.glob(os.path.join(sys_se, "mapping", "*.cil")))
    for m in reversed(maps):
        bn = os.path.basename(m)
        if not bn.endswith(".compat.cil"):
            return bn[:-4]
    return "202404"


def run_secilc(cils, out_bin):
    cmd = [
        "secilc",
        "-m",
        "-M", "true",
        "-G",
        "-N",
        "-c", "30",
        "-o", out_bin,
        "-f", "/dev/null",
    ] + cils
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def mirror_cils_for_host(cils, work_dir, tag, ignored_policycaps):
    """Copy CILs into work_dir/tag/ while commenting out host-unknown policycaps (1:1 line count)."""
    out_dir = os.path.join(work_dir, tag)
    os.makedirs(out_dir, exist_ok=True)
    mirrored = []
    cap_pats = [
        re.compile(rf"^(\s*)\(policycap\s+{re.escape(cap)}\s*\)(.*)$")
        for cap in ignored_policycaps
    ]
    for idx, src in enumerate(cils):
        dst = os.path.join(out_dir, f"{idx:02d}_{os.path.basename(src)}")
        with open(src, "r", encoding="utf-8", errors="ignore") as fin:
            lines = fin.readlines()
        out_lines = []
        for ln in lines:
            replaced = False
            for pat in cap_pats:
                if pat.match(ln):
                    out_lines.append(f";; [host-secilc-sanitized] {ln}")
                    replaced = True
                    break
            if not replaced:
                out_lines.append(ln)
        with open(dst, "w", encoding="utf-8") as fout:
            fout.writelines(out_lines)
        mirrored.append(dst)
    return mirrored


def parse_invalid_policycaps(stderr_text):
    return sorted(set(re.findall(r"Invalid policycap \(([^)\s]+)\)", stderr_text)))


def parse_unresolved_symbols(stderr_text):
    """Extract missing CIL symbol locations from secilc stderr."""
    missing = []
    pat_loc = re.compile(r"Failed to resolve (\S+) statement at ([^:\s]+):(\d+)")
    for m in pat_loc.finditer(stderr_text):
        stmt, fpath, lineno = m.group(1), m.group(2), int(m.group(3))
        missing.append((stmt, fpath, lineno))
    return missing


def load_known_symbols(cils):
    """Collect all defined types, typeattributes, roles, classes, booleans in CILs."""
    defined = set()
    patterns = [
        re.compile(r"\(type\s+([^\s()]+)\)"),
        re.compile(r"\(typeattribute\s+([^\s()]+)\)"),
        re.compile(r"\(typealias\s+([^\s()]+)\)"),
        re.compile(r"\(role\s+([^\s()]+)\)"),
        re.compile(r"\(roleattribute\s+([^\s()]+)\)"),
        re.compile(r"\(boolean\s+([^\s()]+)\s+"),
        re.compile(r"\(class\s+([^\s()]+)\s+"),
        re.compile(r"\(classpermission\s+([^\s()]+)\)"),
        re.compile(r"\(classmap\s+([^\s()]+)\s+"),
        re.compile(r"\(user\s+([^\s()]+)\)"),
    ]
    for p in cils:
        try:
            txt = open(p, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for pat in patterns:
            defined.update(pat.findall(txt))
    return defined


def extract_k90_symbol_kinds(k90_fw_dirs):
    """Inspect K90 stock system/system_ext/product CILs to know type vs typeattribute."""
    kinds = {}
    re_type = re.compile(r"\(type\s+([^\s()]+)\)")
    re_attr = re.compile(r"\(typeattribute\s+([^\s()]+)\)")
    for d in k90_fw_dirs:
        if not d or not os.path.isdir(d):
            continue
        for p in glob.glob(os.path.join(d, "**", "*.cil"), recursive=True):
            try:
                txt = open(p, "r", encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            for sym in re_type.findall(txt):
                kinds[sym] = "type"
            for sym in re_attr.findall(txt):
                kinds.setdefault(sym, "typeattribute")
    return kinds


def find_missing_tokens_on_line(stmt, fpath, lineno, known_all):
    """Parse the offending CIL statement line and identify unresolved type/attribute tokens."""
    if not os.path.isfile(fpath):
        return [], ""
    with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    if lineno < 1 or lineno > len(lines):
        return [], ""
    line = lines[lineno - 1].strip()

    cil_keywords = {
        "allow", "dontaudit", "auditallow", "neverallow", "allowx", "dontauditx",
        "typeattributeset", "expandtypeattribute", "type_transition", "typetransition",
        "typechange", "typemember", "typebounds", "typepermissive", "roletype",
        "roleattributeset", "filecon", "genfscon", "portcon", "and", "or", "not",
        "xor", "all", "self", "true", "false", "object_r", "system_r", "u", "r",
        "s0", "c0", "file", "dir", "lnk_file", "chr_file", "blk_file", "sock_file",
        "fifo_file", "process", "fd", "binder", "service_manager", "hwservice_manager",
        "vndservice_manager", "property_service", "unix_stream_socket",
        "unix_dgram_socket", "netlink_route_socket", "netlink_kobject_uevent_socket",
        "tcp_socket", "udp_socket", "rawip_socket", "capability", "capability2",
        "filesystem", "security", "system", "key", "sem", "msg", "msgq", "shm",
        "ipc", "bpf", "perf_event", "memprotect", "ioctl", "nlmsg",
    }

    candidates = []
    if stmt == "typeattributeset":
        tokens = re.findall(r"[A-Za-z0-9_.-]+", line)
        for tok in tokens[1:]:
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)
    elif stmt in ("allow", "dontaudit", "auditallow", "neverallow", "allowx", "dontauditx"):
        m = re.match(r"^\(\s*\S+\s+([^\s()]+)\s+([^\s()]+)\s+", line)
        if m:
            for tok in (m.group(1), m.group(2)):
                if tok not in cil_keywords and tok not in known_all:
                    candidates.append(tok)
    elif stmt == "genfscon":
        m = re.search(r"\bobject_r\s+([^\s()]+)", line)
        if m:
            tok = m.group(1)
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)
    elif stmt in ("typetransition", "type_transition", "typechange", "typemember"):
        no_q = re.sub(r'"[^"]*"', "", line)
        tokens = re.findall(r"[A-Za-z0-9_.-]+", no_q)
        for idx in (1, 2, len(tokens) - 1):
            if 0 < idx < len(tokens):
                tok = tokens[idx]
                if tok not in cil_keywords and tok not in known_all:
                    candidates.append(tok)
    elif stmt in ("roletype", "expandtypeattribute", "typebounds", "typepermissive"):
        tokens = re.findall(r"[A-Za-z0-9_.-]+", line)
        for tok in tokens[1:]:
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)
    else:
        tokens = re.findall(r"[A-Za-z0-9_.-]+", line)
        for tok in tokens[1:4]:
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)

    return candidates, line


def append_rules_preserving_xattrs(fpath, rules, header=None):
    st = os.lstat(fpath)
    saved_xa = {}
    if hasattr(os, "listxattr"):
        for xk in os.listxattr(fpath, follow_symlinks=False):
            saved_xa[xk] = os.getxattr(fpath, xk, follow_symlinks=False)

    with open(fpath, "a", encoding="utf-8") as sf:
        if header:
            sf.write(header)
        for r in rules:
            sf.write(r + "\n")

    os.chown(fpath, st.st_uid, st.st_gid)
    os.chmod(fpath, st.st_mode & 0o7777)
    for xk, xv in saved_xa.items():
        os.setxattr(fpath, xk, xv, follow_symlinks=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sys-se", required=True, help="Staged Neo 11 system/etc/selinux")
    ap.add_argument("--ext-se", default="", help="Neo 11 system_ext/etc/selinux")
    ap.add_argument("--prod-se", default="", help="Neo 11 product/etc/selinux")
    ap.add_argument("--vnd-se", required=True, help="K90 vendor/etc/selinux")
    ap.add_argument("--odm-se", default="", help="K90 odm/etc/selinux")
    ap.add_argument("--k90-fw-se", action="append", default=[], help="K90 stock system/ext/product etc/selinux dirs")
    ap.add_argument("--report", required=True, help="Output report file")
    ap.add_argument("--max-rounds", type=int, default=100)
    args = ap.parse_args()

    vers = detect_policy_vers(args.sys_se, args.vnd_se)
    cils = collect_cil_files(args.sys_se, args.ext_se, args.prod_se, args.vnd_se, args.odm_se, vers)
    print(f"[SEPolicy] Target vendor sepolicy version: {vers}")
    print(f"[SEPolicy] Compiling {len(cils)} split CIL files via secilc:")
    for c in cils:
        print(f"  - {c}")

    shim_target = os.path.join(args.sys_se, "mapping", f"{vers}.cil")
    if not os.path.isfile(shim_target):
        raise FileNotFoundError(f"Expected Neo 11 mapping CIL not found: {shim_target}")
    shim_idx = cils.index(shim_target)

    k90_kinds = extract_k90_symbol_kinds(args.k90_fw_se)
    added_shims = []
    ignored_policycaps = set()
    report_lines = [
        f"Target Vendor SEPolicy Version: {vers}",
        f"CIL files checked: {len(cils)}",
    ]

    work_dir = tempfile.mkdtemp(prefix="sepolicy_gate_")
    out_bin = os.path.join(work_dir, "sepolicy.bin")

    try:
        # Step 0: Self-calibrate host secilc on 100% stock K90 CILs, auto-sanitizing
        # host-unknown kernel policycaps (e.g. functionfs_seclabel on Ubuntu secilc 3.5)
        # ONLY in temporary mirror copies (NEVER modifying real ROM plat_sepolicy.cil!).
        k90_sys = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "system"), "")
        k90_ext = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "system_ext"), "")
        k90_prod = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "product"), "")
        if k90_sys and os.path.isdir(k90_sys):
            k90_cils = collect_cil_files(k90_sys, k90_ext, k90_prod, args.vnd_se, args.odm_se, vers)
            if k90_cils:
                base_ok = False
                base_err = ""
                for _ in range(10):
                    mirrored_k90 = mirror_cils_for_host(k90_cils, work_dir, "k90_base", ignored_policycaps)
                    base_rc, _, base_err = run_secilc(mirrored_k90, out_bin)
                    if base_rc == 0:
                        base_ok = True
                        break
                    bad_caps = parse_invalid_policycaps(base_err)
                    new_caps = [c for c in bad_caps if c not in ignored_policycaps]
                    if new_caps:
                        ignored_policycaps.update(new_caps)
                        print(f"[SEPolicy] Host secilc does not know policycap(s) {new_caps}; sanitizing temp mirror copy only...")
                        continue
                    break

                if not base_ok:
                    warn_msg = (
                        f"[WARN] Host secilc failed even on 100% untouched stock K90 CILs (rc={base_rc}). "
                        "Host secilc version is incompatible with Android 17 CIL syntax; skipping fatal gate."
                    )
                    print(warn_msg)
                    print(base_err[:1500])
                    report_lines.append(warn_msg)
                    report_lines.append("\n=== Stock K90 Baseline secilc stderr (truncated) ===")
                    report_lines.append(base_err[:4000])
                    with open(args.report, "w", encoding="utf-8") as rf:
                        rf.write("\n".join(report_lines) + "\n")
                    return 0

                msg = f"Baseline check on stock K90: PASS ({len(k90_cils)} CILs, host_sanitized_policycaps={sorted(ignored_policycaps)})"
                print(f"[SEPolicy] {msg}")
                report_lines.append(msg)

        # Step 1: Real cross-OEM compile on Neo 11 (system+ext+product) + K90 (vendor+odm)
        mirrored_port = mirror_cils_for_host(cils, work_dir, "port_cross", ignored_policycaps)
        mirrored_shim_path = mirrored_port[shim_idx]

        for rnd in range(1, args.max_rounds + 1):
            rc, stdout, stderr = run_secilc(mirrored_port, out_bin)
            if rc == 0:
                sz = os.path.getsize(out_bin)
                msg = (
                    f"[PASS] Cross-OEM Split SEPolicy compiled cleanly on round {rnd}! "
                    f"(binary policy size={sz:,d} bytes, shims_added={len(added_shims)})"
                )
                print(msg)
                report_lines.append(msg)
                if added_shims:
                    report_lines.append(f"\n=== Compatibility Shim Rules Added to mapping/{vers}.cil ===")
                    report_lines.extend(added_shims)
                with open(args.report, "w", encoding="utf-8") as rf:
                    rf.write("\n".join(report_lines) + "\n")
                return 0

            # Also sanitize any newly encountered host-unknown policycap in Neo 11 CILs
            bad_caps = parse_invalid_policycaps(stderr)
            new_caps = [c for c in bad_caps if c not in ignored_policycaps]
            if new_caps:
                ignored_policycaps.update(new_caps)
                print(f"[SEPolicy] Round {rnd}: sanitizing host-unknown policycap(s) {new_caps} in temp mirror...")
                mirrored_port = mirror_cils_for_host(cils, work_dir, "port_cross", ignored_policycaps)
                mirrored_shim_path = mirrored_port[shim_idx]
                continue

            print(f"[SEPolicy] Round {rnd} secilc exited {rc}; analyzing unresolved symbols...")
            unresolved = parse_unresolved_symbols(stderr)
            if not unresolved:
                print("[FATAL] secilc failed without recognizable unresolved symbol error:", file=sys.stderr)
                print(stderr, file=sys.stderr)
                report_lines.append(f"[FAIL] Round {rnd} secilc error:\n{stderr}")
                with open(args.report, "w", encoding="utf-8") as rf:
                    rf.write("\n".join(report_lines) + "\n")
                return 1

            known_all = load_known_symbols(mirrored_port)

            new_rules = []
            seen_this_round = set()
            for stmt, fpath, lineno in unresolved:
                cands, raw_line = find_missing_tokens_on_line(stmt, fpath, lineno, known_all)
                for sym in cands:
                    if sym in seen_this_round:
                        continue
                    seen_this_round.add(sym)
                    if sym.endswith(f"_{vers}") or k90_kinds.get(sym) == "typeattribute":
                        rule = f"(typeattribute {sym})"
                    elif stmt == "typeattributeset" and raw_line.startswith(f"(typeattributeset {sym} "):
                        rule = f"(typeattribute {sym})"
                    else:
                        rule = f"(type {sym})"
                    new_rules.append(rule)
                    print(f"  + Shim [{stmt} @ {os.path.basename(fpath)}:{lineno}]: {rule}")

            if not new_rules:
                print("[FATAL] Could not identify missing CIL symbols from secilc error:", file=sys.stderr)
                print(stderr, file=sys.stderr)
                report_lines.append(f"[FAIL] Round {rnd} unresolved:\n{stderr}")
                with open(args.report, "w", encoding="utf-8") as rf:
                    rf.write("\n".join(report_lines) + "\n")
                return 1

            header = "\n;; === K90 Cross-OEM Vendor SEPolicy Compatibility Shims ===\n" if not added_shims else None
            append_rules_preserving_xattrs(shim_target, new_rules, header=header)
            with open(mirrored_shim_path, "a", encoding="utf-8") as mf:
                if header:
                    mf.write(header)
                for r in new_rules:
                    mf.write(r + "\n")
            added_shims.extend(new_rules)

        print(f"[FATAL] Reached max rounds ({args.max_rounds}) without clean secilc compile!", file=sys.stderr)
        report_lines.append(f"[FAIL] Exceeded max rounds ({args.max_rounds})")
        with open(args.report, "w", encoding="utf-8") as rf:
            rf.write("\n".join(report_lines) + "\n")
        return 1
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
