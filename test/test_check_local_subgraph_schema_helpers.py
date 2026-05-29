import importlib.util
import sys
import unittest
from pathlib import Path


def _load_module():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location(
        "check_local_subgraph_schema",
        root / "scripts" / "check_local_subgraph_schema.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


check_local_subgraph_schema = _load_module()


class CheckLocalSubgraphSchemaHelperTests(unittest.TestCase):
    def test_decode_json_response_bytes_accepts_object_payload(self):
        body, error = check_local_subgraph_schema._decode_json_response_bytes(
            b'{"data":{"__schema":{"queryType":{"fields":[{"name":"foo"}]}}}}'
        )
        self.assertIsNone(error)
        self.assertIsInstance(body, dict)
        self.assertIn("data", body)

    def test_decode_json_response_bytes_rejects_oversized_payload(self):
        raw = b"{" + (b'"a":1,' * 250_000) + b'"z":1}'
        body, error = check_local_subgraph_schema._decode_json_response_bytes(raw)
        self.assertIsNone(body)
        self.assertEqual(
            error,
            f"response_too_large>{check_local_subgraph_schema.MAX_SUBGRAPH_RESPONSE_BYTES}",
        )

    def test_decode_json_response_bytes_rejects_non_object_json(self):
        body, error = check_local_subgraph_schema._decode_json_response_bytes(b'["not","an","object"]')
        self.assertIsNone(body)
        self.assertEqual(error, "response_not_object")


if __name__ == "__main__":
    unittest.main()
