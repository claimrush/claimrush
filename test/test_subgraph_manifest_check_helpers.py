import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


def _load_module(name: str, rel_path: str):
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location(name, root / rel_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


runtime_readiness = _load_module(
    "check_subgraph_manifest_runtime_readiness",
    "scripts/check_subgraph_manifest_runtime_readiness.py",
)
events_vs_abi = _load_module(
    "check_subgraph_manifest_events_vs_abi",
    "scripts/check_subgraph_manifest_events_vs_abi.py",
)


class SubgraphManifestCheckHelperTests(unittest.TestCase):
    def test_runtime_readiness_parse_yaml_rejects_directory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(SystemExit) as ctx:
                runtime_readiness.parse_yaml(Path(tmpdir))
        self.assertIn("not a regular file", str(ctx.exception))

    def test_runtime_readiness_parse_yaml_rejects_oversized_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "manifest.yaml"
            path.write_text("dataSources:\n" + ("  - kind: ethereum\n" * 64), encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                runtime_readiness.parse_yaml(path, max_bytes=16)
        self.assertIn("too large", str(ctx.exception))

    def test_events_vs_abi_rejects_non_array_abi(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "ClaimToken.json"
            path.write_text(json.dumps({"abi": []}), encoding="utf-8")
            with self.assertRaises(SystemExit) as ctx:
                events_vs_abi.load_abi_events(path)
        self.assertIn("expected ABI array", str(ctx.exception))

    def test_events_vs_abi_rejects_directory_input(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(SystemExit) as ctx:
                events_vs_abi.load_abi_events(Path(tmpdir))
        self.assertIn("not a regular file", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
