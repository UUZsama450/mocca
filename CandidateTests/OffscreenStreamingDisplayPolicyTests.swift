import Foundation

@main
enum OffscreenStreamingDisplayPolicyTests {
    private static var assertions = 0

    static func main() {
        independentOwnersDoNotResumeEachOther()
        giantMessageUsesLiveBottomRatherThanMessageTop()
        approachingTailResumesBeforeItEntersViewport()
        activeScrollDefersCatchUpMutation()
        lazyTailCanAcquireAfterUserDetaches()
        passiveUpperReadingDoesNotAcquireWithoutUserDetach()
        invalidViewportFailsOpen()
        print("OFFSCREEN_STREAM_POLICY_TESTS=PASS assertions=\(assertions)")
    }

    private static func input(
        viewportHeight: CGFloat = 800,
        userDetachedFromTail: Bool = false,
        isScrolling: Bool = false,
        isAtBottom: Bool = false,
        isNearBottom: Bool = false,
        liveTailMaxY: CGFloat? = nil,
        lazyTailIsBelowViewport: Bool = false,
        isCurrentlySuspended: Bool = false
    ) -> OffscreenStreamingDisplayPolicyInput {
        OffscreenStreamingDisplayPolicyInput(
            viewportHeight: viewportHeight,
            userDetachedFromTail: userDetachedFromTail,
            isScrolling: isScrolling,
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom,
            liveTailMaxY: liveTailMaxY,
            lazyTailIsBelowViewport: lazyTailIsBelowViewport,
            isCurrentlySuspended: isCurrentlySuspended
        )
    }

    private static func expect(
        _ actual: OffscreenStreamingDisplayDesiredState,
        _ expected: OffscreenStreamingDisplayDesiredState,
        _ name: String
    ) {
        assertions += 1
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    private static func expect(
        _ actual: StreamingTextDisplaySuspensionTransition,
        _ expected: StreamingTextDisplaySuspensionTransition,
        _ name: String
    ) {
        assertions += 1
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    private static func assert(_ condition: Bool, _ name: String) {
        assertions += 1
        guard condition else {
            fatalError(name)
        }
    }

    private static func independentOwnersDoNotResumeEachOther() {
        var ledger = StreamingTextDisplaySuspensionLedger()
        expect(ledger.set(.drawer, suspended: true), .began, "drawer begins")
        expect(ledger.set(.detachedTail, suspended: true), .unchanged, "tail joins")
        expect(ledger.set(.drawer, suspended: false), .unchanged, "drawer cannot end tail")
        assert(ledger.isSuspended, "tail still suspends after drawer release")
        assert(ledger.contains(.detachedTail), "tail owner remains")
        expect(ledger.set(.detachedTail, suspended: false), .ended, "last owner ends")
        assert(!ledger.isSuspended, "ledger is released")
    }

    private static func giantMessageUsesLiveBottomRatherThanMessageTop() {
        // The old 4950 decision used the message's minY. For one giant message
        // that value can be -2,000 while its actual growing bottom is +3,000.
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(
                    userDetachedFromTail: true,
                    isScrolling: true,
                    liveTailMaxY: 3_000
                )
            ),
            .active,
            "giant message live bottom acquires"
        )
    }

    private static func approachingTailResumesBeforeItEntersViewport() {
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(
                    userDetachedFromTail: true,
                    liveTailMaxY: 1_200,
                    isCurrentlySuspended: true
                )
            ),
            .inactive,
            "catch-up band resumes"
        )
    }

    private static func activeScrollDefersCatchUpMutation() {
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(
                    userDetachedFromTail: true,
                    isScrolling: true,
                    liveTailMaxY: 1_200,
                    isCurrentlySuspended: true
                )
            ),
            .active,
            "finger motion defers catch-up"
        )
    }

    private static func lazyTailCanAcquireAfterUserDetaches() {
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(
                    userDetachedFromTail: true,
                    lazyTailIsBelowViewport: true
                )
            ),
            .active,
            "lazy below-tail acquires"
        )
    }

    private static func passiveUpperReadingDoesNotAcquireWithoutUserDetach() {
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(liveTailMaxY: 3_000)
            ),
            .inactive,
            "no detach stays live"
        )
    }

    private static func invalidViewportFailsOpen() {
        expect(
            OffscreenStreamingDisplayPolicy.desiredState(
                for: input(
                    viewportHeight: .nan,
                    userDetachedFromTail: true,
                    isCurrentlySuspended: true
                )
            ),
            .inactive,
            "invalid viewport resumes"
        )
    }
}
