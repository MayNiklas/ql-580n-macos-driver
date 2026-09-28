"""Mocked CUPS side-channel tests for loaded media and print completion."""

from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

from tests.test_filter import read_job


ROOT = Path(__file__).resolve().parents[1]


class StatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        cls.filter = cls.directory / "rastertoql580n"
        cls.fixture = cls.directory / "raster_fixture"
        cls.backend = cls.directory / "status_fixture"
        for sources, target in (
            ([ROOT / "src/rastertoql580n.c", ROOT / "src/ql_status.c"], cls.filter),
            ([ROOT / "tests/raster_fixture.c"], cls.fixture),
            ([ROOT / "tests/status_fixture.c"], cls.backend),
        ):
            subprocess.run(
                ["cc", "-std=c11", "-O2", "-Wno-deprecated-declarations",
                 *(str(source) for source in sources), "-o", str(target), "-lcups", "-lm"],
                check=True, capture_output=True, text=True,
            )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def make_raster(self, *, width: int = 732, height: int = 306,
                    page_width_mm: int = 62, page_height_mm: int = 26,
                    name: str = "w62l26", mark_x: int = 18, mark_y: int = 35) -> Path:
        path = self.directory / "fixture.ras"
        subprocess.run(
            [str(self.fixture), str(path), str(width), str(height),
             str(page_width_mm * 72 / 25.4), str(page_height_mm * 72 / 25.4),
             name, "1", str(mark_x), str(mark_y), "gray8", "1", "300"],
            check=True, capture_output=True,
        )
        return path

    def run_job(self, mode: str, *, media: str = "Manual", status: str = "On",
                path: Path | None = None, wait: int = 1) -> subprocess.CompletedProcess[bytes]:
        if path is None:
            path = self.make_raster()
        filter_socket, backend_socket = socket.socketpair()

        def assign_fd4(sock: socket.socket):
            def fn() -> None:
                os.dup2(sock.fileno(), 4)
            return fn

        env = os.environ.copy()
        env.pop("PPD", None)
        backend = subprocess.Popen(
            [str(self.backend), mode], pass_fds=(backend_socket.fileno(), 4),
            preexec_fn=assign_fd4(backend_socket), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        filter_process = subprocess.Popen(
            [str(self.filter), "1", "test", "fixture", "1",
             f"QLMedia={media} QLStatus={status} QLWaitTimeout={wait}", str(path)],
            pass_fds=(filter_socket.fileno(), 4), preexec_fn=assign_fd4(filter_socket),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
        )
        filter_socket.close()
        backend_socket.close()
        try:
            stdout, stderr = filter_process.communicate(timeout=15)
            backend.communicate(timeout=8)
        finally:
            if filter_process.poll() is None:
                filter_process.kill()
                filter_process.communicate()
            if backend.poll() is None:
                backend.kill()
                backend.communicate()
        self.assertEqual(backend.returncode, 0)
        return subprocess.CompletedProcess(filter_process.args, filter_process.returncode,
                                           stdout, stderr)

    def test_auto_roll_uses_loaded_width(self) -> None:
        path = self.make_raster(width=342, page_width_mm=29, name="w29l26")
        result = self.run_job("ready", media="Auto", path=path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["kind"], page["width"], page["length"]), (10, 62, 0))

    def test_auto_diecut_uses_loaded_stock(self) -> None:
        result = self.run_job("diecut", media="Auto")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["kind"], page["width"], page["length"], page["count"]),
                         (11, 62, 100, 1109))

    def test_auto_narrow_roll_scales_and_centers_artwork(self) -> None:
        path = self.make_raster(mark_x=-2, mark_y=34)
        result = self.run_job("narrow", media="Auto", path=path)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        page = read_job(result.stdout)[0]
        self.assertEqual((page["width"], page["count"]), (29, 237))
        scale = 306 / 696
        top = (237 - round(237 * scale)) // 2
        expected = bytearray(90)
        for x in range(306):
            source_x = 18 + int(x / scale)
            if source_x % 17 < 8:
                bit = 6 + 305 - x
                expected[bit // 8] |= 0x80 >> (bit % 8)
        self.assertEqual(page["rows"][top], bytes(expected))
        self.assertEqual(sum(bool(any(row)) for row in page["rows"]), 1)

    def test_empty_roll_is_reported_before_output(self) -> None:
        result = self.run_job("empty")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +media-empty-error", result.stderr)

    def test_cutter_jam_is_reported_before_output(self) -> None:
        result = self.run_job("jam")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +com.brother.ql580n-cutter-jam-error", result.stderr)

    def test_cover_open_is_reported_before_output(self) -> None:
        result = self.run_job("cover")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +cover-open-error", result.stderr)

    def test_unavailable_status_fails_closed(self) -> None:
        result = self.run_job("unavailable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +com.brother.ql580n-status-unavailable-error", result.stderr)

    def test_malformed_status_fails_closed(self) -> None:
        result = self.run_job("bad-packet")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +com.brother.ql580n-status-unavailable-error", result.stderr)

    def test_manual_size_mismatch_is_reported_before_output(self) -> None:
        path = self.make_raster(width=342, page_width_mm=29, name="w29l26")
        result = self.run_job("ready", path=path)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +media-needed-error", result.stderr)

    def test_roll_change_during_preparation_is_reported_before_output(self) -> None:
        result = self.run_job("roll-change", media="Auto")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"STATE: +media-needed-error", result.stderr)

    def test_malformed_or_overflowed_page_count_is_rejected(self) -> None:
        for mode in ("bad-count", "overflow-count"):
            with self.subTest(mode=mode):
                result = self.run_job(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"STATE: +com.brother.ql580n-status-unavailable-error", result.stderr)

    def test_success_waits_for_page_counter(self) -> None:
        result = self.run_job("ready")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(len(read_job(result.stdout)), 1)
        self.assertIn(b"Printer confirmed 1 label(s)", result.stderr)

    def test_four_digit_counter_is_accepted(self) -> None:
        result = self.run_job("four-digits")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(len(read_job(result.stdout)), 1)
        self.assertIn(b"Printer confirmed 1 label(s)", result.stderr)

    def test_error_after_transfer_is_reported(self) -> None:
        result = self.run_job("post-jam")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout)
        self.assertIn(b"STATE: +com.brother.ql580n-cutter-jam-error", result.stderr)

    def test_no_completion_is_not_success(self) -> None:
        result = self.run_job("stalled", wait=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout)
        self.assertIn(b"STATE: +com.brother.ql580n-completion-unknown-error", result.stderr)

    def test_excess_count_is_not_attributed_to_this_job(self) -> None:
        result = self.run_job("excess")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout)
        self.assertIn(b"STATE: +com.brother.ql580n-completion-unknown-error", result.stderr)


if __name__ == "__main__":
    unittest.main()
