#!/usr/bin/env python3
"""Build the initial A/B slot metadata (AvbABData) for the misc partition.

u-boot's A/B boot (CONFIG_ANDROID_AB + CONFIG_SPL_AB) stores its slot state
in a 32-byte AvbABData struct at byte offset 2048 of the `misc` partition
(AB_METADATA_OFFSET).  The struct layout matches include/android_avb/avb_ab_flow.h
in the vendored u-boot; the default values match avb_ab_data_init():

    magic          "\0AB0"          version_major=1  version_minor=0
    slot a         priority=15  tries_remaining=7  successful_boot=0
    slot b         priority=14  tries_remaining=7  successful_boot=0
    last_boot      0
    crc32          big-endian CRC32 over the preceding 28 bytes

The output is padded (default 4096 bytes) so the metadata sits at offset 2048
regardless of how the image is written into the partition.

Usage:
    mkabmeta.py [-o misc.img] [--slot-a P,T,S] [--slot-b P,T,S] [--last-boot N]
    mkabmeta.py --check misc.img          # parse + verify an existing file
"""

import argparse
import struct
import sys
import zlib

MAGIC = b"\x00AB0"
MAGIC_LEN = 4
AB_METADATA_OFFSET = 2048
PAD = 4096

MAJOR = 1
MINOR = 0
MAX_PRIORITY = 15
MAX_TRIES = 7


def build(slot_a=(MAX_PRIORITY, MAX_TRIES, 0),
          slot_b=(MAX_PRIORITY - 1, MAX_TRIES, 0),
          last_boot=0):
    """Serialize an AvbABData (32 bytes), CRC32 big-endian over bytes 0..27."""
    slots = struct.pack(">4B4B",
                        slot_a[0], slot_a[1], slot_a[2], 0,
                        slot_b[0], slot_b[1], slot_b[2], 0)
    head = struct.pack(">4sBB2s", MAGIC, MAJOR, MINOR, b"\x00\x00")
    body = head + slots + struct.pack(">B", last_boot) + b"\x00" * 11
    assert len(body) == 28, len(body)
    crc = zlib.crc32(body) & 0xFFFFFFFF
    return body + struct.pack(">I", crc)


def parse(data):
    """Parse a 32-byte AvbABData; returns (slots, last_boot) or None on error."""
    if len(data) < 32:
        return None
    (magic, major, minor, _r1,
     pa, ta, sa, _ra, pb, tb, sb, _rb,
     last_boot, _r2, crc) = struct.unpack(">4sBB2s4B4BB11sI", data[:32])
    if magic != MAGIC or major > MAJOR:
        return None
    if crc != zlib.crc32(data[:28]) & 0xFFFFFFFF:
        return None
    slots = ((pa, ta, sa), (pb, tb, sb))
    return slots, last_boot


def parse_slot(s):
    p, t, succ = (int(x) for x in s.split(","))
    if not (0 <= p <= MAX_PRIORITY and 0 <= t <= MAX_TRIES and succ in (0, 1)):
        raise ValueError(f"invalid slot spec {s!r} (P,T,S)")
    return p, t, succ


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", default="misc.img", metavar="FILE")
    ap.add_argument("--slot-a", default="15,7,0", metavar="P,T,S",
                    help="priority,tries_remaining,successful_boot for slot a")
    ap.add_argument("--slot-b", default="14,7,0", metavar="P,T,S")
    ap.add_argument("--last-boot", type=int, default=0, choices=(0, 1))
    ap.add_argument("--pad", type=int, default=PAD,
                    help="pad output to this size (default 4096)")
    ap.add_argument("--check", metavar="FILE", help="parse+verify an existing file")
    args = ap.parse_args(argv)

    if args.check:
        data = open(args.check, "rb").read()
        got = parse(data[AB_METADATA_OFFSET:] if len(data) > AB_METADATA_OFFSET else data)
        if got is None:
            print(f"{args.check}: invalid AvbABData (magic/CRC mismatch)", file=sys.stderr)
            return 1
        slots, last_boot = got
        for i, (p, t, s) in enumerate(slots):
            print(f"slot_{'a' if i == 0 else 'b'}: priority={p} "
                  f"tries_remaining={t} successful_boot={s}")
        print(f"last_boot={last_boot}")
        return 0

    blob = build(parse_slot(args.slot_a), parse_slot(args.slot_b), args.last_boot)
    size = max(args.pad, AB_METADATA_OFFSET + len(blob))
    out = bytearray(b"\xff" * size)
    out[AB_METADATA_OFFSET:AB_METADATA_OFFSET + len(blob)] = blob
    with open(args.output, "wb") as f:
        f.write(out)
    print(f"wrote {args.output} ({size} bytes; AvbABData @ offset {AB_METADATA_OFFSET})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
