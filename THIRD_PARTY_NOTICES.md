# Attribution and third-party material

The callback/MTA-worker approach and byte-region profile were informed by:

- [chen0416ccc-cpu/codex-windows-fast-patch-skill](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill), pinned commit [`14b418f71b3cd56b3c1cca41db5933dfbc30fbd1`](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/tree/14b418f71b3cd56b3c1cca41db5933dfbc30fbd1).
- Its [`scripts/patch-computer-use-helper-win10.ps1`](https://github.com/chen0416ccc-cpu/codex-windows-fast-patch-skill/blob/14b418f71b3cd56b3c1cca41db5933dfbc30fbd1/scripts/patch-computer-use-helper-win10.ps1), profile `@oai/sky 0.7.12 helper 6FCC7C64`.
- Source-text SHA-256: `8F961A6AB639F1E9FB2BE91F7F2F429F07CF9A68E80FCECD3654B525C60450D1`.

No license file was found in that pinned upstream tree. Its patch script, machine-code byte tables, and documentation are not vendored in this repository or relicensed by its MIT license. Users obtain that source separately; the preparation tool verifies it and parses it only as data. Attribution is not a claim of permission to redistribute upstream material.

Related first-party issue discussions contain community reports, not an official endorsement:

- [OpenAI Codex issue #51245](https://github.com/openai/codex/issues/51245)
- [OpenAI Codex issue #50362](https://github.com/openai/codex/issues/50362)
- [October 24 report on 0.7.13](https://github.com/openai/codex/issues/50362#issuecomment-6378345173)

The latter report describes a successful local experiment but publishes no implementation, so it cannot validate this candidate by itself.

OpenAI's helper executable and any modified copies remain subject to the vendor's rights and applicable terms. No vendor binary is distributed here. ChatGPT, Codex, Windows, and other product names identify the affected software; this project is not affiliated with or endorsed by OpenAI or Microsoft.

The MIT license in this repository covers only its original tooling, tests, and documentation.
