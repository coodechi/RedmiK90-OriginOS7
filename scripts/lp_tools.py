#!/usr/bin/env python3
"""
Minimal, dependency-free Android liblp (super.img) inspector & unpacker.
Supports lpdump and lpunpack on raw (non-sparse) super images.
"""

import os
import struct
import sys

LP_PARTITION_RESERVED_BYTES = 4096
LP_METADATA_GEOMETRY_MAGIC = 0x616C4467
LP_METADATA_GEOMETRY_SIZE = 4096
LP_METADATA_HEADER_MAGIC = 0x414C5030
LP_SECTOR_SIZE = 512

LP_TARGET_TYPE_LINEAR = 0
LP_TARGET_TYPE_ZERO = 1


def read_geometry(f):
    for offset in (LP_PARTITION_RESERVED_BYTES, LP_PARTITION_RESERVED_BYTES + LP_METADATA_GEOMETRY_SIZE):
        f.seek(offset)
        buf = f.read(52)
        magic, struct_size, checksum, metadata_max_size, metadata_slot_count, logical_block_size = (
            struct.unpack("<II32sIII", buf)
        )
        if magic == LP_METADATA_GEOMETRY_MAGIC:
            return {
                "offset": offset,
                "struct_size": struct_size,
                "metadata_max_size": metadata_max_size,
                "metadata_slot_count": metadata_slot_count,
                "logical_block_size": logical_block_size,
            }
    raise RuntimeError("LP_METADATA_GEOMETRY_MAGIC not found (is super.img still sparse?)")


def parse_table_desc(buf, offset):
    return struct.unpack_from("<III", buf, offset)  # offset, num_entries, entry_size


def read_metadata(f, geom, slot=0):
    meta_offset = (
        LP_PARTITION_RESERVED_BYTES
        + LP_METADATA_GEOMETRY_SIZE * 2
        + slot * geom["metadata_max_size"]
    )
    f.seek(meta_offset)
    hdr = f.read(256)
    magic, major, minor, header_size = struct.unpack_from("<IHHI", hdr, 0)
    if magic != LP_METADATA_HEADER_MAGIC:
        raise RuntimeError(f"Invalid LP metadata header magic: 0x{magic:08x}")

    # Table descriptors start at byte 80 (after magic/ver/header_size/header_checksum(32)/tables_size/tables_checksum(32))
    partitions_td = parse_table_desc(hdr, 80)
    extents_td = parse_table_desc(hdr, 92)
    groups_td = parse_table_desc(hdr, 104)
    block_devices_td = parse_table_desc(hdr, 116)

    tables_size = struct.unpack_from("<I", hdr, 44)[0]
    f.seek(meta_offset + header_size)
    tables = f.read(tables_size)

    def read_entries(td):
        off, count, esize = td
        return [tables[off + i * esize : off + (i + 1) * esize] for i in range(count)]

    groups = []
    for raw in read_entries(groups_td):
        name_raw, flags, max_size = struct.unpack_from("<36sIQ", raw, 0)
        groups.append({
            "name": name_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace"),
            "flags": flags,
            "maximum_size": max_size,
        })

    block_devices = []
    for raw in read_entries(block_devices_td):
        first_logical_sector, alignment, alignment_offset, size, name_raw, flags = struct.unpack_from(
            "<QIIQ36sI", raw, 0
        )
        block_devices.append({
            "first_logical_sector": first_logical_sector,
            "alignment": alignment,
            "alignment_offset": alignment_offset,
            "size": size,
            "name": name_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace"),
            "flags": flags,
        })

    extents = []
    for raw in read_entries(extents_td):
        num_sectors, target_type, target_data, target_source = struct.unpack_from("<QIQI", raw, 0)
        extents.append({
            "num_sectors": num_sectors,
            "target_type": target_type,
            "target_data": target_data,
            "target_source": target_source,
        })

    partitions = []
    for raw in read_entries(partitions_td):
        name_raw, attrs, first_extent_idx, num_extents, group_idx = struct.unpack_from("<36sIIII", raw, 0)
        p_extents = extents[first_extent_idx : first_extent_idx + num_extents]
        total_sectors = sum(e["num_sectors"] for e in p_extents)
        partitions.append({
            "name": name_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace"),
            "attributes": attrs,
            "group_index": group_idx,
            "group_name": groups[group_idx]["name"] if group_idx < len(groups) else str(group_idx),
            "extents": p_extents,
            "size_bytes": total_sectors * LP_SECTOR_SIZE,
        })

    return {
        "major": major,
        "minor": minor,
        "header_size": header_size,
        "groups": groups,
        "block_devices": block_devices,
        "partitions": partitions,
    }


