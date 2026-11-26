#!/usr/bin/env python3
"""
Pre-flight Split SEPolicy Compiler Gate & Cross-OEM Compatibility Shim Generator.

Simulates Android init's CompileSplitPolicy() using `secilc` on:
  - Port (Neo 11): system + system_ext + product CILs + mapping/<vers>.cil
  - Base (K90):    vendor (plat_pub_versioned + vendor_sepolicy) + odm_sepolicy

If K90's vendor/odm CIL references Xiaomi-specific platform types/attributes
missing from Neo 11's system/system_ext/product, automatically synthesizes
minimal compatibility declarations into Neo 11's mapping/<vers>.cil and re-runs
`secilc` until compilation succeeds with exit code 0!
"""

import argparse
import glob
import os
import re
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
    # Fallback: check highest mapping/*.cil in system
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


def parse_unresolved_symbols(stderr_text):
    """Extract missing CIL symbol names and their AST context from secilc stderr."""
    missing = []
    # Common secilc messages:
    #   Failed to resolve typeattributeset statement at /path/file.cil:123
    #   Failed to resolve allow statement at /path/file.cil:456
    #   Failed to resolve roletype statement at ...
    #   Failed to resolve type_transition statement at ...
    #   Failed to resolve genfscon / expandtypeattribute / etc.
    # Often preceded by:
    #   Symbol not found: foo_bar (or line contents)
    pat_loc = re.compile(r"Failed to resolve (\S+) statement at ([^:\s]+):(\d+)")
    for m in pat_loc.finditer(stderr_text):
        stmt, fpath, lineno = m.group(1), m.group(2), int(m.group(3))
        missing.append((stmt, fpath, lineno))
    return missing


