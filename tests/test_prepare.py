"""Guard tests use synthetic bytes only; no proprietary binary fixtures."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prepare.py"
SPEC = importlib.util.spec_from_file_location("prepare", SCRIPT)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class PreparationGuards(unittest.TestCase):
    def test_unknown_original_rejected_before_parsing(self):
        with patch.object(prepare, "parse_regions") as parse:
            with self.assertRaisesRegex(prepare.PreparationError, "unsupported build"):
                prepare.build_candidate(b"unknown executable", b"untrusted script")
            parse.assert_not_called()

    def test_modified_upstream_source_rejected(self):
        with self.assertRaisesRegex(prepare.PreparationError, "source SHA-256 mismatch"):
            prepare.parse_regions(b"Write-Output 'this must never execute'")

    def test_region_mismatch_preserves_original(self):
        original = b"abcdef"
        with self.assertRaisesRegex(prepare.PreparationError, "guard mismatch"):
            prepare.apply_regions(original, [dict(name="code", offset=1,
                                                  original=b"xx", patched=b"12")])
        self.assertEqual(original, b"abcdef")

    def test_overlapping_regions_rejected(self):
        regions = [dict(name="one", offset=1, original=b"bc", patched=b"12"),
                   dict(name="two", offset=2, original=b"cd", patched=b"34")]
        with self.assertRaisesRegex(prepare.PreparationError, "Overlapping"):
            prepare.apply_regions(b"abcdef", regions)

    def test_out_of_bounds_and_length_changes_rejected(self):
        for offset, original, candidate in [(-1, b"a", b"b"), (6, b"a", b"b"),
                                            (0, b"a", b"bc"), (0, b"", b"")]:
            with self.subTest(offset=offset, original=original, candidate=candidate):
                with self.assertRaisesRegex(prepare.PreparationError, "range"):
                    prepare.apply_regions(b"abcdef", [dict(name="code", offset=offset,
                                          original=original, patched=candidate)])

    def test_memory_only_patch_leaves_input_unchanged(self):
        original = b"abcdef"
        result, _, changed = prepare.apply_regions(original, [dict(name="code", offset=1,
                                                   original=b"bc", patched=b"12")])
        self.assertEqual(result, b"a12def")
        self.assertEqual(original, b"abcdef")
        self.assertEqual(changed, 2)

    def test_refuses_output_inside_helper_installation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            helper = root / "install" / "helper.exe"
            helper.parent.mkdir()
            helper.write_bytes(b"original")
            source = root / "patch.ps1"
            source.write_text("untrusted", encoding="utf-8")
            with self.assertRaisesRegex(prepare.PreparationError, "installation directory"):
                prepare.validate_paths(helper, source, helper.parent / "staging")

    def test_unknown_input_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            helper = root / "install" / "helper.exe"
            helper.parent.mkdir()
            helper.write_bytes(b"original")
            source = root / "source.ps1"
            source.write_text("untrusted", encoding="utf-8")
            output = root / "staged"
            with self.assertRaises(prepare.PreparationError):
                prepare.prepare(helper, source, output)
            self.assertFalse(output.exists())
            self.assertEqual(helper.read_bytes(), b"original")

    def test_existing_output_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            helper = root / "install" / "helper.exe"
            helper.parent.mkdir()
            helper.write_bytes(b"original")
            source = root / "source.ps1"
            source.write_text("untrusted", encoding="utf-8")
            output = root / "staged"
            output.mkdir()
            preserved = output / "original.bin"
            preserved.write_bytes(b"do not replace")
            with self.assertRaisesRegex(prepare.PreparationError, "empty or nonexistent"):
                prepare.prepare(helper, source, output)
            self.assertEqual(preserved.read_bytes(), b"do not replace")


if __name__ == "__main__":
    unittest.main()
