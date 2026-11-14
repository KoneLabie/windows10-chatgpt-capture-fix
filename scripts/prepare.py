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

# Selection is by the entire original file, never by a package/version label.
PROFILES = {
    "11825CB78575D9099AED8F13D16F78B03C20A1A0EBC809CF78B406FB2F25F5F8": {
        "candidate_sha256": "1071E8CC945EDDFC466637CF096852E670D21AFA396FE7CCA70B107C3DE3EFC5",
        "changed_bytes": 552,
        "layout": "october",
    },
    "49C7F43DA0C2A9DBCADFB0C993058147018BF7C1D0FDE4360DE11ACE2C98F45D": {
        "candidate_sha256": "25A8CD31B5BC44C387CBF53EC3FE4CD314B5FCAC0D8D84201F444F1B2DB10FAB",
        "changed_bytes": 551,
        "layout": "october",
    },
    "F8AD259CAA82BC2A62C26CB1A3428E558D26959DE7B4D5BCE0D708F5C40E81D9": {
        "candidate_sha256": "7BCF0B19481A96F478760A345B389AE47C44D6E2A6F745B331B9043CD9F7E804",
        "changed_bytes": 551,
        "layout": "november",
    },
    "A1EB13F38DC0214AE56D5C8B676B3740054A0818AB2BB68801B7AEDC85909DED": {
        "candidate_sha256": "210502D9B2FD64F66613DDDD79BFA6942EB3CBC5472C10387AB72B9279406ADF",
        "changed_bytes": 552,
        "layout": "november_a1",
    },
}
# These layouts are selected only by the whole-file hashes above. They are not
# templates for arbitrary files reporting the same library version.
LAYOUTS = {
    "october": {
        "file_size": 1551152,
        "source_sha256": "8F961A6AB639F1E9FB2BE91F7F2F429F07CF9A68E80FCECD3654B525C60450D1",
        "source_commit": "14b418f71b3cd56b3c1cca41db5933dfbc30fbd1",
        "source_profile": "0.7.12-6FCC7C64",
        "source_marker": "Name = '@oai/sky 0.7.12 helper 6FCC7C64",
        "sky_version": "0.7.13",
        "section_count": 10, "section_rva": 0x17E000, "section_raw": 0x176E00,
        "vtable_raw": 0x12C8C8, "callback_rva": 0x42489,
        "exception_rva": 0x151000, "exception_size": 0x84D8,
        "exception_append": 0x1574D8,
        "adapt_november": False,
    },
    "november": {
        "file_size": 1548592,
        "source_sha256": "D56FD5CBD327C9D8A230BBB048536F23AD4779BA8D2154467773BD641A171310",
        "source_commit": "87bea9f9143cf904a579bdab30e96fe93678232e",
        "source_profile": "0.7.17-7F73CF56-mapped-to-exact-0.7.18-F8AD259C",
        "source_marker": "Name = '@oai/sky 0.7.17 helper 7F73CF56",
        "sky_version": "0.7.18",
        "section_count": 9, "section_rva": 0x17C000, "section_raw": 0x176400,
        "vtable_raw": 0x12BB00, "callback_rva": 0x42544,
        "exception_rva": 0x150000, "exception_size": 0x8478,
        "exception_append": 0x156878,
        "callback_sha256": "D91DCF08268861A239E394031B7FCEE921E0F3FCCE4DA4953ABFA4F038A8723E",
        "adapt_november": True,
    },
    "november_a1": {
        "file_size": 1549104,
        "source_sha256": "D56FD5CBD327C9D8A230BBB048536F23AD4779BA8D2154467773BD641A171310",
        "source_commit": "87bea9f9143cf904a579bdab30e96fe93678232e",
        "source_profile": "0.7.17-7F73CF56-mapped-to-exact-0.7.21-A1EB13F3",
        "source_marker": "Name = '@oai/sky 0.7.17 helper 7F73CF56",
        "sky_version": "0.7.21",
        "section_count": 9, "section_rva": 0x17C000, "section_raw": 0x176600,
        "vtable_raw": 0x12BB48, "callback_rva": 0x42544,
        "exception_rva": 0x150000, "exception_size": 0x8478,
        "exception_append": 0x156A78,
        "callback_sha256": "43987630A774CBC73EB06AA282E1EBA8EF457586D40A8493E59E14A959117362",
        "adapt_november": True,
    },
}
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


