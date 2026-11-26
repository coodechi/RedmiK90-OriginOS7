#!/usr/bin/env python3
"""
Lossless EROFS staging, SELinux/capability xattr preservation, fixup, and
post-pack mount verification tool for Android ROM porting on Linux runners.

Commands:
  copy   <src_mnt> <dst_dir> [--override-selinux <ctx>]
  fixup  <root_dir> --default-selinux <ctx>
  verify <erofs_img> [--expect-file <relpath> ...] [--min-selinux-ratio 0.99]
"""

import argparse
import errno
import os
import shutil
import stat
import subprocess
import sys
import tempfile


def get_xattrs(path):
    res = {}
    try:
        names = os.listxattr(path, follow_symlinks=False)
    except OSError as e:
        if e.errno in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENODATA):
            return res
        raise
    for name in names:
        try:
            res[name] = os.getxattr(path, name, follow_symlinks=False)
        except OSError:
            pass
    return res


def set_xattrs(path, xattrs, override_selinux=None):
    merged = dict(xattrs)
    if override_selinux is not None:
        merged["security.selinux"] = override_selinux.encode("utf-8") + b"\x00"
    for name, val in merged.items():
        try:
            os.setxattr(path, name, val, follow_symlinks=False)
        except OSError as e:
            if name == "security.selinux":
                raise RuntimeError(
                    f"FATAL: Failed to set security.selinux on {path}: {e}. "
                    f"Ensure staging directory is on ext4/xfs (not tmpfs/overlay) and running as root!"
                ) from e
            print(f"[WARN] Could not set xattr {name} on {path}: {e}", file=sys.stderr)