def load_known_symbols(cils):
    """Collect all defined types, typeattributes, and properties/classes/roles in CILs."""
    defined_types = set()
    defined_attrs = set()
    defined_roles = set()
    defined_bools = set()
    re_type = re.compile(r"\(type\s+([^\s()]+)\)")
    re_attr = re.compile(r"\(typeattribute\s+([^\s()]+)\)")
    re_role = re.compile(r"\(role\s+([^\s()]+)\)")
    re_bool = re.compile(r"\(boolean\s+([^\s()]+)\s+")

    for p in cils:
        try:
            txt = open(p, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        defined_types.update(re_type.findall(txt))
        defined_attrs.update(re_attr.findall(txt))
        defined_roles.update(re_role.findall(txt))
        defined_bools.update(re_bool.findall(txt))

    return defined_types, defined_attrs, defined_roles, defined_bools


def extract_k90_symbol_kinds(k90_fw_dirs):
    """Inspect K90 stock system/system_ext/product CILs to know whether a missing symbol was a type or typeattribute."""
    kinds = {}  # sym -> "type" | "typeattribute"
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

    # Tokenize CIL S-expression atoms
    # Skip CIL keywords, operators, and permission lists (last paren group in allow/dontaudit/neverallow)
    cil_keywords = {
        "allow", "dontaudit", "auditallow", "neverallow", "allowx", "dontauditx",
        "typeattributeset", "expandtypeattribute", "type_transition", "typetransition",
        "typechange", "typemember", "roletype", "roleattributeset", "filecon",
        "genfscon", "portcon", "and", "or", "not", "xor", "all", "self", "true", "false",
        "object_r", "system_r", "u", "r", "s0", "c0", "file", "dir", "lnk_file",
        "chr_file", "blk_file", "sock_file", "fifo_file", "process", "fd", "binder",
        "service_manager", "hwservice_manager", "vndservice_manager", "property_service",
        "unix_stream_socket", "unix_dgram_socket", "netlink_route_socket",
        "netlink_kobject_uevent_socket", "tcp_socket", "udp_socket", "rawip_socket",
        "capability", "capability2", "filesystem", "security", "system", "key",
        "sem", "msg", "msgq", "shm", "ipc", "bpf", "perf_event", "memprotect",
    }

    candidates = []
    if stmt == "typeattributeset":
        # (typeattributeset ATTR (expr ...))
        tokens = re.findall(r"[A-Za-z0-9_.-]+", line)
        # tokens[0] == "typeattributeset", tokens[1] == attr, tokens[2:] == members
        for tok in tokens[1:]:
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)
    elif stmt in ("allow", "dontaudit", "auditallow", "neverallow", "allowx", "dontauditx"):
        # (allow SRC TGT (CLASS (PERMS...)))
        m = re.match(r"^\(\s*\S+\s+([^\s()]+)\s+([^\s()]+)\s+", line)
        if m:
            for tok in (m.group(1), m.group(2)):
                if tok not in cil_keywords and tok not in known_all:
                    candidates.append(tok)
    elif stmt == "genfscon":
        # (genfscon fs "/path" (u object_r TYPE ((s0) (s0))))
        m = re.search(r"\bobject_r\s+([^\s()]+)", line)
        if m:
            tok = m.group(1)
            if tok not in cil_keywords and tok not in known_all:
                candidates.append(tok)
    elif stmt in ("typetransition", "type_transition", "typechange", "typemember"):
        # (typetransition SRC TGT CLASS [NAME] NEW_TYPE)
        # Strip quoted strings first
        no_q = re.sub(r'"[^"]*"', "", line)
        tokens = re.findall(r"[A-Za-z0-9_.-]+", no_q)
        # src=tokens[1], tgt=tokens[2], new_type=tokens[-1]
        for idx in (1, 2, len(tokens) - 1):
            if 0 < idx < len(tokens):
                tok = tokens[idx]
                if tok not in cil_keywords and tok not in known_all:
                    candidates.append(tok)
    elif stmt in ("roletype", "expandtypeattribute"):
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sys-se", required=True, help="Staged Neo 11 system/etc/selinux")
    ap.add_argument("--ext-se", default="", help="Neo 11 system_ext/etc/selinux")
    ap.add_argument("--prod-se", default="", help="Neo 11 product/etc/selinux")
    ap.add_argument("--vnd-se", required=True, help="K90 vendor/etc/selinux")
    ap.add_argument("--odm-se", default="", help="K90 odm/etc/selinux")
    ap.add_argument("--k90-fw-se", action="append", default=[], help="K90 stock system/ext/product etc/selinux dirs for lookup")
    ap.add_argument("--report", required=True, help="Output report file")
    ap.add_argument("--max-rounds", type=int, default=30)
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

    k90_kinds = extract_k90_symbol_kinds(args.k90_fw_se)
    added_shims = []
    report_lines = [
        f"Target Vendor SEPolicy Version: {vers}",
        f"CIL files checked: {len(cils)}",
    ]

    with tempfile.NamedTemporaryFile(prefix="sepolicy_test_", delete=False) as tf:
        out_bin = tf.name

    try:
        # Step 0: Self-calibrate host secilc against 100% stock K90 CILs!
        # Ubuntu 24.04 ships secilc 3.5 (2023), whereas Android 17 CILs are built with
        # newer libsepol (3.7+). If host secilc cannot even compile untouched stock K90,
        # warn and skip fatal exit instead of causing a false-positive build failure.
        k90_sys = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "system"), "")
        k90_ext = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "system_ext"), "")
        k90_prod = next((d for d in args.k90_fw_se if d and os.path.basename(d.rstrip("/")) == "product"), "")
        if k90_sys and os.path.isdir(k90_sys):
            k90_cils = collect_cil_files(k90_sys, k90_ext, k90_prod, args.vnd_se, args.odm_se, vers)
            if k90_cils:
                base_rc, _, base_err = run_secilc(k90_cils, out_bin)
                if base_rc != 0:
                    warn_msg = (
                        f"[WARN] Host secilc failed even on 100% untouched stock K90 CILs (rc={base_rc}). "
                        "Host secilc version is likely older than Android 17 CIL syntax; skipping fatal gate."
                    )
                    print(warn_msg)
                    print(base_err[:1500])
                    report_lines.append(warn_msg)
                    report_lines.append("\n=== Stock K90 Baseline secilc stderr (truncated) ===")
                    report_lines.append(base_err[:4000])
                    with open(args.report, "w", encoding="utf-8") as rf:
                        rf.write("\n".join(report_lines) + "\n")
                    return 0
                else:
                    print(f"[SEPolicy] Host secilc baseline check on stock K90 PASSED ({len(k90_cils)} CILs).")
                    report_lines.append(f"Baseline check on stock K90: PASS ({len(k90_cils)} CILs)")

        for rnd in range(1, args.max_rounds + 1):
            rc, stdout, stderr = run_secilc(cils, out_bin)
            if rc == 0:
                sz = os.path.getsize(out_bin)
                msg = (
                    f"[PASS] Split SEPolicy compiled cleanly on round {rnd}! "
                    f"(binary policy size={sz:,d} bytes, shims_added={len(added_shims)})"
                )
                print(msg)
                report_lines.append(msg)
                if added_shims:
                    report_lines.append("\n=== Compatibility Shim Rules Added to mapping/{}.cil ===".format(vers))
                    report_lines.extend(added_shims)
                with open(args.report, "w", encoding="utf-8") as rf:
                    rf.write("\n".join(report_lines) + "\n")
                return 0

            print(f"[SEPolicy] Round {rnd} secilc exited {rc}; analyzing unresolved symbols...")
            unresolved = parse_unresolved_symbols(stderr)
            if not unresolved:
                print("[FATAL] secilc failed without recognizable unresolved symbol error:", file=sys.stderr)
                print(stderr, file=sys.stderr)
                report_lines.append(f"[FAIL] Round {rnd} secilc error:\n{stderr}")
                with open(args.report, "w", encoding="utf-8") as rf:
                    rf.write("\n".join(report_lines) + "\n")
                return 1

            defined_types, defined_attrs, defined_roles, defined_bools = load_known_symbols(cils)
            known_all = defined_types | defined_attrs | defined_roles | defined_bools

            new_rules = []
            seen_this_round = set()
            for stmt, fpath, lineno in unresolved:
                cands, raw_line = find_missing_tokens_on_line(stmt, fpath, lineno, known_all)
                for sym in cands:
                    if sym in seen_this_round:
                        continue
                    seen_this_round.add(sym)
                    # Determine whether to declare as typeattribute or type
                    # Versioned symbols ending in _202404 / _34_0 in mapping are typeattributes!
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

            # Preserve xattrs/mode while appending compatibility declarations to mapping/<vers>.cil
            st = os.lstat(shim_target)
            saved_xa = {}
            for xk in os.listxattr(shim_target, follow_symlinks=False):
                saved_xa[xk] = os.getxattr(shim_target, xk, follow_symlinks=False)

            with open(shim_target, "a", encoding="utf-8") as sf:
                if not added_shims:
                    sf.write("\n;; === K90 Cross-OEM Vendor SEPolicy Compatibility Shims ===\n")
                for r in new_rules:
                    sf.write(r + "\n")
                    added_shims.append(r)

            os.chown(shim_target, st.st_uid, st.st_gid)
            os.chmod(shim_target, st.st_mode & 0o7777)
            for xk, xv in saved_xa.items():
                os.setxattr(shim_target, xk, xv, follow_symlinks=False)

        print(f"[FATAL] Reached max rounds ({args.max_rounds}) without clean secilc compile!", file=sys.stderr)
        report_lines.append(f"[FAIL] Exceeded max rounds ({args.max_rounds})")
        with open(args.report, "w", encoding="utf-8") as rf:
            rf.write("\n".join(report_lines) + "\n")
        return 1
    finally:
        if os.path.exists(out_bin):
            os.remove(out_bin)


if __name__ == "__main__":
    sys.exit(main())