def profile_for_hash(original_hash):
    profile = PROFILES.get(original_hash)
    must(profile is not None, "Original helper SHA-256 mismatch; unsupported build.")
    return profile


def parse_regions(source_data, layout):
    """Accept only the reviewed source bytes, then parse literal records."""
    must(sha(source_data) == layout["source_sha256"], "Upstream source SHA-256 mismatch.")
    source = source_data.decode("utf-8-sig")
    marker = layout["source_marker"]
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
    if layout["adapt_november"]:
        adapt_november_regions(regions, layout)
    return regions


def adapt_november_regions(regions, layout):
    """Apply separately reviewed exact-build mappings to pinned upstream data."""
    by_name = {r["name"]: r for r in regions}
    by_name["frame-arrived-busy-return"]["offset"] = 0x41979
    by_name["frame-arrived-once-flag"]["offset"] = 0x4198A
    by_name["frame-arrived-vtable"]["offset"] = layout["vtable_raw"]
    by_name["frame-arrived-vtable"]["original"] = struct.pack("<Q", 0x140042544)
    by_name["pe-certificate-directory"]["original"] = struct.pack("<II", layout["section_raw"], 0x3D30)
    by_name["mta-wrapper-and-unwind"]["offset"] = layout["section_raw"]
    # A1's larger .rdata moved later raw sections, with their RVAs unchanged.
    section_header = bytearray(by_name["mta-section-header"]["patched"])
    must(struct.unpack_from("<I", section_header, 20)[0] == 0x176400,
         "Unexpected upstream wrapper file offset.")
    struct.pack_into("<I", section_header, 20, layout["section_raw"])
    by_name["mta-section-header"]["patched"] = bytes(section_header)
    for name in ("pe-exception-directory-size", "pdata-virtual-size"):
        by_name[name]["original"] = struct.pack("<I", 0x8478)
        by_name[name]["patched"] = struct.pack("<I", 0x8490)
    by_name["mta-runtime-functions"]["offset"] = layout["exception_append"]
    worker = bytearray(by_name["mta-wrapper-and-unwind"]["patched"])
    must(worker[0x96] == 0xE8, "Expected direct original-callback call.")
    upstream_target = 0x17C000 + 0x9B + struct.unpack_from("<i", worker, 0x97)[0]
    must(upstream_target == 0x4247A, "Unexpected upstream callback destination.")
    struct.pack_into("<i", worker, 0x97, 0x42544 - (0x17C000 + 0x9B))
    by_name["mta-wrapper-and-unwind"]["patched"] = bytes(worker)


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


def validate_original_layout(original, before, layout):
    must(before.count == layout["section_count"] and before.image_size == layout["section_rva"],
         "Unexpected original PE extent.")
    must(before.directory(3) == (layout["exception_rva"], layout["exception_size"]),
         "Unexpected original exception directory.")
    must(before.directory(4) == (layout["section_raw"], 0x3D30),
         "Unexpected original certificate directory.")
    append = layout["exception_append"]
    must(before.offset(layout["exception_rva"]) + layout["exception_size"] == append,
         "Incorrect exception append position.")
    must(original[append:append + 24] == bytes(24), "Nonzero exception padding.")
    must(before.u64(layout["vtable_raw"]) == before.base + layout["callback_rva"],
         "Original callback vtable changed.")
    if layout["adapt_november"]:
        callback = original[before.offset(0x42544):before.offset(0x45BDE)]
        must(sha(callback) == layout["callback_sha256"],
             "Callback body changed.")
        must(original[0x41979:0x4197F] == bytes.fromhex("0f855b310000"), "Busy branch changed.")
        must(0x42579 + 6 + struct.unpack_from("<i", original, 0x4197B)[0] == 0x456DA,
             "Original busy destination changed.")
        must(original[0x4198A:0x4198C] == bytes.fromhex("740d"), "Once branch changed.")


