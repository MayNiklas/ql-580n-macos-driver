"""Wire-level tests for the native Brother QL-580N CUPS raster filter."""

from __future__ import annotations

import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PPD = ROOT / "ppd/Brother-QL-580N-Native.ppd"
SAMPLE_PDF = ROOT / "build/test-label-62x50.pdf"
ROLL_62_PT = 62 * 72 / 25.4
DIE_29_PT = 29 * 72 / 25.4
DIE_90_PT = 90 * 72 / 25.4


def unpack_packbits(packed: bytes) -> bytes:
    output = bytearray()
    at = 0
    while at < len(packed):
        control = packed[at]
        at += 1
        if control < 128:
            count = control + 1
            output.extend(packed[at : at + count])
            at += count
        elif control > 128:
            count = 257 - control
            output.extend(packed[at : at + 1] * count)
            at += 1
    if at != len(packed) or len(output) != 90:
        raise AssertionError(f"bad PackBits row: consumed {at}/{len(packed)}, made {len(output)} bytes")
    return bytes(output)


def read_job(wire: bytes) -> list[dict]:
    prefix = b"\x1bi a".replace(b" ", b"") + b"\x01" + b"\x00" * 200 + b"\x1b@\x1bia\x01"
    assert wire.startswith(prefix), "missing mode switch, invalidation, or initialization"
    at = len(prefix)
    pages = []
    while at < len(wire):
        if pages:
            assert wire[at : at + 1] == b"\x0c", "nonfinal page must end with form feed"
            at += 1
        assert wire[at : at + 3] == b"\x1biz", "missing print information"
        info = wire[at + 3 : at + 13]
        assert len(info) == 10
        flags, kind, width, length = info[:4]
        count = struct.unpack_from("<I", info, 4)[0]
        page_position = info[8]
        assert info[9] == 0
        at += 13
        assert wire[at : at + 3] == b"\x1biM"
        autocut = wire[at + 3]
        at += 4
        assert wire[at : at + 4] == b"\x1biA\x01"
        at += 4
        assert wire[at : at + 3] == b"\x1biK"
        expanded = wire[at + 3]
        at += 4
        assert wire[at : at + 3] == b"\x1bid"
        feed_margin = struct.unpack_from("<H", wire, at + 3)[0]
        at += 5
        assert wire[at : at + 2] == b"M\x02", "LAN transport must use TIFF PackBits"
        at += 2
        rows = []
        for _ in range(count):
            op = wire[at]
            if op == ord("Z"):
                rows.append(bytes(90))
                at += 1
            else:
                assert wire[at : at + 2] == b"g\x00"
                size = wire[at + 2]
                rows.append(unpack_packbits(wire[at + 3 : at + 3 + size]))
                at += 3 + size
        pages.append({
            "flags": flags, "kind": kind, "width": width, "length": length,
            "count": count, "position": page_position, "autocut": autocut,
            "expanded": expanded, "margin": feed_margin, "rows": rows,
        })
        if wire[at : at + 1] == b"\x1a":
            assert at + 1 == len(wire), "extra bytes after final page"
            break
    return pages


class FilterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        cls.filter = cls.directory / "rastertoql580n"
        cls.fixture = cls.directory / "raster_fixture"
        for source, target in (
            (ROOT / "src/rastertoql580n.c", cls.filter),
            (ROOT / "tests/raster_fixture.c", cls.fixture),
        ):
            extra = [str(ROOT / "src/ql_status.c")] if source.name == "rastertoql580n.c" else []
            subprocess.run(
                ["cc", "-std=c11", "-O2", "-Wno-deprecated-declarations", str(source), *extra,
                 "-o", str(target), "-lcups", "-lm"],
                check=True, capture_output=True, text=True,
            )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def make_raster(
        self, *, width: int = 732, height: int = 306,
        page_width: float = ROLL_62_PT, page_height: float = 306 * 72 / 300,
        name: str = "r62x26", pages: int = 1, mark_x: int = 18,
        mark_y: int = 35, mode: str = "gray8", num_copies: int = 1,
        ydpi: int = 300,
    ) -> Path:
        path = self.directory / "fixture.ras"
        subprocess.run(
            [str(self.fixture), str(path), str(width), str(height), str(page_width),
             str(page_height), name, str(pages), str(mark_x), str(mark_y), mode,
             str(num_copies), str(ydpi)],
            check=True, capture_output=True,
        )
        return path

    def run_filter(self, path: Path, *, copies: int = 1, options: str = "") -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env.pop("PPD", None)
        return subprocess.run(
            [str(self.filter), "1", "test", "fixture", str(copies), options, str(path)],
            capture_output=True, env=env,
        )

    def test_62mm_roll_crop_mirror_and_packbits(self) -> None:
        result = self.run_filter(self.make_raster())
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        pages = read_job(result.stdout)
        self.assertEqual(len(pages), 1)
        page = pages[0]
        self.assertEqual((page["kind"], page["width"], page["length"]), (10, 62, 0))
        self.assertEqual((page["count"], page["margin"], page["position"]), (236, 35, 0))
        self.assertEqual((page["autocut"], page["expanded"]), (0x40, 0x08))
        self.assertEqual(sum(bool(any(row)) for row in page["rows"]), 1)
        expected = bytearray(90)
        expected[707 // 8] = 0x80 >> (707 % 8)
        self.assertEqual(page["rows"][0], bytes(expected))

    def test_600dpi_roll_retains_extra_feed_direction_detail(self) -> None:
        result = self.run_filter(self.make_raster(
            height=612, page_height=612 * 72 / 600, mark_y=70, ydpi=600,
        ))
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["flags"], page["count"], page["expanded"], page["margin"]),
                         (0xc6, 472, 0x48, 35))
        self.assertEqual(sum(bool(any(row)) for row in page["rows"]), 1)
        expected = bytearray(90)
        expected[707 // 8] = 0x80 >> (707 % 8)
        self.assertEqual(page["rows"][0], bytes(expected))
        self.assertEqual(page["rows"][1], bytes(90))

    def test_multi_page_and_copies(self) -> None:
        result = self.run_filter(self.make_raster(pages=2, num_copies=2), copies=1)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        pages = read_job(result.stdout)
        self.assertEqual(len(pages), 4)
        self.assertEqual([page["position"] for page in pages], [0, 1, 1, 1])
        self.assertTrue(all(page["rows"] == pages[0]["rows"] for page in pages))

    def cupsfilter(self, pdf: Path, *, copies: int = 1, options: list[str] | None = None) -> Path:
        path = self.directory / "cupsfilter.ras"
        command = ["/usr/sbin/cupsfilter", "-P", str(PPD), "-m", "application/vnd.cups-raster",
                   "-n", str(copies)]
        for option in options or []:
            command.extend(["-o", option])
        command.append(str(pdf))
        with path.open("wb") as output:
            subprocess.run(command, stdout=output, stderr=subprocess.PIPE, check=True)
        return path

    def test_macos_cupsfilter_two_copies_are_not_doubled(self) -> None:
        if not SAMPLE_PDF.is_file():
            self.skipTest("sample PDF is unavailable")
        path = self.cupsfilter(SAMPLE_PDF, copies=2, options=["PageSize=w62l50"])
        headers = subprocess.run([str(self.fixture), "--inspect", str(path)],
                                 capture_output=True, text=True, check=True).stdout.splitlines()
        self.assertEqual([int(header.split()[0]) for header in headers], [1, 1])
        result = self.run_filter(path, copies=2)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        pages = read_job(result.stdout)
        self.assertEqual(len(pages), 2)
        self.assertEqual([page["width"] for page in pages], [62, 62])

    def test_macos_cupsfilter_renders_true_300x600_raster(self) -> None:
        if not SAMPLE_PDF.is_file():
            self.skipTest("sample PDF is unavailable")
        path = self.cupsfilter(SAMPLE_PDF, options=["PageSize=w62l50", "Resolution=300x600dpi"])
        headers = subprocess.run([str(self.fixture), "--inspect", str(path)],
                                 capture_output=True, text=True, check=True).stdout.splitlines()
        self.assertEqual(len(headers), 1)
        fields = headers[0].split()
        self.assertEqual(fields[-2:], ["300", "600"])
        self.assertGreater(int(fields[2]), 1000)
        result = self.run_filter(path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["count"], page["expanded"]), (1041, 0x48))

    def test_macos_cupsfilter_custom_62x75mm(self) -> None:
        if not SAMPLE_PDF.is_file():
            self.skipTest("sample PDF is unavailable")
        path = self.cupsfilter(
            SAMPLE_PDF, options=["PageSize=Custom.175.748x212.598", "fit-to-page"],
        )
        headers = subprocess.run([str(self.fixture), "--inspect", str(path)],
                                 capture_output=True, text=True, check=True).stdout.splitlines()
        self.assertEqual(headers[0].split()[-2:], ["300", "600"])
        result = self.run_filter(path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        pages = read_job(result.stdout)
        self.assertEqual(len(pages), 1)
        self.assertEqual((pages[0]["width"], pages[0]["kind"]), (62, 10))
        self.assertGreaterEqual(pages[0]["count"], 1620)
        self.assertLessEqual(pages[0]["count"], 1640)
        self.assertEqual(pages[0]["expanded"], 0x48)

    def test_macos_cupsfilter_custom_62mm_lengths(self) -> None:
        if not SAMPLE_PDF.is_file():
            self.skipTest("sample PDF is unavailable")
        for length, minimum, maximum in ((42, 840, 860), (181, 4120, 4150)):
            with self.subTest(length=length):
                path = self.cupsfilter(
                    SAMPLE_PDF, options=[f"PageSize=Custom.62x{length}mm", "fit-to-page"])
                result = self.run_filter(path)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                page = read_job(result.stdout)[0]
                self.assertEqual((page["width"], page["kind"], page["expanded"]), (62, 10, 0x48))
                self.assertGreaterEqual(page["count"], minimum)
                self.assertLessEqual(page["count"], maximum)

    def test_packbits_round_trip_for_mixed_full_width_row(self) -> None:
        result = self.run_filter(self.make_raster(mark_x=-2))
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        expected = bytearray(90)
        for x in range(696):
            if ((x + 18) % 17) < 8:
                bit = 12 + 695 - x
                expected[bit // 8] |= 0x80 >> (bit % 8)
        self.assertEqual(page["rows"][0], bytes(expected))

    def test_autocut_off(self) -> None:
        result = self.run_filter(self.make_raster(), options="AutoCut=Off")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["autocut"], page["expanded"]), (0, 0))

    def test_trimming_requires_explicit_opt_in(self) -> None:
        path = self.make_raster(mark_y=150)
        default = self.run_filter(path)
        disabled = self.run_filter(path, options="QLTrim=Off")
        self.assertEqual(default.returncode, 0)
        self.assertEqual(default.stdout, disabled.stdout)
        self.assertEqual(read_job(default.stdout)[0]["count"], 236)
        self.assertIn('*DefaultQLTrim: Off', PPD.read_text())

    def test_trimming_preserves_ink_and_minimum_length_at_both_resolutions(self) -> None:
        for ydpi in (300, 600):
            with self.subTest(ydpi=ydpi):
                factor = ydpi // 300
                path = self.make_raster(height=306*factor, mark_y=150*factor,
                                        page_height=306*72/300, ydpi=ydpi, num_copies=2)
                original = read_job(self.run_filter(path).stdout)[0]
                result = self.run_filter(path, options="QLTrim=On")
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                pages = read_job(result.stdout)
                self.assertEqual(len(pages), 2)
                self.assertEqual(pages[0]["rows"], pages[1]["rows"])
                self.assertEqual(pages[0]["count"], 155*factor)
                self.assertEqual(pages[0]["margin"], 35)
                self.assertEqual([row for row in original["rows"] if any(row)],
                                 [row for row in pages[0]["rows"] if any(row)])

    def test_trimming_preserves_blank_labels(self) -> None:
        path = self.make_raster(mark_x=-1)
        original = self.run_filter(path)
        trimmed = self.run_filter(path, options="QLTrim=On")
        self.assertEqual(trimmed.returncode, 0)
        self.assertEqual(original.stdout, trimmed.stdout)

    def test_trimming_preserves_internal_whitespace_and_edge_marks(self) -> None:
        path = self.make_raster(mark_y=-2)
        original = self.run_filter(path)
        trimmed = self.run_filter(path, options="QLTrim=On")
        self.assertEqual(trimmed.returncode, 0)
        self.assertEqual(original.stdout, trimmed.stdout)
        self.assertEqual(sum(any(row) for row in read_job(trimmed.stdout)[0]["rows"]), 2)

    def test_trimming_never_changes_diecut_labels(self) -> None:
        path = self.make_raster(width=342, height=1061, page_width=DIE_29_PT,
                                page_height=DIE_90_PT, name="d29x90", mark_y=400)
        original = self.run_filter(path)
        trimmed = self.run_filter(path, options="QLTrim=On")
        self.assertEqual(trimmed.returncode, 0)
        self.assertEqual(original.stdout, trimmed.stdout)

    def test_29x90_diecut_uses_printable_rows(self) -> None:
        path = self.make_raster(
            width=342, height=1061, page_width=DIE_29_PT, page_height=DIE_90_PT,
            name="d29x90", mark_x=18, mark_y=35,
        )
        result = self.run_filter(path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["flags"], page["kind"], page["width"], page["length"]),
                         (0x8e, 0x0b, 29, 90))
        self.assertEqual((page["count"], page["margin"]), (991, 0))
        expected = bytearray(90)
        bit = 6 + 306 - 1
        expected[bit // 8] = 0x80 >> (bit % 8)
        self.assertEqual(page["rows"][0], bytes(expected))

    def test_600dpi_diecut_doubles_printable_rows(self) -> None:
        path = self.make_raster(
            width=342, height=2122, page_width=DIE_29_PT, page_height=DIE_90_PT,
            name="d29x90", mark_x=18, mark_y=70, ydpi=600,
        )
        result = self.run_filter(path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["flags"], page["count"], page["margin"]), (0xce, 1982, 0))
        self.assertEqual(sum(bool(any(row)) for row in page["rows"]), 1)

    def test_truncated_raster_rejected_before_output(self) -> None:
        path = self.make_raster()
        path.write_bytes(path.read_bytes()[:-10])
        result = self.run_filter(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_unsupported_color_format_rejected_before_output(self) -> None:
        result = self.run_filter(self.make_raster(mode="cmyk32"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
