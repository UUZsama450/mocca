import Foundation

@main
@MainActor
enum ComposerNativeTextInputHostTests {
    private static var assertions = 0

    static func main() {
        thresholds()
        returnIntent()
        transactions()
        print("COMPOSER_NATIVE_TEXT_INPUT_HOST_TESTS=PASS assertions=\(assertions)")
        print("SCOPE=production threshold, edit-intent and transaction validation on macOS; UIKit selection/Undo/focus/IME/layout require iPhone acceptance")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        assertions += 1
        guard value() else { fatalError("COMPOSER_NATIVE_TEXT_INPUT_HOST_TESTS=FAIL \(name)") }
    }

    private static func thresholds() {
        check(!ComposerPastePolicy.shouldOfferAttachment(for: ""), "empty paste is short")
        check(!ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "中", count: 4_999)), "4999 Chinese Characters stay text")
        check(ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "中", count: 5_000)), "5000 Chinese Characters offer attachment")
        check(ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "a", count: 5_001)), "5001 ASCII Characters offer attachment")
        let family = "👨‍👩‍👧‍👦"
        check(!ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: family, count: 4_999)), "emoji UTF16 length does not inflate threshold")
        check(ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: family, count: 5_000)), "5000 emoji Characters offer attachment")
        check(!ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "e\u{301}", count: 4_999)), "combining marks do not inflate threshold")
        check(ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "e\u{301}", count: 5_000)), "5000 combining Characters offer attachment")
        check(!ComposerPastePolicy.shouldOfferAttachment(for: "\n"), "single newline is short paste")
        check(ComposerPastePolicy.shouldOfferAttachment(for: String(repeating: "\n", count: 5_000)), "long newline paste offers attachment")
    }

    private static func returnIntent() {
        check(ComposerPastePolicy.shouldSubmitReturn(replacement: "\n", enterToSend: true, isPasting: false, isComposing: false), "keyboard return can submit")
        check(!ComposerPastePolicy.shouldSubmitReturn(replacement: "\n", enterToSend: true, isPasting: true, isComposing: false), "single pasted newline cannot submit")
        check(!ComposerPastePolicy.shouldSubmitReturn(replacement: "\n", enterToSend: true, isPasting: false, isComposing: true), "IME confirmation cannot submit")
        check(!ComposerPastePolicy.shouldSubmitReturn(replacement: "\n", enterToSend: false, isPasting: false, isComposing: false), "return preference disabled inserts newline")
        check(!ComposerPastePolicy.shouldSubmitReturn(replacement: "one\ntwo", enterToSend: true, isPasting: true, isComposing: false), "multiline paste cannot submit")
        check(!ComposerPastePolicy.shouldSubmitReturn(replacement: "确认", enterToSend: true, isPasting: false, isComposing: false), "normal Chinese input cannot submit")
    }

    private static func transactions() {
        let conversationA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let conversationB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let identity = ComposerInputIdentity(conversationID: conversationA, resetRevision: 4)
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let draft = "前🙂后"
        let snapshot = ComposerPasteSnapshot(
            token: token, identity: identity, revision: 12, originalText: draft,
            selection: NSRange(location: 1, length: 2), pastedText: String(repeating: "长", count: 5_000)
        )
        check(snapshot.matches(token: token, identity: identity, revision: 12, text: draft, selection: snapshot.selection), "untouched transaction with selected emoji is valid")
        check(snapshot.originalText == draft && snapshot.pastedText.count == 5_000, "snapshot separates old draft and new paste")
        check(!snapshot.matches(token: token, identity: identity, revision: 12, text: draft, selection: NSRange(location: 4, length: 0)), "cursor moved while choice is pending invalidates request")
        check(!snapshot.matches(token: token, identity: identity, revision: 12, text: draft, selection: NSRange(location: 1, length: 0)), "selection collapsed while choice is pending invalidates request")
        check(!snapshot.matches(token: nil, identity: identity, revision: 12, text: draft, selection: snapshot.selection), "cancelled or consumed token cannot apply")
        check(!snapshot.matches(token: UUID(), identity: identity, revision: 12, text: draft, selection: snapshot.selection), "new paste token invalidates previous callback")
        check(!snapshot.matches(token: token, identity: .init(conversationID: conversationB, resetRevision: 4), revision: 12, text: draft, selection: snapshot.selection), "conversation switch invalidates request")
        check(!snapshot.matches(token: token, identity: .init(conversationID: conversationA, resetRevision: 5), revision: 12, text: draft, selection: snapshot.selection), "successful send reset invalidates request")
        check(!snapshot.matches(token: token, identity: identity, revision: 13, text: draft, selection: snapshot.selection), "edit then undo to same text still invalidates old revision")
        check(!snapshot.matches(token: token, identity: identity, revision: 12, text: draft + "新", selection: snapshot.selection), "external draft change invalidates before UIKit revision catches up")
        let precomposed = "é"
        let decomposed = "e\u{301}"
        check(precomposed == decomposed, "Unicode fixture is canonically equal")
        check(!ComposerPastePolicy.identicalText(precomposed, decomposed), "different UTF16 storage is not a matching draft")
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: 5, length: 0), NSRange(location: 1, length: Int.max)] {
            let invalid = ComposerPasteSnapshot(token: token, identity: identity, revision: 12, originalText: draft, selection: range, pastedText: "x")
            check(!invalid.matches(token: token, identity: identity, revision: 12, text: draft, selection: range), "invalid/overflowing selection cannot be applied")
        }
        let end = ComposerPasteSnapshot(token: token, identity: identity, revision: 12, originalText: draft, selection: NSRange(location: draft.utf16.count, length: 0), pastedText: "x")
        check(end.matches(token: token, identity: identity, revision: 12, text: draft, selection: end.selection), "UTF16 end insertion is valid")
        let largeExistingDraft = ComposerPasteSnapshot(token: token, identity: identity, revision: 12, originalText: String(repeating: "旧", count: 20_000), selection: NSRange(location: 0, length: 0), pastedText: "short")
        check(!ComposerPastePolicy.shouldOfferAttachment(for: largeExistingDraft.pastedText), "large existing draft never changes the per-paste threshold")
    }
}
