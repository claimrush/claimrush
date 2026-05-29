import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


def _load_module():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location(
        "export_abis",
        root / "scripts" / "export_abis.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


export_abis = _load_module()


class ExportAbisHelperTests(unittest.TestCase):
    def test_find_foundry_artifact_prefers_exact_contract_sol_path(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            exact = out_dir / "ClaimToken.sol" / "ClaimToken.json"
            other = out_dir / "ZZZ.sol" / "ClaimToken.json"
            exact.parent.mkdir(parents=True)
            other.parent.mkdir(parents=True)
            exact.write_text("{}", encoding="utf-8")
            other.write_text("{}", encoding="utf-8")

            chosen = export_abis.find_foundry_artifact(out_dir, "ClaimToken")
            self.assertEqual(chosen, exact)

    def test_find_foundry_artifact_falls_back_deterministically(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            out_dir = Path(tmpdir)
            first = out_dir / "AAA" / "Contract.json"
            second = out_dir / "BBB" / "Contract.json"
            first.parent.mkdir(parents=True)
            second.parent.mkdir(parents=True)
            first.write_text("{}", encoding="utf-8")
            second.write_text("{}", encoding="utf-8")

            chosen = export_abis.find_foundry_artifact(out_dir, "Contract")
            self.assertEqual(chosen, first)


if __name__ == "__main__":
    unittest.main()
