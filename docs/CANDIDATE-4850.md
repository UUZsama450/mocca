# Mocca 4850 drawer-settle idle cleanup candidate

Base: exact 4849 semantic-isolation candidate.

This candidate adds one ordinary-path fast path. When opening the drawer with
no active keyboard, navigation, message-target, version replacement, send
positioning, bottom materialization, or conversation-return work, the leaf
drawer observer skips the established cleanup block instead of replaying nil
and false state writes at the settle boundary.

If any cleanup owner is active, the complete 4849 cleanup block still runs.

Unchanged: drawer gesture and spring, 120 Hz display link, rounded clipping,
shadow, scrim, transcript rendering, Markdown/TextKit, persistence, and chat
data.

Validation:

- Swift parser and `git diff --check`: passed.
- Unsigned Swift 6 whole-module Release build: passed.
- Signed arm64 Release build, strict signature verification, and app/extension
  dSYM UUID matching: passed.
- Same-bundle installation on the target iPhone and installed-version readback
  as Mocca 0.1.0 (4850): passed.
- Ordinary long-chat drawer settle: physically accepted as substantially
  smoother.

Keyboard-open drawer handling, switching conversations behind the drawer, and
opening the drawer during streaming remain adjacent regression checks; they
were preserved by source audit but were not included in the reported physical
acceptance.
