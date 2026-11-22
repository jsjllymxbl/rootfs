#!/usr/bin/env python3
"""打 TWRP 刷机包：rootfs 成员用 STORED 且排第一位，便于按偏移提取。

用法: mkzip.py --work DIR --output ZIP --member rootfs.tar.gz [--print-offset]
"""
import argparse
import os
import shutil
import stat
import sys
import zipfile

MEMBER_SRC = None


def zip_attr(path):
    mode = stat.S_IMODE(os.lstat(path).st_mode)
    attr = mode << 16
    if stat.S_ISDIR(os.lstat(path).st_mode):
        attr |= 0x10
    return attr


def add_tree(z, root, skip):
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for d in sorted(dirs):
            full = os.path.join(base, d)
            rel = os.path.relpath(full, root)
            if rel in skip:
                continue
            zi = zipfile.ZipInfo(rel + "/", date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = zip_attr(full)
            z.writestr(zi, b"")
        for f in sorted(files):
            full = os.path.join(base, f)
            rel = os.path.relpath(full, root)
            if rel in skip:
                continue
            zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = zip_attr(full)
            with open(full, "rb") as src:
                z.writestr(zi, src.read())


def add_stored(z, src, name):
    zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_STORED
    zi.external_attr = 0o644 << 16
    with open(src, "rb") as f, z.open(zi, "w") as dst:
        shutil.copyfileobj(f, dst, 1024 * 1024)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--member", default="rootfs.tar.gz")
    ap.add_argument("--source", required=True, help="member 的源文件路径")
    ap.add_argument("--print-offset", action="store_true")
    args = ap.parse_args()

    tmp = args.output + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        add_stored(z, args.source, args.member)     # 必须是第一个
        add_tree(z, args.work, skip={args.member})
    os.replace(tmp, args.output)

    if args.print_offset:
        with zipfile.ZipFile(args.output) as z:
            info = z.getinfo(args.member)
            if info.compress_type != zipfile.ZIP_STORED:
                sys.exit("成员没有被 stored，偏移不能用")
            off = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
            print(f"OFFSET={off}")
            print(f"SIZE={info.file_size}")


if __name__ == "__main__":
    main()
