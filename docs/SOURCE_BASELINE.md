# Source baseline for publication preparation

This is an independent local publication snapshot based on development build 5058, not an App Store release. Its initial history starts with the prepared source tree from local commit `027ed5f17c00ec33ff1aee7525469f98164b8d6b`. Earlier development history remains in the original local repository. The commit identifiers below are provenance references; they are not commits included in this new repository. See [repository guide](REPOSITORY_GUIDE.md) for current scope and verification.

| Source | Commit | Meaning |
| --- | --- | --- |
| Development build 5058 | `ff15b568cee7b9e4e50500595130a66c3d2c3cbc` | Requested starting point; includes history title search |
| Development build 5057 | `5c199036a1b53b0423897555ae6f3096fc6f204e` | Previous development baseline |
| App Store submission 5057 | `ae032cc72afabc70d629f25964c2efa9206aae2f` | Separate production identity; submitted 2026-09-20 with manual release |

The iPhone 17 Pro was read back as 1.0 (5058) during preparation. All 149 files in its frozen source manifest matched the development baseline and the initial preparation checkout. This establishes source provenance, not physical interaction or performance acceptance.

## Preparation changes

- Neutral wording in synthetic test fixtures and previews; Unicode, whitespace, emoji and paired request/expectation coverage are preserved.
- A backup error says “备份文件” instead of “搬家包”; validation and failure behavior are unchanged.
- English and Simplified Chinese README files with matching navigation and content.
- Local absolute paths in historical instructions replaced with portable references.
- Three generated build-4982 device receipts omitted from this candidate tree. Originals remain in the original local source/history; historical validation notes are retained.
- The old build-4932 snapshot note is explicitly marked as historical.

This tree differs from the installed 5058. It does not replace the frozen 5058 baseline or the exact submitted 5057 source. No new device installation or App Store submission is part of this preparation.

## Intentionally retained

- LICENSE, NOTICE, third-party notices, Kelivo origins and compatibility identifiers.
- `5.1宝宝` as a legacy migration match, `qwq` as a model-family identifier, and the short-message filter's emoticon vocabulary.
- Sponsorship implementation, saved decorations and historical test coverage; new builds gate commerce explicitly.
- Stable Keychain service names and backup compatibility identifiers; app signing identity is configurable.

## Remaining before remote publication or binary distribution

- Review the independent repository's exact tree, history and author metadata before uploading it. Removing a current file does not remove it from Git history.
- Configure the intended GitHub repository and verify its visibility and source links.
- For a distributed binary, verify the exact corresponding source, release signing and distribution documents separately. This development snapshot is not the submitted 5057 source.
- Public-safe screenshots and confirmed download links, when available.

Older checklists and candidate notes describe their own point in time; they are not a current release dashboard. This snapshot is prepared for the private [UUZsama450/mocca](https://github.com/UUZsama450/mocca) repository. Public source release and binary distribution are separate steps.

## Validation for the first preparation pass

Native image/text host: 325 assertions passed. Drawer content equivalence: 1,524 checks passed. Assistant file contracts and the 100-assertion history-search host passed. The three edited product files passed Swift syntax parsing; edited Python scripts and the README relative links passed structural checks. This is not a full application build or device acceptance.

The older `check_chat_render_work_reuse.py` comparison harness is not compatible with the current localization, native-image dependencies and actor isolation. It remains a separate maintenance item; no pass is claimed. The assistant-file host uses an error-string lookup stand-in because its tests compare typed errors, not localization resources.

## Local privacy audit (2026-09-20)

The first preparation commit's 408 tracked files, 161 reachable commits, commit messages and 891 unique historical blobs were inspected. Gitleaks 8.30.1 reported four storage-key literals; each is a UserDefaults field name in SponsorStore, not a credential. Synthetic test credentials remain explicitly synthetic. No confirmed live credential was found by this pass.

All 25 unique binary assets are PNG app/icon/avatar artwork; visual review found no private photos or chat screenshots. Image metadata inspection found no GPS or owner fields. The current simulator test summary had its machine-specific device ID omitted without changing test outcomes.

The original commit history still contains a personal author email and nine local-path occurrences in earlier file versions. This audit does not make that history suitable for automatic publication. Preserve the local development history; choose the upload history and author metadata separately, retaining source provenance and attribution. No remote was created or updated.

## Portable build configuration (2026-09-20)

`Configuration/Shared.xcconfig` now supplies an unsigned-development placeholder identity, an empty team, and sponsorship off for Debug and Release. An ignored `Configuration/Local.xcconfig` can override all three. The extension identity and background task identifiers follow the selected app identity. See [build configuration](BUILD_CONFIGURATION.md).

The sponsorship setting controls the settings row, search result, destination, help section and StoreKit operations. Sponsorship sources, products, backup fields and existing decorations remain present. The shared scheme no longer automatically enables StoreKit simulation; developers can select the retained test file explicitly. This is a preparation variant, not a claim that the submitted 5057 or installed 5058 has these defaults.

The host gate test compiles the actual configuration and SponsorStore sources with a localization-only shim. It covers explicit YES/NO, missing, unresolved and invalid values; disabled paths return without loading products, waiting for transactions, purchasing or restoring. It does not validate successful real purchases or rendered iOS UI.

Unsigned iOS builds passed with Xcode 26.3: default Debug (sponsorship NO) and an exported-source Release with a synthetic local identity (sponsorship YES). Both app/extension identifiers and background task allowlists were checked in the built artifacts. Eight resolved-setting checks cover both targets, configurations and local overrides. Existing warnings in unchanged rendering code remain. No device installation, UI acceptance, real purchase, signing validation or remote publication is implied.

## Asset source and usage pass (2026-09-20)

The 54 PNG/SVG files present at the start of this pass were inventoried against pinned Kelivo/Lobe Icons sources, local creation evidence, code references and built asset catalogs. Thirteen unused PNGs and the superseded app-icon catalog configuration were removed. The maintainer chose to replace the old pink `AssistantAvatar` artwork with the current robot at all three scales while retaining the legacy asset name; no backup/model identifiers were changed. There are now 43 PNG/SVG files. See [asset audit](ASSET_AUDIT.md) and [inventory](ASSET_INVENTORY.json).

Lobe Icons' MIT license is included verbatim in the repository and app bundle. The cat icon's retained layers and layout, normal default avatars, service SVGs, and legacy Kelivo provider artwork remain unchanged. This source/usage record does not assert blanket permission to use every third-party trademark. Final binary/source alignment and publication history remain separate release tasks.
