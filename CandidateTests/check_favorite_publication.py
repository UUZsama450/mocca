"""Run the production publication predicate against favorite landing states."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Mocca/RootView.swift').read_text()
start = source.index('        func matches(', source.index('    private func awaitNativeTranscriptPublication('))
end = source.index('        guard !Task.isCancelled', start)
predicate = source[start:end]
swift = '''import Foundation
import CoreGraphics
final class Scroll {
    var window: Int? = 1
    var contentOffset = CGPoint(x: 0, y: 1161.7)
    var contentSize = CGSize(width: 402, height: 4243.7)
}
final class Holder { var scrollView: Scroll?; init(_ s: Scroll) { scrollView = s } }
struct NativeChatScrollGeometry {
    var publicationID: AnyHashable = 7
    var containerSize = CGSize(width: 402, height: 874)
    var contentOffset = CGPoint(x: 0, y: 1161.7)
    var contentSize = CGSize(width: 402, height: 4243.7)
    var frames: [UUID: CGRect] = [:]
}
@main struct Checks {
    static func main() {
        let publication = 7
        let target = UUID(), other = UUID()
        var requiredTarget: (messageID: UUID, minY: CGFloat)? = (target, 87.3)
        let scroll = Scroll()
        let chatScrollViewBox = Holder(scroll), nativeTranscriptDriver = Holder(scroll)
        var checks = 0
        func check(_ pass: Bool, _ reason: String) { precondition(pass, reason); checks += 1 }
'''
swift += predicate
swift += '''
        var geometry = NativeChatScrollGeometry()
        check(!matches(nil), "missing publication is not ready")
        check(!matches(geometry), "new publication with no target frame is not a favorite landing")
        geometry.frames[other] = CGRect(x: 0, y: 87.3, width: 402, height: 500)
        check(!matches(geometry), "another visible row cannot acknowledge the favorite")
        geometry.frames[target] = CGRect(x: 0, y: 300, width: 402, height: 2841.3)
        check(!matches(geometry), "moving target has not retained its prior landing")
        geometry.frames[target]!.origin.y = 87.4
        check(matches(geometry), "measured current target at its landing is accepted")
        geometry.publicationID = 6
        check(!matches(geometry), "old publication cannot acknowledge a new page")
        geometry.publicationID = 7
        geometry.contentOffset.y = 1266.7
        check(!matches(geometry), "stale pre-measurement offset is rejected")
        geometry.contentOffset.y = 1161.7
        geometry.contentSize.height = 4348.7
        check(!matches(geometry), "stale pre-measurement height is rejected")
        geometry.contentSize.height = 4243.7
        geometry.frames[target]!.origin.y = 48
        requiredTarget = (target, 48)
        check(matches(geometry), "short clamped target keeps its verified coordinate")
        scroll.window = nil
        check(!matches(geometry), "detached viewport is rejected")
        scroll.window = 1
        nativeTranscriptDriver.scrollView = Scroll()
        check(!matches(geometry), "replaced scroll owner is rejected")
        nativeTranscriptDriver.scrollView = scroll
        requiredTarget = nil
        geometry.frames = [:]
        check(matches(geometry), "ordinary publication clients keep their existing semantics")
        print("PASS \\(checks) production favorite publication checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mocca-favorite-publication-') as directory:
    out = Path(directory)
    (out / 'Checks.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                    str(out / 'Checks.swift'), '-o', str(out / 'checks')], check=True)
    subprocess.run([str(out / 'checks')], check=True)
