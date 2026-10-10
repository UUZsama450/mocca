import UIKit

/// One in-flight analysis per text host, with only the newest pending snapshot.
/// Coloring never participates in code size, disclosure or scroll completion.
@MainActor
final class CodeSyntaxTextStyler {
    var didApplyColors: (() -> Void)?

    private struct Request: Equatable {
        let text: String
        let language: String
        let theme: CodeSyntaxTheme
        let isStreaming: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.language == rhs.language && lhs.theme == rhs.theme
                && lhs.isStreaming == rhs.isStreaming
                && (lhs.text as NSString).isEqual(to: rhs.text)
        }
    }

    private var latest: Request?
    private var generation: UInt64 = 0
    private var storageGeneration: UInt64 = 0
    private var task: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var appliedRuns: [CodeSyntaxColorRun] = []
    private var baseColor: UIColor = .label
    private var colors: [UInt32: UIColor] = [:]

    func matches(language: String, theme: CodeSyntaxTheme) -> Bool {
        latest?.language == CodeSyntaxHighlighter.normalizedLanguage(language)
            && latest?.theme == theme
    }

    /// The caller replaced the text storage or its layout attributes.
    func resetColors() {
        storageGeneration &+= 1
        latest = nil
        appliedRuns = []
    }

    func cancel() {
        generation &+= 1
        latest = nil
        activeTaskID = nil
        task?.cancel()
        task = nil
    }

    func update(
        textView: UITextView, text: String, language: String,
        theme: CodeSyntaxTheme, isStreaming: Bool, baseColor: UIColor
    ) {
        self.baseColor = baseColor
        let request = Request(
            text: text, language: CodeSyntaxHighlighter.normalizedLanguage(language),
            theme: theme, isStreaming: isStreaming
        )
        guard request != latest else { return }
        if let previous = latest,
           previous.theme != theme || previous.language != request.language {
            clearColors(in: textView)
        }
        latest = request
        generation &+= 1
        startIfNeeded(textView)
    }

    private func startIfNeeded(_ textView: UITextView) {
        guard task == nil, let request = latest else { return }
        let requestGeneration = generation
        let requestStorageGeneration = storageGeneration
        let taskID = UUID()
        activeTaskID = taskID
        task = Task { @MainActor [weak self, weak textView] in
            let runs = await CodeSyntaxHighlighter.shared.highlight(
                text: request.text, language: request.language,
                theme: request.theme, isStreaming: request.isStreaming
            )
            guard let self, let textView, self.activeTaskID == taskID else { return }
            guard !Task.isCancelled else { return }
            await self.applyColors(runs, to: textView, request: request,
                                   storageGeneration: requestStorageGeneration, taskID: taskID)
            guard self.activeTaskID == taskID else { return }
            self.task = nil
            self.activeTaskID = nil
            if self.generation != requestGeneration {
                self.startIfNeeded(textView)
            }
        }
    }

    private func clearColors(in textView: UITextView) {
        guard !appliedRuns.isEmpty else { return }
        textView.textStorage.addAttribute(.foregroundColor, value: baseColor,
            range: NSRange(location: 0, length: textView.textStorage.length))
        appliedRuns = []
        didApplyColors?()
    }

    private func canApply(_ request: Request, to textView: UITextView,
                          storageGeneration: UInt64, taskID: UUID) -> Bool {
        guard !Task.isCancelled, activeTaskID == taskID,
              self.storageGeneration == storageGeneration,
              latest?.language == request.language, latest?.theme == request.theme else { return false }
        // A busy stream may always be ahead of the parser. Color the exact prefix
        // it analyzed while the newest snapshot waits; replacement/folding and
        // theme changes invalidate it. Never normalize Unicode for this check.
        return (textView.textStorage.string as NSString).range(
            of: request.text, options: [.anchored, .literal]
        ).location == 0
    }

    private func applyColors(_ runs: [CodeSyntaxColorRun], to textView: UITextView,
                             request: Request, storageGeneration: UInt64, taskID: UUID) async {
        let storage = textView.textStorage
        let length = request.text.utf16.count
        guard canApply(request, to: textView, storageGeneration: storageGeneration, taskID: taskID) else { return }
        var previousEnd = 0
        guard runs.allSatisfy({
            guard $0.range.location >= previousEnd && $0.range.length > 0
                && $0.range.location <= length
                && $0.range.length <= length - $0.range.location else { return false }
            previousEnd = NSMaxRange($0.range)
            return true
        }) else { return }

        // Streaming usually changes only the last few runs. Keep the identical
        // prefix instead of restyling thousands of unchanged tokens each batch.
        var shared = 0
        while shared < min(runs.count, appliedRuns.count), runs[shared] == appliedRuns[shared] {
            shared += 1
        }
        let oldStart = shared < appliedRuns.count ? appliedRuns[shared].range.location : length
        let newStart = shared < runs.count ? runs[shared].range.location : length
        var start = min(oldStart, newStart, length)
        guard start < length else {
            appliedRuns = runs
            return
        }
        appliedRuns = Array(runs.prefix(shared))
        // Bound each main-actor edit, retaining the old colors ahead of the batch.
        // Long blocks progressively gain colors without one huge UI-thread loop.
        repeat {
            guard canApply(request, to: textView, storageGeneration: storageGeneration, taskID: taskID) else { return }
            let endIndex = min(shared + 256, runs.count)
            let end = endIndex == runs.count ? length : NSMaxRange(runs[endIndex - 1].range)
            storage.beginEditing()
            storage.addAttribute(
                .foregroundColor, value: baseColor,
                range: NSRange(location: start, length: end - start)
            )
            for run in runs[shared..<endIndex] {
                let color: UIColor
                if let cached = colors[run.rgb] {
                    color = cached
                } else {
                    color = UIColor(
                        red: CGFloat((run.rgb >> 16) & 255) / 255,
                        green: CGFloat((run.rgb >> 8) & 255) / 255,
                        blue: CGFloat(run.rgb & 255) / 255, alpha: 1
                    )
                    colors[run.rgb] = color
                }
                storage.addAttribute(.foregroundColor, value: color, range: run.range)
            }
            storage.endEditing()
            appliedRuns.append(contentsOf: runs[shared..<endIndex])
            shared = endIndex
            start = end
            if shared < runs.count { await Task.yield() }
        } while shared < runs.count
        didApplyColors?()
    }
}