def copy_tree_lossless(src_root, dst_root, override_selinux=None):
    src_root = os.path.abspath(src_root)
    dst_root = os.path.abspath(dst_root)
    os.makedirs(dst_root, exist_ok=True)

    # Probe destination xattr capability immediately (fail-fast!)
    probe = os.path.join(dst_root, ".xattr_probe")
    with open(probe, "wb") as f:
        f.write(b"ok")
    try:
        os.setxattr(probe, "security.selinux", b"u:object_r:system_file:s0\x00", follow_symlinks=False)
        got = os.getxattr(probe, "security.selinux", follow_symlinks=False)
        assert b"system_file" in got
    except Exception as e:
        os.unlink(probe)
        raise RuntimeError(f"Staging filesystem at {dst_root} does not support security.selinux xattrs: {e}") from e
    os.unlink(probe)

    dir_meta = []  # (dst_dir, st, xattrs) applied bottom-up so mtime/readonly modes don't block creation
    inode_map = {}  # (st_dev, st_ino) -> dst_path for hardlinks
    stats = {"dirs": 0, "files": 0, "links": 0, "hardlinks": 0, "selinux_copied": 0}

    # Copy root dir metadata
    root_st = os.lstat(src_root)
    root_xattrs = get_xattrs(src_root)
    dir_meta.append((dst_root, root_st, root_xattrs))

    for cur_dir, dirs, files in os.walk(src_root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(cur_dir, src_root)
        target_dir = dst_root if rel_dir == "." else os.path.join(dst_root, rel_dir)

        for d in dirs:
            sp = os.path.join(cur_dir, d)
            dp = os.path.join(target_dir, d)
            st = os.lstat(sp)
            if stat.S_ISLNK(st.st_mode):
                # Directory symlink
                if os.path.lexists(dp):
                    os.unlink(dp)
                os.symlink(os.readlink(sp), dp)
                os.lchown(dp, st.st_uid, st.st_gid)
                xa = get_xattrs(sp)
                set_xattrs(dp, xa, override_selinux)
                stats["links"] += 1
                if "security.selinux" in xa or override_selinux:
                    stats["selinux_copied"] += 1
            else:
                os.makedirs(dp, exist_ok=True)
                os.chmod(dp, 0o755)  # Writable while populating; restored bottom-up
                xa = get_xattrs(sp)
                dir_meta.append((dp, st, xa))
                stats["dirs"] += 1
                if "security.selinux" in xa or override_selinux:
                    stats["selinux_copied"] += 1

        for fn in files:
            sp = os.path.join(cur_dir, fn)
            dp = os.path.join(target_dir, fn)
            st = os.lstat(sp)
            xa = get_xattrs(sp)

            if os.path.lexists(dp):
                if os.path.isdir(dp) and not os.path.islink(dp):
                    shutil.rmtree(dp)
                else:
                    os.unlink(dp)

            if stat.S_ISLNK(st.st_mode):
                os.symlink(os.readlink(sp), dp)
                os.lchown(dp, st.st_uid, st.st_gid)
                set_xattrs(dp, xa, override_selinux)
                stats["links"] += 1
            elif stat.S_ISREG(st.st_mode):
                key = (st.st_dev, st.st_ino)
                if st.st_nlink > 1 and key in inode_map:
                    os.link(inode_map[key], dp)
                    stats["hardlinks"] += 1
                else:
                    with open(sp, "rb") as fsrc, open(dp, "wb") as fdst:
                        shutil.copyfileobj(fsrc, fdst, length=1024 * 1024)
                    os.lchown(dp, st.st_uid, st.st_gid)
                    os.chmod(dp, stat.S_IMODE(st.st_mode))
                    set_xattrs(dp, xa, override_selinux)
                    os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
                    if st.st_nlink > 1:
                        inode_map[key] = dp
                    stats["files"] += 1
            elif stat.S_ISFIFO(st.st_mode):
                os.mkfifo(dp, stat.S_IMODE(st.st_mode))
                os.lchown(dp, st.st_uid, st.st_gid)
                set_xattrs(dp, xa, override_selinux)
            else:
                print(f"[WARN] Skipping special node: {sp} (mode={oct(st.st_mode)})", file=sys.stderr)
                continue

            if "security.selinux" in xa or override_selinux:
                stats["selinux_copied"] += 1

    # Apply directory ownership, mode, xattrs, and timestamps bottom-up
    for dp, st, xa in reversed(dir_meta):
        os.lchown(dp, st.st_uid, st.st_gid)
        os.chmod(dp, stat.S_IMODE(st.st_mode))
        set_xattrs(dp, xa, override_selinux)
        try:
            os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
        except OSError:
            pass

    print(
        f"[OK] Lossless copy {src_root} -> {dst_root}: "
        f"dirs={stats['dirs']}, files={stats['files']}, links={stats['links']}, "
        f"hardlinks={stats['hardlinks']}, selinux_labeled={stats['selinux_copied']}"
    )


def fixup_missing_selinux(root_dir, default_ctx):
    root_dir = os.path.abspath(root_dir)
    ctx_bytes = default_ctx.encode("utf-8") + b"\x00"
    fixed = 0
    total = 0

    def ensure(path):
        nonlocal fixed, total
        total += 1
        try:
            val = os.getxattr(path, "security.selinux", follow_symlinks=False)
            if val and val.strip(b"\x00"):
                return
        except OSError:
            pass
        os.setxattr(path, "security.selinux", ctx_bytes, follow_symlinks=False)
        fixed += 1

    ensure(root_dir)
    for cur_dir, dirs, files in os.walk(root_dir, topdown=True, followlinks=False):
        for d in dirs:
            ensure(os.path.join(cur_dir, d))
        for fn in files:
            ensure(os.path.join(cur_dir, fn))

    print(f"[OK] SELinux fixup on {root_dir}: total_inodes={total}, fixed_missing={fixed} (default={default_ctx})")


def verify_erofs_image(img_path, expect_files, min_selinux_ratio):
    img_path = os.path.abspath(img_path)
    if not os.path.isfile(img_path):
        raise FileNotFoundError(f"EROFS image not found: {img_path}")

    mnt = tempfile.mkdtemp(prefix="erofs_verify_")
    try:
        subprocess.run(
            ["mount", "-t", "erofs", "-o", "ro,loop", img_path, mnt],
            check=True,
        )
        # Verify expected files exist and report their SELinux labels
        for rel in expect_files:
            full = os.path.join(mnt, rel.lstrip("/"))
            if not os.path.lexists(full):
                raise RuntimeError(f"Expected path missing in {img_path}: {rel}")
            xa = get_xattrs(full)
            se = xa.get("security.selinux", b"").rstrip(b"\x00").decode("utf-8", errors="replace")
            if not se:
                raise RuntimeError(f"Expected path missing security.selinux in {img_path}: {rel}")
            print(f"  [VERIFIED] /{rel.lstrip('/')}  selinux={se}")

        total = 0
        labeled = 0
        caps = 0
        for cur_dir, dirs, files in os.walk(mnt, topdown=True, followlinks=False):
            entries = [cur_dir] + [os.path.join(cur_dir, f) for f in files]
            for p in entries:
                total += 1
                xa = get_xattrs(p)
                if xa.get("security.selinux", b"").strip(b"\x00"):
                    labeled += 1
                if "security.capability" in xa:
                    caps += 1
            for d in dirs:
                dp = os.path.join(cur_dir, d)
                if os.path.islink(dp):
                    total += 1
                    xa = get_xattrs(dp)
                    if xa.get("security.selinux", b"").strip(b"\x00"):
                        labeled += 1

        ratio = (labeled / total) if total else 1.0
        size_mb = os.path.getsize(img_path) / (1024 * 1024)
        print(
            f"[OK] Verified {os.path.basename(img_path)} ({size_mb:.2f} MiB): "
            f"inodes={total}, selinux_labeled={labeled} ({ratio*100:.2f}%), capabilities={caps}"
        )
        if ratio < min_selinux_ratio:
            raise RuntimeError(
                f"SELinux label coverage {ratio*100:.2f}% below threshold {min_selinux_ratio*100:.2f}%!"
            )
    finally:
        subprocess.run(["umount", mnt], check=False)
        os.rmdir(mnt)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_copy = sub.add_parser("copy")
    p_copy.add_argument("src_mnt")
    p_copy.add_argument("dst_dir")
    p_copy.add_argument("--override-selinux", default=None)

    p_fix = sub.add_parser("fixup")
    p_fix.add_argument("root_dir")
    p_fix.add_argument("--default-selinux", required=True)

    p_ver = sub.add_parser("verify")
    p_ver.add_argument("erofs_img")
    p_ver.add_argument("--expect-file", action="append", default=[])
    p_ver.add_argument("--min-selinux-ratio", type=float, default=0.99)

    args = ap.parse_args()
    if args.cmd == "copy":
        copy_tree_lossless(args.src_mnt, args.dst_dir, args.override_selinux)
    elif args.cmd == "fixup":
        fixup_missing_selinux(args.root_dir, args.default_selinux)
    elif args.cmd == "verify":
        verify_erofs_image(args.erofs_img, args.expect_file, args.min_selinux_ratio)


if __name__ == "__main__":
    main()
