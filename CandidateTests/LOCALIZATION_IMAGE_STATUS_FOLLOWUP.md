# Settings and image-reply status follow-up

Baseline: phone candidate 5055, `50fb533d08f97ca0a444f71be6da77da5a501ba7`.

- Settings and settings search reuse the same 20-point icon and 32-point frame for Language as the other rows. The provider toolbar keeps its existing presentation.
- Image capability no longer emits speculative image progress in ordinary or tool-enabled Chat Completions. Existing ordinary waiting UI applies until reply content arrives. Explicit Responses image-generation progress still appears, and direct image payloads are still decoded and displayed.
- Removed the now-unused `sseStream.initialEvents` parameter and emission loop. Request bodies, modalities, timeouts, image decoding, cancellation and persistence are unchanged.
- Localized native image progress/cancellation, speech validation and system speech title, search configuration errors, app-owned model group titles, and background-save warnings. User names, provider text and model IDs stay unchanged. The old waiting-stage translation supports existing recorded event text.

Validation:

- Production native-image transport harness: PASS, 325 assertions and 62 synthetic localhost requests. Includes image-capable text-only replies without image progress, explicit image progress before image delivery, ordinary/tool routes, mixed output, cancellation, errors and attachment persistence.
- Compiled localization host checks: PASS for Chinese/English lookup, interpolation, persisted language choice and notification isolation.
- Catalog/source checks: PASS; 1,893 main catalog entries and 6 permission entries. AppModel business state and 14 drawer/navigation ownership blocks remain unchanged.
- Generic iOS Debug build, signing disabled: BUILD SUCCEEDED after final cleanup.

No phone installation, new archive, upload or App Review modification was performed. Build number remains the baseline value until a deployment candidate is prepared. These checks do not establish physical-device visual or performance acceptance.
