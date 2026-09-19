# Mocca 4854 Liquid Glass cat icon candidate

Base: accepted and committed 4850 drawer-settle candidate.

Changes:

- Keep the separate black-and-gold 4851 candidate unchanged.
- Apply the latest mint background, white cat, and white speech-bubble layout
  from the `develop` Icon Composer draft while leaving that draft untouched.
- Keep the background-circle layer hidden.
- Split the combined detail artwork into independent cat-face and bubble-dot
  layers, align the dots with the speech bubble, and omit the sparkle entirely.
- Apply Liquid Glass to the white cat-body layer to match the speech bubble;
  preserve every position, scale, color, and visibility setting from 4853.
- Give the cat body and speech bubble the same explicit solid-white fill so
  their Liquid Glass material does not inherit different source-image whites.
- Disable the extra 50-percent group translucency so the larger cat surface
  does not pick up more mint background than the smaller speech bubble; keep
  Liquid Glass enabled independently on both white shapes.
- Make the About page load the compiled primary application icon, with its
  declared bundle icon file as a compatibility fallback.
- Keep the old assistant avatar only as a failure fallback.
- Bump the app and extension build number to 4854.

Unchanged: the accepted 4850 drawer-settle implementation, chat rendering,
persistence, and chat data.

Verification:

- Icon Composer JSON and diff checks passed.
- Standalone compiled-icon preview and signed generic iOS Release build
  succeeded.
- App and extension are arm64, strictly signed, and have matching dSYM UUIDs.
- Same-bundle overwrite install and launch succeeded on iPhone 17 Pro.
- Signed generic iOS Release succeeded; app and extension are arm64, strictly
  signed, and have matching dSYM UUIDs.
- Same-bundle overwrite install and launch succeeded on iPhone 17 Pro.
- Device readback confirmed Mocca `0.1.0 (4854)` and both app/extension
  processes. No uninstall, data clear, chat-container access, or new chat
  snapshot was performed.