def cmd_dump(super_path):
    with open(super_path, "rb") as f:
        geom = read_geometry(f)
        meta = read_metadata(f, geom, slot=0)

    print(f"Metadata version: {meta['major']}.{meta['minor']}")
    print(f"Metadata max size: {geom['metadata_max_size']}")
    print(f"Metadata slot count: {geom['metadata_slot_count']}")
    print(f"Logical block size: {geom['logical_block_size']}")
    print("\nBlock device table:")
    for bd in meta["block_devices"]:
        print(
            f"  name={bd['name']} size={bd['size']} ({bd['size'] / 1024**3:.2f} GiB) "
            f"first_logical_sector={bd['first_logical_sector']} alignment={bd['alignment']}"
        )

    print("\nPartition groups:")
    for g in meta["groups"]:
        print(
            f"  name={g['name']} maximum_size={g['maximum_size']} "
            f"({g['maximum_size'] / 1024**3:.2f} GiB)"
        )

    print("\nPartitions:")
    total = 0
    for p in meta["partitions"]:
        sz = p["size_bytes"]
        total += sz
        print(
            f"  {p['name']:<24s} group={p['group_name']:<28s} "
            f"size={sz:12d} bytes ({sz / 1024**2:8.2f} MiB) extents={len(p['extents'])}"
        )
    print(f"\nTotal allocated logical partitions: {total} bytes ({total / 1024**3:.2f} GiB)")


def cmd_unpack(super_path, out_dir, only_parts=None):
    os.makedirs(out_dir, exist_ok=True)
    with open(super_path, "rb") as f:
        geom = read_geometry(f)
        meta = read_metadata(f, geom, slot=0)

        for p in meta["partitions"]:
            name = p["name"]
            if only_parts and name not in only_parts:
                continue
            if p["size_bytes"] == 0:
                print(f"Skipping empty partition: {name}")
                continue
            out_path = os.path.join(out_dir, f"{name}.img")
            print(f"Unpacking {name} ({p['size_bytes'] / 1024**2:.2f} MiB) -> {out_path}")
            with open(out_path, "wb") as out_f:
                for ext in p["extents"]:
                    nbytes = ext["num_sectors"] * LP_SECTOR_SIZE
                    if ext["target_type"] == LP_TARGET_TYPE_ZERO:
                        rem = nbytes
                        zeros = b"\x00" * (1024 * 1024)
                        while rem > 0:
                            chunk = min(rem, len(zeros))
                            out_f.write(zeros[:chunk])
                            rem -= chunk
                    elif ext["target_type"] == LP_TARGET_TYPE_LINEAR:
                        f.seek(ext["target_data"] * LP_SECTOR_SIZE)
                        rem = nbytes
                        while rem > 0:
                            chunk = min(rem, 4 * 1024 * 1024)
                            data = f.read(chunk)
                            if not data:
                                raise EOFError(f"Unexpected EOF reading {name}")
                            out_f.write(data)
                            rem -= len(data)
                    else:
                        raise RuntimeError(f"Unknown extent target_type={ext['target_type']} in {name}")


def main():
    if len(sys.argv) < 3:
        print("Usage:")
        print("  lp_tools.py dump <super_raw.img>")
        print("  lp_tools.py unpack <super_raw.img> <out_dir> [part1,part2,...]")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "dump":
        cmd_dump(sys.argv[2])
    elif cmd == "unpack":
        out_dir = sys.argv[3]
        only = set(sys.argv[4].split(",")) if len(sys.argv) >= 5 and sys.argv[4] else None
        cmd_unpack(sys.argv[2], out_dir, only)
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
