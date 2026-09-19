# Device 4989 verification

Product:5d8b1f6, following shared-handoff46c8048. Built from the isolated mocca-version-reading-handoff-4989-a candidate. Sources and hashes recorded in work/verification/build-source-sha256.json. Final Release build-signed-4989.log succeeded; build-before-viewport-review.log is an intentionally interrupted earlier build, not deployment proof.

PASS: 55 production-extracted shared handoff behavior checks, 24576 deletion selector combinations, 24 entry checks, 13 window checks plus1830 combinations, Swift parse, whitespace checks. Mocks do not establish SwiftUI pixels, performance or actual persistence behavior.

PASS: main app and GenerationActivityExtension both0.1.0(4989), exact migration bundle identities, strict signatures, arm64, matching Mach-O/dSYM UUIDs, current device provisioning profile/team/entitlements. See artifact-4989-verification.json.

PASS: phone readback before installation migration4988/formal4957; same-bundle overwrite installed4989. After readback migration4989/formal4957. Main PID52349 and extension PID52345 belong to the installed0BADEAEA-5ECE-4C86-888F-74F666D52AB6 app bundle. Normal application launch succeeded with -diagnoseChatBottom and console logging is active (unified exec session52901). The devicectl console launch JSON may not be finalized until the console exits; launch output, live diagnostics and independent processes are the current launch evidence. Do not Ctrl-C this console because it forwards to the phone process.

Physical acceptance PENDING: first middle/off-bottom long→short, then reverse/repeated versions, actual-bottom tail, deletion, ordinary entry, paging, focused composer, user interruption. Internal LANDED is not visual acceptance. No simulator, uninstall, clearing, import/chat copy or extra chat backup performed. Same-bundle install is not byte-for-byte chat verification.

Artifacts and live log are under work/verification; machine summary result-4989.json. Signed4988 rollback artifact is retained at the path recorded in rollback-4988.json. User was notified that4989 is installed and ready for the original middle-version test.

## User feedback and diagnostics off

User reported “没问题” and requested logging off. This is positive physical feedback for the current test, not an itemized completion of every matrix case. Relaunched the same installed4989 bundle normally with launch arguments[]; PID52839, same installed bundle URL, success recorded in launch-4989-normal.json. Diagnostic console ended when its old app instance terminated. No source/build/install or data changes.
