#!/usr/bin/env python3
"""
Build a raw Android liblp super.img (lpmake equivalent, dependency-free).

Validated against the stock REDMI K90 super.img: geometry / header / tables
SHA-256 checksums and table offsets match byte-for-byte.

Usage:
  make_super.py build <out.img> \
      --part odm_a=<path> --part vendor_a=<path> ... \
      [--empty system_b] [--super-size N] [--group-max N]
"""
import argparse
import hashlib
import os
import struct
import sys

SECTOR = 512
GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
GEOM_OFF = 4096
GEOM_SIZE = 4096          # reserved size of each geometry slot
GEOM_STRUCT = 52
HDR_SIZE = 256
META_MAX = 65536
SLOT_COUNT = 3
SUPER_SIZE = 13421772800            # 12.5 GiB physical super partition
GROUP_MAX = 13411287040             # 12.49 GiB dynamic group cap
FIRST_LOGICAL_SECTOR = 2048         # 1 MiB
ALIGN = 1048576                     # 1 MiB
LOGICAL_BLOCK = 4096


def pad36(s):
    b = s.encode("utf-8")
    if len(b) > 35:
        raise ValueError(f"partition name too long: {s}")
    return b + b"\x00" * (36 - len(b))


def align_up(x, a):
    return (x + a - 1) // a * a


def build(out, parts, super_size=SUPER_SIZE, group_a_max=GROUP_MAX,
          group_b_max=GROUP_MAX, super_name="super", meta_max=META_MAX,
          slot_count=SLOT_COUNT):
    """parts: list of (name, path_or_None, group_index), in metadata order."""
    data_off = FIRST_LOGICAL_SECTOR * SECTOR
    extents = []
    pentries = []
    for name, path, gi in parts:
        if path:
            size = os.path.getsize(path)
            nsectors = (size + SECTOR - 1) // SECTOR
            data_off = align_up(data_off, ALIGN)
            target = data_off // SECTOR
            extents.append((nsectors, 0, target, 0))
            fe, ne = len(extents) - 1, 1
            data_off += nsectors * SECTOR
        else:
            fe, ne = len(extents), 0          # match stock: next extent index
        pentries.append((name, 1, fe, ne, gi))   # attr=1 (READONLY)

    if data_off > super_size:
        raise SystemExit(f"[FATAL] data ends at {data_off}, exceeds super {super_size}")

    ptab = b"".join(struct.pack("<36sIIII", pad36(n), a, fe, ne, gi)
                    for (n, a, fe, ne, gi) in pentries)
    etab = b"".join(struct.pack("<QIQI", *e) for e in extents)
    groups = [("default", 0, 0),
              ("qti_dynamic_partitions_a", 0, group_a_max),
              ("qti_dynamic_partitions_b", 0, group_b_max)]
    gtab = b"".join(struct.pack("<36sIQ", pad36(n), f, m) for (n, f, m) in groups)
    btab = struct.pack("<QIIQ36sI", FIRST_LOGICAL_SECTOR, ALIGN, 0,
                       super_size, pad36(super_name), 0)

    tables = ptab + etab + gtab + btab
    if len(tables) > meta_max:
        raise SystemExit(f"[FATAL] tables {len(tables)} > meta_max {meta_max}")

    part_paths = {n: p for (n, p, _gi) in parts}

    hdr = bytearray(HDR_SIZE)
    struct.pack_into("<IHHI", hdr, 0, HDR_MAGIC, 10, 2, HDR_SIZE)
    struct.pack_into("<I", hdr, 44, len(tables))
    hdr[48:80] = hashlib.sha256(tables).digest()
    struct.pack_into("<III", hdr, 80, 0, len(pentries), 52)
    struct.pack_into("<III", hdr, 92, len(ptab), len(extents), 24)
    struct.pack_into("<III", hdr, 104, len(ptab) + len(etab), len(groups), 48)
    struct.pack_into("<III", hdr, 116, len(ptab) + len(etab) + len(gtab), 1, 64)
    struct.pack_into("<I", hdr, 128, 1)      # flags = VIRTUAL_AB (matches stock)
    hdr[12:44] = b"\x00" * 32
    hdr[12:44] = hashlib.sha256(bytes(hdr)).digest()

    geo = bytearray(GEOM_STRUCT)
    struct.pack_into("<II", geo, 0, GEOM_MAGIC, GEOM_STRUCT)
    struct.pack_into("<III", geo, 40, meta_max, slot_count, LOGICAL_BLOCK)
    geo[8:40] = b"\x00" * 32
    geo[8:40] = hashlib.sha256(bytes(geo)).digest()

    print(f"[build] {out}")
    print(f"  partitions={len(pentries)} extents={len(extents)} tables={len(tables)}")
    print(f"  data_end={data_off} ({data_off/1024**3:.2f} GiB) / super={super_size} "
          f"({super_size/1024**3:.2f} GiB) headroom={(super_size-data_off)/1024**2:.1f} MiB")

    with open(out, "wb") as f:
        f.truncate(super_size)                       # sparse file on APFS
        f.seek(GEOM_OFF); f.write(geo)
        f.seek(GEOM_OFF + GEOM_SIZE); f.write(geo)
        for i in range(slot_count * 2):      # primary slots + backup slots (stock has 6)
            f.seek(GEOM_OFF + GEOM_SIZE * 2 + i * meta_max)
            f.write(bytes(hdr))
            f.write(tables)
        for (name, attr, fe, ne, gi) in pentries:
            if ne == 0:
                continue
            e = extents[fe]
            path = part_paths[name]
            f.seek(e[2] * SECTOR)
            print(f"  + {name:<14s} {os.path.getsize(path)/1024**2:9.2f} MiB @ sector {e[2]}")
            with open(path, "rb") as src:
                while True:
                    buf = src.read(8 * 1024 * 1024)
                    if not buf:
                        break
                    f.write(buf)
    print("[build] done")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("out")
    b.add_argument("--part", action="append", default=[], metavar="NAME=PATH")
    b.add_argument("--empty", action="append", default=[], metavar="NAME")
    b.add_argument("--super-size", type=int, default=SUPER_SIZE)
    b.add_argument("--group-max", type=int, default=GROUP_MAX)
    b.add_argument("--order", default="", help="comma list of names to define order")
    args = ap.parse_args()

    if args.cmd != "build":
        ap.print_help(); sys.exit(1)

    part_map = {}
    for spec in args.part:
        name, _, path = spec.partition("=")
        if not _ or not os.path.isfile(path):
            raise SystemExit(f"[FATAL] bad --part {spec}")
        part_map[name] = path
    for name in args.empty:
        part_map[name] = None

    order = [x for x in args.order.split(",") if x] or sorted(part_map)
    missing = set(part_map) - set(order)
    order += sorted(missing)

    parts = []
    for name in order:
        if name in part_map:
            gi = 2 if name.endswith("_b") else 1
            parts.append((name, part_map[name], gi))

    build(args.out, parts, super_size=args.super_size,
          group_a_max=args.group_max, group_b_max=args.group_max)


if __name__ == "__main__":
    main()
