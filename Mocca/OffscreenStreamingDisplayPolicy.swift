import Foundation

enum StreamingTextDisplaySuspensionOwner: Hashable {
    case nonStreamingReply
    case drawer
    case detachedTail
    case codeDisclosure(UUID)
}

enum StreamingTextDisplaySuspensionTransition: Equatable {
    case unchanged
    case began
    case ended
}

struct StreamingTextDisplaySuspensionLedger {
    private(set) var owners = Set<StreamingTextDisplaySuspensionOwner>()

    var isSuspended: Bool {
        !owners.isEmpty
    }

    func contains(_ owner: StreamingTextDisplaySuspensionOwner) -> Bool {
        owners.contains(owner)
    }

    mutating func set(
        _ owner: StreamingTextDisplaySuspensionOwner,
        suspended: Bool
    ) -> StreamingTextDisplaySuspensionTransition {
        let wasSuspended = isSuspended
        if suspended {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }

        switch (wasSuspended, isSuspended) {
        case (false, true):
            return .began
        case (true, false):
            return .ended
        default:
            return .unchanged
        }
    }
}

enum OffscreenStreamingDisplayDesiredState: Equatable {
    case inactive
    case active
}

struct OffscreenStreamingDisplayPolicyInput {
    let viewportHeight: CGFloat
    let userDetachedFromTail: Bool
    let isScrolling: Bool
    let isAtBottom: Bool
    let isNearBottom: Bool
    let liveTailMaxY: CGFloat?
    let lazyTailIsBelowViewport: Bool
    let isCurrentlySuspended: Bool
}

enum OffscreenStreamingDisplayPolicy {
    static let acquireClearance: CGFloat = 64
    static let catchUpViewportMultiplier: CGFloat = 1.6

    static func desiredState(
        for input: OffscreenStreamingDisplayPolicyInput
    ) -> OffscreenStreamingDisplayDesiredState {
        guard input.viewportHeight.isFinite,
              input.viewportHeight > 0 else {
            return .inactive
        }

        let concreteTailIsSafelyBelow = input.liveTailMaxY.map {
            $0.isFinite
                && $0 >= input.viewportHeight + acquireClearance
        } ?? false
        let tailIsSafelyBelow = concreteTailIsSafelyBelow
            || input.lazyTailIsBelowViewport

        if input.isCurrentlySuspended {
            // Never resume a potentially large catch-up mutation beneath an
            // active finger/deceleration. Re-evaluate when scrolling settles.
            if input.isScrolling {
                return .active
            }

            let liveTailEnteredCatchUpBand = input.liveTailMaxY.map {
                $0.isFinite
                    && $0 <= input.viewportHeight * catchUpViewportMultiplier
            } ?? false
            if input.isAtBottom
                || input.isNearBottom
                || liveTailEnteredCatchUpBand {
                return .inactive
            }

            if input.userDetachedFromTail, tailIsSafelyBelow {
                return .active
            }
            return .inactive
        }

        guard input.userDetachedFromTail,
              !input.isAtBottom,
              !input.isNearBottom,
              tailIsSafelyBelow else {
            return .inactive
        }
        return .active
    }
}