def build_candidate(original, source_data):
    original_hash = sha(original)
    profile = profile_for_hash(original_hash)
    layout = LAYOUTS[profile["layout"]]
    must(len(original) == layout["file_size"], "Original helper size mismatch.")
    regions = parse_regions(source_data, layout)
    before = PE(original)
    validate_original_layout(original, before, layout)
    candidate, metadata, changed = apply_regions(original, regions)
    must([r["name"] for r in metadata if not r["old_profile_match"]]
         == ["pe-checksum", "mta-wrapper-and-unwind"], "Unexpected profile differences.")
    must(len(candidate) == len(original), "File length changed.")
    must(sha(candidate) == profile["candidate_sha256"], "Candidate SHA-256 mismatch; refusing output.")
    must(changed == profile["changed_bytes"], "Unexpected changed-byte count.")
    after = PE(candidate)
    if layout["adapt_november"]:
        must(0x42579 + 6 + struct.unpack_from("<i", candidate, 0x4197B)[0] == 0x456BC,
             "Patched busy destination changed.")
    must(after.count == before.count + 1, "Unexpected section count.")
    section = after.sections[-1]
    section_rva = layout["section_rva"]
    must(section == dict(name=".cuw10", virtual_size=0xD0, rva=section_rva,
                         raw_size=0x200, raw=layout["section_raw"], flags=0x60000020),
         "Unexpected new section.")
    must(after.directory(4) == (0, 0), "Certificate directory not cleared.")
    must(after.image_size == section_rva + 0x1000, "Unexpected image extent.")
    for previous, current in zip(after.sections, after.sections[1:]):
        must(previous["rva"] + previous["virtual_size"] <= current["rva"],
             "Overlapping virtual sections.")
    vtable_rva = before.rva(layout["vtable_raw"])
    must(before.relocations().get(vtable_rva) == 10, "Missing vtable DIR64 relocation.")
    must(after.u64(layout["vtable_raw"]) == after.base + section_rva, "Incorrect vtable pointer.")
    must(before.relocations() == after.relocations(), "Relocations changed.")
    wrapper = candidate[section["raw"]:section["raw"] + 0xB2]
    imports = before.imports()
    must(after.imports() == imports, "Imports changed.")
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
    must(body_rva == layout["callback_rva"], "Unexpected original function target.")
    exception_rva, exception_size = after.directory(3)
    must((exception_rva, exception_size) == (layout["exception_rva"], layout["exception_size"] + 24),
         "Incorrect exception directory.")
    original_table = before.offset(exception_rva)
    must(candidate[original_table:original_table + layout["exception_size"]]
         == original[original_table:original_table + layout["exception_size"]],
         "Original exception records changed.")
    entries = [struct.unpack_from("<III", candidate, after.offset(exception_rva) + i)
               for i in range(0, exception_size, 12)]
    must(all(a[0] < b[0] for a, b in zip(entries, entries[1:])), "Unsorted runtime functions.")
    must(entries[-2:] == [(section_rva, section_rva + 0x72, section_rva + 0xC0),
                         (section_rva + 0x80, section_rva + 0xB2, section_rva + 0xC8)],
         "Incorrect runtime functions.")
    # UNWIND_INFO: version 1, five-byte prologue, two codes, no frame register;
    # allocation of 48/32 bytes, then push RBX. These are metadata semantics.
    for rva, allocation_code in [(section_rva + 0xC0, 0x52), (section_rva + 0xC8, 0x32)]:
        fields = struct.unpack_from("8B", candidate, after.offset(rva))
        must(fields == (1, 5, 2, 0, 5, allocation_code, 1, 0x30),
             "Incorrect unwind records.")
    return candidate, dict(input_sha256=original_hash, candidate_sha256=profile["candidate_sha256"],
                           regions=metadata, changed_bytes=changed, iat_checks=calls,
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
    layout = LAYOUTS[profile_for_hash(details["input_sha256"])["layout"]]
    # Catch replacement of an input during static analysis before staging anything.
    must(sha(helper.read_bytes()) == details["input_sha256"], "Helper changed during analysis.")
    must(sha(patch_source.read_bytes()) == layout["source_sha256"], "Source changed during analysis.")
    manifest = dict(
        schema_version=1, status="STATICALLY_STAGED_NOT_EXECUTED_NOT_INSTALLED",
        helper_path=str(helper), original_filename="original.bin",
        candidate_filename="candidate.bin", file_size=layout["file_size"],
        source_sha256=layout["source_sha256"], source_commit=layout["source_commit"],
        source_url=("https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/blob/"
                    + layout["source_commit"] + "/scripts/patch-computer-use-helper-win10.ps1"),
        source_profile=layout["source_profile"], observed_sky_version=layout["sky_version"],
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
