#!/usr/bin/env python3
"""Generate a small vector PDF test label with no third-party dependencies."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--resolution", type=int, choices=(300, 600), default=300)
args = parser.parse_args()

width, height = 62 * 72 / 25.4, 50 * 72 / 25.4
content = f"""0 G 0.7 w 7 10 {width - 14:.3f} {height - 20:.3f} re S
BT /F1 12 Tf 13 113 Td (Brother QL-580N) Tj
/F1 9 Tf 0 -19 Td (Native Apple Silicon driver) Tj
0 -16 Td (62 x 50 mm - 300 x {args.resolution} dpi) Tj
0 -16 Td (LEFT   123456789   RIGHT) Tj
0 -16 Td (macOS print test) Tj ET
0 g 13 20 8 8 re f 145 20 12 8 re S
""".encode("ascii")
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.5f} {height:.5f}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".encode(),
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
]
pdf = bytearray(b"%PDF-1.4\n")
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
name = "test-label-62x50.pdf" if args.resolution == 300 else "test-label-62x50-600dpi.pdf"
target = Path(__file__).resolve().parent.parent / "build" / name
target.parent.mkdir(exist_ok=True)
target.write_bytes(pdf)
print(target)
