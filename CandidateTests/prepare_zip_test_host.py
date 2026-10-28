"""Create an isolated ZIP/document XCTest host with synthetic files and fake HTTP."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/python3', str(root / 'CandidateTests/prepare_document_test_host.py'), str(output)], check=True)
project = output / 'Mocca.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace('com.uuzsama450.mocca.documentqa20261025', 'com.uuzsama450.mocca.zipqa20261028'))
tests = output / 'Slice1UITests/Slice1UITests.swift'
source = tests.read_text() + '\n' + (root / 'CandidateTests/ZIPAttachmentTests.swift').read_text()
# The inherited motion fixture used a fixed 0.5 s delay before looking for its
# UIKit editor. Require actual layout/readiness in this disposable host instead.
# Motion/content/history assertions and production sources are unchanged.
anchor = '@MainActor final class ComposerIndependentMotionTests: XCTestCase {'
helper = '''
    func zipQAReadyEditor(_ view: UIView) async throws -> ComposerInputTextView {
        for _ in 0..<150 {
            view.setNeedsLayout(); view.layoutIfNeeded()
            if let editor = nativeEditor(view), editor.window != nil, editor.bounds.width > 0 { return editor }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(nativeEditor(view), "Composer fixture never attached its native editor")
    }
'''
assert source.count(anchor) == 1
source = source.replace(anchor, anchor + helper).replace(
    'let editor = try XCTUnwrap(nativeEditor(host.view))',
    'let editor = try await zipQAReadyEditor(host.view)'
)
tests.write_text(source)
print(output)
