import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def _load_module():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location(
        "verify_deployment",
        root / "scripts" / "verify_deployment.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


verify_deployment = _load_module()


class VerifyDeploymentHelperTests(unittest.TestCase):
    def test_prefer_nonzero_addr_falls_back_to_launch_expected_pool(self):
        launch_expected_pool = "0x1111111111111111111111111111111111111111"
        chosen = verify_deployment._prefer_nonzero_addr(
            verify_deployment.ZERO_ADDR,
            launch_expected_pool,
            verify_deployment.ZERO_ADDR,
        )
        self.assertEqual(chosen, launch_expected_pool)

    def test_furnace_hop_defers_zero_pool_pre_genesis_when_pool_is_not_live(self):
        check, is_warning = verify_deployment._furnace_weth_claim_pool_status(
            "FurnaceEntryTokenRegistry",
            verify_deployment.ZERO_ADDR,
            verify_deployment.ZERO_ADDR,
            False,
            False,
        )
        self.assertTrue(is_warning)
        self.assertTrue(check.ok)
        self.assertIn("deferred pre-genesis", check.detail)

    def test_furnace_hop_compares_against_resolved_expected_pool(self):
        resolved_expected_pool = "0x2222222222222222222222222222222222222222"
        check, is_warning = verify_deployment._furnace_weth_claim_pool_status(
            "FurnaceEntryTokenRegistry",
            resolved_expected_pool,
            resolved_expected_pool,
            False,
            False,
        )
        self.assertFalse(is_warning)
        self.assertTrue(check.ok)
        self.assertIn(resolved_expected_pool, check.detail)

    def test_run_rejects_oversized_stdout(self):
        rc, out, err = verify_deployment._run(
            [sys.executable, "-c", "print('x' * 32)"],
            max_stdout_chars=8,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("stdout too large", err)

    def test_run_reports_timeout(self):
        rc, out, err = verify_deployment._run(
            [sys.executable, "-c", "import time; time.sleep(0.2)"],
            timeout_sec=0,
        )
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        self.assertIn("command timed out", err)

    def test_load_manifest_rejects_directory_input(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(SystemExit) as ctx:
                verify_deployment._load_manifest(Path(tmpdir))
        self.assertIn("not a regular file", str(ctx.exception))

    def test_load_manifest_rejects_oversized_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "manifest.json"
            path.write_text(json.dumps({"contracts": {"ClaimToken": "x" * 128}}), encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                verify_deployment._load_manifest(path, max_bytes=16)
        self.assertIn("manifest too large", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
