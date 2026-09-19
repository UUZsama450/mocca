# 4991: Unclassified imported chats and simple Liquid Glass navigation

Baseline: the phone's migration app `com.uuzsama450.mocca.migration`, 0.1.0 (4990), from `0f5c4a4db33454fcc710d70b29a240ee1ada5b14`. All 41 retained build-input hashes matched the signed 4990 manifest before the clean worktree was created. Candidate branch: `codex/unclassified-assistant-4991`. The separate formal bundle remains 4957.

## Behavior

Persisted single chats with no assistant ID or an ID absent from the loaded assistant profiles are assigned to an ordinary assistant named `未分类`. A marker in its profile allows renaming/configuration and reuse across backup merges. If the user deletes it, a later explicit import creates a fresh assistant ID, avoiding stale bindings from the deleted identity. Defaults include disabled long-term/recent memory and no invented legacy persona. A user-created assistant with the same name is not reused. Group chats, known owners and unsaved placeholders are excluded.

Assignment changes only `Conversation.assistantID`. Conversation IDs, timestamps, title, summary, version selections, provider/model selection and migration metadata remain intact; message/attachment/author records are not inputs to the assignment. Existing title lists, search, branches and deletion use their normal paths. Deleting a conversation removes that conversation; deleting the destination assistant removes its owned single chats with the existing confirmation. Completed migration is not rerun on subsequent launches. Explicit later imports can reintroduce records included in the imported backup.

On first successful store load, the destination profile is saved before conversation references, and the one-time completion marker is set only after the conversation save succeeds. Profile save failure restores the prior in-memory graph; chat save failure retains the saved destination, restores the original conversation ownership, and leaves migration pending. A restart finds the persisted destination by its profile marker and reuses its ID. A blocked startup can retry after successful store reload. Both native and legacy imports collect missing owners after settings/chat merge and before selection repair/persistence. Import profile persistence failure blocks later conversation writes; successful import persistence also completes the launch marker. Collection does not run in sidebar rendering, gestures, scrolling or ordinary saves.

The simple navigation mode's sole return-to-bottom button uses one native `glassEffect(.regular, in: Circle())` on iOS 26. Its former material, custom stroke and shadow are removed. The circular face is 36 pt (previously 40), arrow is 15 pt (previously 16), and native hit area is 44 pt (previously 48). Earlier supported iOS versions use a plain system background. Existing action, inertia/tap handling, visibility rules and pressed animation remain. The four-button navigation panel is unchanged; the RootView diff is confined to `QuickReturnToBottomButton`.

## Validation

`/usr/bin/python3 CandidateTests/check_unclassified_assistant.py`: 52 checks passed, plus import/launch call-site checks. The harness extracts the actual Conversation and AssistantProfile declarations, legacy conversation converter, assignment, launch migration, import persistence boundary, assistant deletion, drawer title filter and branch constructor. It checks record-field preservation, opaque message preservation, owner/group/draft isolation, naming collisions, repeat import, rename retention, deletion/reopen, and injected profile/chat save interruptions. Framework services and persistence are synthetic; conversation deletion is extracted through its save boundary. This is not a full AppModel/SQLite/ZIP-import or iPhone UI test.

Existing checks passed: 22 ownership isolation cases; 1524 drawer/text equivalence checks; 55 deletion/version-handoff cases including 24576 selector combinations; 24 conversation-entry lifecycle cases. `git diff --check` passed. A source comparison verifies that the rest of RootView, including full navigation and scroll owners, is identical to 4990.

Signed build/deployment and phone storage readback are recorded separately in `work/verification`. Physical acceptance remains separate: select `未分类`, find the original title, open it, create a branch, and evaluate the smaller glass button in simple navigation mode. Destructive checks use synthetic data, never the user's real chats.

The retained signed 4990 artifact is the executable rollback point. It can read the ordinary destination assistant; reverting the executable does not undo persisted ownership changes or user deletions.

## Device result, 2026-09-10

Final signed Release succeeded after the recreation-identity refinement. Main app/extension are 0.1.0 (4991), arm64; strict signatures, device provisioning and matching dSYM UUIDs passed. Same-bundle installation and normal launch succeeded; the separate formal bundle remains 4957. Product commit: `8f9cec1`.

The authoritative pre-install readback contained 939 conversations and 14,200 messages, including 9 unassigned conversations with 339 messages. During post-install verification the user explicitly reported deleting the new assistant. The subsequent readback contained 930 conversations and 13,861 messages: exactly the original 9 unassigned conversation IDs were removed, all surviving conversation/message records were unchanged, and no new IDs appeared. The completion marker was true and the destination profile was absent. Reopening retained this graph exactly; the user confirmed “没出现捏！” in response to checking that the deleted assistant was not recreated. This deliberate deletion was preserved, without restoring the old chats.

All five pre-existing assistant profiles were semantically unchanged. One profile's serialized `localToolIDs` array reordered because its model type is `Set<String>`; reconstructing that ordering matched the pre-install field and full-profile hashes. No setting membership change occurred.

All inspected active record hashes and canonical conversation/message links were valid. Raw phone copies existed only in temporary directories and were deleted; verification retains IDs/hashes and counts. The initial preservation-only comparison correctly stopped when it encountered the user's deletion; the final comparison accounts for that explicitly reported action. Machine records are under `work/verification`, including `result-4991.json` and the three phone-store manifests.

Physical acceptance obtained: the user could delete the new assistant, and it did not reappear after reopening. The glass button's appearance/size and a full search/open/branch interaction matrix remain for user feedback; offline checks and installation are not substituted for that feedback.
