#!/usr/bin/env python3
"""Convert the original SVG printer artwork to a multi-size macOS ICNS file."""

from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "ql580n-native.svg"
OUTPUT = ROOT / "assets" / "ql580n-native.icns"
SIZES = ((16, b"icp4"), (32, b"icp5"), (64, b"icp6"),
         (128, b"ic07"), (256, b"ic08"), (512, b"ic09"),
         (1024, b"ic10"))


def build() -> bytes:
    if shutil.which("rsvg-convert") is None:
        raise SystemExit("rsvg-convert is required only when regenerating the icon")
    chunks = []
    with tempfile.TemporaryDirectory() as temporary:
        for size, kind in SIZES:
            png = Path(temporary) / f"icon-{size}.png"
            subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size),
                            str(SOURCE), "-o", str(png)], check=True)
            data = png.read_bytes()
            chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    payload = b"".join(chunks)
    return b"icns" + struct.pack(">I", len(payload) + 8) + payload


if __name__ == "__main__":
    OUTPUT.write_bytes(build())
    print(OUTPUT)
