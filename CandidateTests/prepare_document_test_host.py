"""Prepare an isolated full-app XCTest host. No device action or provider access.

Run with /usr/bin/python3, passing a NEW temporary output directory.
The tests generate their own files and intercept document.test with URLProtocol.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
subprocess.run([
    '/usr/bin/python3', str(root / 'CandidateTests/prepare_review_correctness_host.py'), str(output)
], check=True)
project = output / 'Mocca.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace(
    '"$(MOCCA_BUNDLE_IDENTIFIER)"', 'com.uuzsama450.mocca.documentqa20261025'
).replace(
    '"$(MOCCA_BUNDLE_IDENTIFIER).GenerationActivityExtension"', 'com.uuzsama450.mocca.documentqa20261025.GenerationActivityExtension'
).replace(
    'com.uuzsama450.mocca.review5047qa', 'com.uuzsama450.mocca.documentqa20261025'
))
# Change access only in the disposable host to render the real options view.
view = output / 'Mocca/DocumentAttachmentViews.swift'
view.unlink()
view.write_text((root / 'Mocca/DocumentAttachmentViews.swift').read_text().replace(
    'private struct DocumentAttachmentOptionsView', 'struct DocumentAttachmentOptionsView', 1
))
(output / 'Slice1UITests/Slice1UITests.swift').write_text('\n'.join(
    (root / 'CandidateTests' / name).read_text()
    for name in ['DocumentAttachmentTests.swift', 'RecordStorageTests.swift', 'ComposerIndependentMotionTests.swift', 'SearchToolPromptTests.swift']
))
print(output)
