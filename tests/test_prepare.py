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
    PAIRS = [
        ("11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8",
         "1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5", 552),
        ("49C7F43DA0C2A9DBCADFB0C993058147018BF7C1D0FDE4360DE11ACE2C98F45D",
         "25A8CD31B5BC44C387CBF53EC3FE4CD314B5FCAC0D8D84201F444F1B2DB10FAB", 551),
    ]

    def test_both_exact_profiles_remain_available(self):
        for original, candidate, changed in self.PAIRS:
            with self.subTest(original=original):
                profile = prepare.profile_for_hash(original)
                self.assertEqual(profile["candidate_sha256"], candidate)
                self.assertEqual(profile["changed_bytes"], changed)

    def test_patched_hashes_are_not_accepted_as_originals(self):
        for _, candidate, _ in self.PAIRS:
            with self.subTest(candidate=candidate):
                with self.assertRaisesRegex(prepare.PreparationError, "unsupported build"):
                    prepare.profile_for_hash(candidate)

    def test_cross_profile_output_rejected(self):
        # Synthetic buffers isolate the pair guard; no proprietary fixture is needed.
        data = bytes(prepare.FILE_SIZE)
        metadata = [dict(name=name, old_profile_match=False)
                    for name in ("pe-checksum", "mta-wrapper-and-unwind")]
        for index, (original, _, changed) in enumerate(self.PAIRS):
            other_candidate = self.PAIRS[1 - index][1]
            with self.subTest(original=original):
                with patch.object(prepare, "sha", side_effect=[original, other_candidate]), \
                        patch.object(prepare, "parse_regions", return_value=[]), \
                        patch.object(prepare, "PE"), \
                        patch.object(prepare, "apply_regions", return_value=(data, metadata, changed)):
                    with self.assertRaisesRegex(prepare.PreparationError, "Candidate SHA-256 mismatch"):
                        prepare.build_candidate(data, b"source")

    def test_each_profile_enforces_its_changed_byte_count(self):
        data = bytes(prepare.FILE_SIZE)
        metadata = [dict(name=name, old_profile_match=False)
                    for name in ("pe-checksum", "mta-wrapper-and-unwind")]
        for original, candidate, changed in self.PAIRS:
            with self.subTest(original=original):
                with patch.object(prepare, "sha", side_effect=[original, candidate]), \
                        patch.object(prepare, "parse_regions", return_value=[]), \
                        patch.object(prepare, "PE"), \
                        patch.object(prepare, "apply_regions", return_value=(data, metadata, changed + 1)):
                    with self.assertRaisesRegex(prepare.PreparationError, "changed-byte count"):
                        prepare.build_candidate(data, b"source")

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
