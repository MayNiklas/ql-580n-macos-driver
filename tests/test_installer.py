import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install.sh"
UNINSTALLER = ROOT / "scripts" / "uninstall.sh"


def run_script(script, *args):
    return subprocess.run(
        ["/bin/bash", str(script), *args],
        text=True,
        capture_output=True,
        check=False,
    )


class InstallerArgumentsTest(unittest.TestCase):
    def test_address_makes_unique_queue_and_socket_target(self):
        result = run_script(INSTALLER, "--host", "192.0.2.25", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("queue=Brother_QL_580N_192_0_2_25\n", result.stdout)
        self.assertIn("name=QL-580N macOS Driver\n", result.stdout)
        self.assertIn("device=socket://192.0.2.25:9100/?waiteof=false\n", result.stdout)

    def test_dns_address_and_explicit_legacy_queue(self):
        result = run_script(
            INSTALLER,
            "--host", "printer.local",
            "--queue", "Brother_QL_580N_Native",
            "--name", "Office Labels",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("name=Office Labels\n", result.stdout)
        self.assertIn("queue=Brother_QL_580N_Native\n", result.stdout)

    def test_invalid_addresses_are_rejected(self):
        for host in (
            "socket://192.0.2.25", "192.0.2.25:9100", "-printer",
            "printer..local", "printer.local/path", "a b", "256.1.2.3",
            "1.2.3", "host;touch", "::1", "",
        ):
            with self.subTest(host=host):
                result = run_script(INSTALLER, "--host", host, "--dry-run")
                self.assertEqual(result.returncode, 2)

    def test_invalid_queues_are_rejected(self):
        for queue in ("-bad", "a/b", "a b", "a;id", "x" * 128):
            with self.subTest(queue=queue):
                result = run_script(
                    INSTALLER, "--host", "printer.local",
                    "--queue", queue, "--dry-run",
                )
                self.assertEqual(result.returncode, 2)
                result = run_script(UNINSTALLER, "--queue", queue)
                self.assertEqual(result.returncode, 2)

    def test_host_required(self):
        result = run_script(INSTALLER, "--dry-run")
        self.assertEqual(result.returncode, 2)

    def test_uninstall_requires_queue(self):
        result = run_script(UNINSTALLER)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
