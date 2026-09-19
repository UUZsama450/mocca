# Phone-based send / stream integration 5041

Base: `f950728aafbcfa6db126628d81ac8eb46aa8b10f` (5038), branch `codex/drawer-native-hit-routing-5038`. Live device app metadata and the retained installation receipt identify 1.0 (5038), bundle `com.uuzsama450.mocca.migration`. All 142 retained Release build-input hashes match the clean source; the retained executable hash also matches the deployment receipt.

Integration branch: `codex/phone-5038-send-handoff-5041`.

The 5038 native drawer touch routing is retained. The net RootView change from common base 5036 (`0691110`) through 5040 (`1798e9f`) is applied without conflict:

- 5037: use a measured bounded tail destination without unnecessary intermediate materialization.
- 5039: end drawer search through its own FocusState so a delayed close callback cannot dismiss the chat editor.
- 5040: land a fully measured staged send once, then hand off to streaming after exact physical landing. Preserve existing lazy/history/keyboard-unified fallbacks.

Only three RootView functions and four build-number settings differ from 5038 in product code. The integrated RootView equals an independent clean three-way merge of 5036, 5038 and 5040; 47 other Swift files are unchanged. The other task's test driver is preserved byte-for-byte.

Integration evidence is retained in the main repository under `work/verification/phone-5038-send-handoff-5041/REPORT.md`. Simulator build and interaction verification do not establish iPhone animation smoothness. This integration task does not install or replace the phone app.

## Combined candidate validation

Debug simulator build passed with all 142 product inputs unchanged. A fresh 5041 QA runner executed 11 tests: two long/very-long sends, streaming reader takeover, two native drawer interaction cases, three search-focus cases, and three keyboard/history/tools/model cases. All passed with zero failures or skips.

Both automatic-follow sends issued one send-position scroll command and completed at the real bottom. The takeover case completed 160 local SSE chunks; 951,846 reading-area pixels matched exactly between a settled-drag screenshot taken during output and the completed-reply screenshot. Phone smoothness remains unverified for this combined build.
