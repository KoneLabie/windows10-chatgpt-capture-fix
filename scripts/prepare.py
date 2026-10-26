#!/usr/bin/env python3
"""Stage an exact-build, unsigned Windows 10 capture experiment. Never install it.

The separately obtained upstream PowerShell file is hash-checked and parsed as
text; this program never executes it. No executable or upstream patch table is
distributed with this repository. Python 3.9+; standard library only.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

INPUT_SHA = "11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8"
OUTPUT_SHA = "1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5"
SOURCE_SHA = "8F961A6AB639F1E9FB2BE91F7F2F429F07CF9A68E80FCECD3654B525C60450D1"
SOURCE_COMMIT = "14b418f71b3cd56b3c1cca41db5933dfbc30fbd1"
SOURCE_URL = (
    "https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/blob/"
    + SOURCE_COMMIT + "/scripts/patch-computer-use-helper-win10.ps1"
)
FILE_SIZE = 1551152
PROFILE = "0.7.12-6FCC7C64"
UNSIGNED_WARNING = (
    "Experimental, unsupported modification. The candidate is unsigned; its "
    "embedded signature is removed. Do not weaken Windows security policy."
)


class PreparationError(RuntimeError):
    """A required guard failed; no installation has been attempted."""


def must(condition, message):
    if not condition:
        raise PreparationError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def parse_regions(source_data):
    """Accept only the reviewed source bytes, then parse literal records."""
    must(sha(source_data) == SOURCE_SHA, "Upstream source SHA-256 mismatch.")
    source = source_data.decode("utf-8-sig")
    marker = "Name = '@oai/sky 0.7.12 helper 6FCC7C64"
    must(source.count(marker) == 1, "Expected exactly one reviewed profile.")
    profile = source[source.index(marker):]
    profile = profile[:profile.index("function Write-Log")]
    pattern = (
        r"Name = '(?P<name>[^']+)'\s+Offset = (?P<offset>0x[0-9a-fA-F]+)"
        r"\s+OriginalHex = '(?P<original>[0-9a-fA-F]+)'"
        r"\s+PatchedHex = '(?P<patched>[0-9a-fA-F]+)'"
    )
    regions = [
        dict(name=m["name"], offset=int(m["offset"], 16),
             original=bytes.fromhex(m["original"]),
             patched=bytes.fromhex(m["patched"]))
        for m in re.finditer(pattern, profile)
    ]
    must(len(regions) == 13, "Expected thirteen reviewed regions.")
    must(len({r["name"] for r in regions}) == 13, "Duplicate region name.")
    return regions


class PE:
    """Read-only PE metadata inspection, after the complete input hash guard."""

    def __init__(self, data):
        self.data = data
        self.pe = self.u32(0x3C)
        must(data[self.pe:self.pe + 4] == b"PE\0\0", "Not a PE file.")
        must(self.u16(self.pe + 4) == 0x8664, "Not an x64 file.")
        self.count = self.u16(self.pe + 6)
        self.opt = self.pe + 24
        must(self.u16(self.opt) == 0x20B, "Not a PE32+ file.")
        self.base = self.u64(self.opt + 24)
        self.image_size = self.u32(self.opt + 56)
        table = self.opt + self.u16(self.pe + 20)
        self.sections = []
        for i in range(self.count):
            offset = table + i * 40
            name = data[offset:offset + 8].rstrip(b"\0").decode("ascii")
            size, rva, raw_size, raw = struct.unpack_from("<IIII", data, offset + 8)
            self.sections.append(dict(name=name, virtual_size=size, rva=rva,
                                      raw_size=raw_size, raw=raw,
                                      flags=self.u32(offset + 36)))

    def u16(self, offset):
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def u64(self, offset):
        return struct.unpack_from("<Q", self.data, offset)[0]

    def directory(self, index):
        return struct.unpack_from("<II", self.data, self.opt + 112 + index * 8)

    def offset(self, rva):
        for section in self.sections:
            if section["rva"] <= rva < section["rva"] + section["raw_size"]:
                return section["raw"] + rva - section["rva"]
        raise PreparationError(f"Unmapped RVA {rva:x}.")

    def rva(self, offset):
        for section in self.sections:
            if section["raw"] <= offset < section["raw"] + section["raw_size"]:
                return section["rva"] + offset - section["raw"]
        raise PreparationError(f"Unmapped offset {offset:x}.")

    def string(self, offset):
        return self.data[offset:self.data.index(b"\0", offset)].decode("ascii")

    def imports(self):
        offset = self.offset(self.directory(1)[0])
        result = {}
        while any(self.data[offset:offset + 20]):
            lookup, _, _, _, iat = struct.unpack_from("<IIIII", self.data, offset)
            index = 0
            while (value := self.u64(self.offset(lookup) + index * 8)):
                if not value >> 63:
                    result[iat + index * 8] = self.string(self.offset(value) + 2)
                index += 1
            offset += 20
        return result

    def relocations(self):
        rva, size = self.directory(5)
        offset = self.offset(rva)
        end = offset + size
        result = {}
        while offset < end:
            page, length = struct.unpack_from("<II", self.data, offset)
            must(length >= 8 and length % 2 == 0 and offset + length <= end,
                 "Invalid relocation block.")
            for pos in range(offset + 8, offset + length, 2):
                entry = self.u16(pos)
                if entry >> 12:
                    result[page + (entry & 0xFFF)] = entry >> 12
            offset += length
        return result


def apply_regions(original, regions):
    """Apply nonoverlapping guarded regions to memory, never to the input file."""
    candidate = bytearray(original)
    covered = set()
    metadata = []
    for region in regions:
        offset = region["offset"]
        old, new = region["original"], region["patched"]
        must(offset >= 0 and len(old) > 0 and len(old) == len(new)
             and offset + len(new) <= len(original), "Invalid region range.")
        span = set(range(offset, offset + len(new)))
        must(not covered.intersection(span), "Overlapping regions.")
        actual = original[offset:offset + len(old)]
        matches = actual == old
        must(matches or region["name"] in {"pe-checksum", "mta-wrapper-and-unwind"},
             "Code/PE guard mismatch: " + region["name"])
        candidate[offset:offset + len(new)] = new
        covered.update(span)
        # No upstream patch byte table is reproduced in the generated metadata.
        metadata.append(dict(name=region["name"], offset=offset, length=len(new),
                             old_profile_match=matches))
    differences = [i for i, (a, b) in enumerate(zip(original, candidate)) if a != b]
    must(set(differences) <= covered, "Unplanned changed bytes.")
    return bytes(candidate), metadata, len(differences)


def build_candidate(original, source_data):
    must(sha(original) == INPUT_SHA, "Original helper SHA-256 mismatch; unsupported build.")
    must(len(original) == FILE_SIZE, "Original helper size mismatch.")
    regions = parse_regions(source_data)
    before = PE(original)
    candidate, metadata, changed = apply_regions(original, regions)
    must([r["name"] for r in metadata if not r["old_profile_match"]]
         == ["pe-checksum", "mta-wrapper-and-unwind"], "Unexpected profile differences.")
    must(len(candidate) == len(original), "File length changed.")
    must(sha(candidate) == OUTPUT_SHA, "Candidate SHA-256 mismatch; refusing output.")
    must(changed == 552, "Unexpected changed-byte count.")
    after = PE(candidate)
    must(after.count == before.count + 1, "Unexpected section count.")
    section = after.sections[-1]
    must(section == dict(name=".cuw10", virtual_size=0xD0, rva=0x17E000,
                         raw_size=0x200, raw=0x176E00, flags=0x60000020),
         "Unexpected new section.")
    must(after.directory(4) == (0, 0), "Certificate directory not cleared.")
    must(after.image_size == 0x17F000, "Unexpected image extent.")
    for previous, current in zip(after.sections, after.sections[1:]):
        must(previous["rva"] + previous["virtual_size"] <= current["rva"],
             "Overlapping virtual sections.")
    vtable_rva = before.rva(0x12C8C8)
    must(before.relocations().get(vtable_rva) == 10, "Missing vtable DIR64 relocation.")
    must(after.u64(0x12C8C8) == after.base + section["rva"], "Incorrect vtable pointer.")
    must(before.relocations() == after.relocations(), "Relocations changed.")
    wrapper = candidate[section["raw"]:section["raw"] + 0xB2]
    imports = before.imports()
    calls = []
    for match in re.finditer(b"\xff\x15", wrapper):
        pos = match.start()
        target = section["rva"] + pos + 6 + struct.unpack_from("<i", wrapper, pos + 2)[0]
        calls.append(dict(offset=pos, iat_rva=hex(target), import_name=imports.get(target)))
    must([call["import_name"] for call in calls]
         == ["CreateThread", "CloseHandle", "RoInitialize", "RoUninitialize"],
         "Unexpected worker import targets.")
    call_pos = 0x96
    must(wrapper[call_pos] == 0xE8, "Original-body call moved.")
    body_rva = section["rva"] + call_pos + 5 + struct.unpack_from("<i", wrapper, call_pos + 1)[0]
    must(body_rva == 0x42489, "Unexpected original function target.")
    exception_rva, exception_size = after.directory(3)
    must(exception_size == 0x84F0, "Incorrect exception-directory size.")
    entries = [struct.unpack_from("<III", candidate, after.offset(exception_rva) + i)
               for i in range(0, exception_size, 12)]
    must(all(a[0] < b[0] for a, b in zip(entries, entries[1:])), "Unsorted runtime functions.")
    must(entries[-2:] == [(0x17E000, 0x17E072, 0x17E0C0),
                         (0x17E080, 0x17E0B2, 0x17E0C8)], "Incorrect runtime functions.")
    # UNWIND_INFO: version 1, five-byte prologue, two codes, no frame register;
    # allocation of 48/32 bytes, then push RBX. These are metadata semantics.
    for rva, allocation_code in [(0x17E0C0, 0x52), (0x17E0C8, 0x32)]:
        fields = struct.unpack_from("8B", candidate, after.offset(rva))
        must(fields == (1, 5, 2, 0, 5, allocation_code, 1, 0x30),
             "Incorrect unwind records.")
    return candidate, dict(regions=metadata, changed_bytes=changed, iat_checks=calls,
                           original_body_rva=hex(body_rva), vtable_slot_rva=hex(vtable_rva),
                           vtable_dir64_relocation=True, unwind_entries=entries[-2:])


def validate_paths(helper, patch_source, output_dir):
    helper = Path(helper).resolve(strict=True)
    patch_source = Path(patch_source).resolve(strict=True)
    output_dir = Path(output_dir).resolve()
    must(helper.is_file() and patch_source.is_file(), "Both inputs must be regular files.")
    must(helper != patch_source, "Helper and patch-source inputs must differ.")
    must(output_dir != helper and output_dir != patch_source, "Output aliases an input.")
    must(output_dir != helper.parent and helper.parent not in output_dir.parents,
         "Output must be outside the helper's installation directory.")
    must(output_dir not in helper.parents and output_dir not in patch_source.parents,
         "Output must not be an ancestor of an input file.")
    if output_dir.exists():
        must(output_dir.is_dir() and not any(output_dir.iterdir()),
             "Output directory must be empty or nonexistent; no files overwritten.")
    return helper, patch_source, output_dir


def prepare(helper, patch_source, output_dir):
    helper, patch_source, output_dir = validate_paths(helper, patch_source, output_dir)
    original = helper.read_bytes()
    source_data = patch_source.read_bytes()
    candidate, details = build_candidate(original, source_data)
    # Catch replacement of an input during static analysis before staging anything.
    must(sha(helper.read_bytes()) == INPUT_SHA, "Helper changed during analysis.")
    must(sha(patch_source.read_bytes()) == SOURCE_SHA, "Source changed during analysis.")
    manifest = dict(
        schema_version=1, status="STATICALLY_STAGED_NOT_EXECUTED_NOT_INSTALLED",
        input_sha256=INPUT_SHA, candidate_sha256=OUTPUT_SHA,
        helper_path=str(helper), original_filename="original.bin",
        candidate_filename="candidate.bin", file_size=FILE_SIZE,
        source_sha256=SOURCE_SHA, source_commit=SOURCE_COMMIT,
        source_url=SOURCE_URL, source_profile=PROFILE, observed_sky_version="0.7.13",
        unsigned_warning=UNSIGNED_WARNING, **details,
    )
    files = {"original.bin": original, "candidate.bin": candidate,
             "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode("utf-8")}
    output_dir.mkdir(parents=True, exist_ok=True)
    must(not any(output_dir.iterdir()), "Output directory became nonempty; no writes.")
    for name, data in files.items():
        # Exclusive creation never replaces any existing file, including on retry.
        with (output_dir / name).open("xb") as stream:
            stream.write(data)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path,
                        help="Exact original helper executable (read only)")
    parser.add_argument("--patch-source", required=True, type=Path,
                        help="Separately obtained, pinned upstream PS1 (text only)")
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="Empty staging directory outside the helper installation")
    args = parser.parse_args(argv)
    try:
        manifest = prepare(args.helper, args.patch_source, args.output_dir)
    except (PreparationError, OSError, ValueError, struct.error) as error:
        print(f"Preparation refused: {error}", file=sys.stderr)
        return 1
    print(json.dumps({key: manifest[key] for key in
                      ("status", "input_sha256", "candidate_sha256", "unsigned_warning")}, indent=2))
    print("Staged only. No helper was installed, executed, or stopped.")
    print("Keep the staging folder private: its manifest contains a local path.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
