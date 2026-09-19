# 4979 record storage boundary

Base: the frozen 4977 encoding-cache candidate, derived from installed 4977; 4978 installed the record store. 4979 changes only ConversationStore.swift and the build number relative to 4978. UI, network, send ordering, stream scheduling, animation, keyboard and scrolling are unchanged.

## One recovery route

SQLite records contain independently encoded messages, conversations, and ordering metadata. Only changed records are encoded and written. Each primary transaction records its generation on modified rows; deletions remain as small tombstones until the next independent backup commit. The independent database contains the preceding complete snapshot. Redundant per-record prior values and the in-file previous-generation recovery route are removed. Nullable old columns remain for 4978 compatibility.

Before committing primary generation N+1, hold its write lock, verify ownership, and update the independent backup to committed generation N. A matching lineage plus generation N-1 allows selecting only primary rows changed after that generation, including tombstones. Apply these encoded rows and the generation header in one backup transaction. Then retire old tombstones, apply the primary changes and commit. A failed primary commit can leave both files at N; retry recognizes the already-completed backup. A same-lineage backup newer than the primary is refused, never overwritten.

Generation headers carry an optional UUID lineage. Legacy 4978 lacks it; a verified 4978 import or recovered/recreated primary establishes a fresh lineage so unrelated generation numbers cannot be mistaken for matching snapshots. Initial import/4978 upgrade aligns the backup once during store loading, using encoded rows without decoding backup message bodies. Subsequent restarts load only the primary; the first send reads the small backup header and outstanding records. Normal saves keep no decoded backup snapshot and no extra encoded-delta cache. Missing or unrelated backup lineage requires one full seed from the validated primary, not a guessed incremental update.

## Durability and compatibility

Both databases use DELETE rollback journaling, FULL synchronous, fullfsync and completeUnlessOpen protection. The existing serial save executor owns the production store. The primary lock is acquired before the backup lock, and stale writers fail before changing the backup. A transaction failure leaves a complete prior or current generation, never partially applied messages.

SHA-256 protects record/header bytes. Cold primary loads and independent recovery decode and validate the complete topology and models. Backup synchronization hashes copied source records without decoding the full backup. As with warm 4978 saves, latent corruption in untouched backup records is detected when those records are read for recovery, not by a full backup scrub on every commit. Permission, busy, disk-full and I/O errors fail closed; they are not evidence for restoring older data. Unsupported schema versions do not silently fall back. Recovery uses only the independent backup, retains one rejected database at a fixed path, and rebuilds from a verified snapshot.

Legacy JSON is imported once. The unsupported-schema marker blocks old v1 apps before any new-format message mutation. Explicit export still emits v1 chats.json. Raw downgrade to 4977 is unsafe without first exporting/converting the latest chats; 4978 record-format interoperability is tested separately and does not authorize routine downgrades. Existing legacy backups and attachments remain intact. No phone chat snapshot was copied.

## Interaction boundary

Send still synchronously waits for successful durable storage before network dispatch. Successful streaming completion and debounced streaming saves use the existing asynchronous queue; stop/failure paths retain their synchronous contract. The active reply is saved as a complete individual message, not per-token fragments. Snapshot/ID traversal and value comparisons remain, as do final text parsing, rendering and UI state work. This change does not claim zero UI work or guarantee no phone hitches.

Validation covers cold reopen/first save, streamed-message completion followed by a new send, migration/interoperability, rollback/retry, deletion/re-add/reorder, nested fields, cold normalization, stale writers/newer backups, corruption/recovery, unsupported schemas and real process death before/after commit. Device build/sign/install proof is separate from user interaction acceptance.
