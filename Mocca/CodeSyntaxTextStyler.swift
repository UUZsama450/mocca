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
    private var task: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var appliedRuns: [CodeSyntaxColorRun] = []
    private var baseColor: UIColor = .label

    func matches(language: String, theme: CodeSyntaxTheme) -> Bool {
        latest?.language == CodeSyntaxHighlighter.normalizedLanguage(language)
            && latest?.theme == theme
    }

    /// The caller replaced the text storage or its layout attributes.
    func resetColors() {
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
            applyColors([], to: textView)
        }
        latest = request
        generation &+= 1
        startIfNeeded(textView)
    }

    private func startIfNeeded(_ textView: UITextView) {
        guard task == nil, let request = latest else { return }
        let requestGeneration = generation
        let taskID = UUID()
        activeTaskID = taskID
        task = Task { @MainActor [weak self, weak textView] in
            let runs = await CodeSyntaxHighlighter.shared.highlight(
                text: request.text, language: request.language,
                theme: request.theme, isStreaming: request.isStreaming
            )
            guard let self, let textView, self.activeTaskID == taskID else { return }
            self.task = nil
            self.activeTaskID = nil
            guard !Task.isCancelled else { return }
            if self.generation == requestGeneration,
               (textView.textStorage.string as NSString).isEqual(to: request.text) {
                self.applyColors(runs, to: textView)
            }
            if self.generation != requestGeneration {
                self.startIfNeeded(textView)
            }
        }
    }

    private func applyColors(_ runs: [CodeSyntaxColorRun], to textView: UITextView) {
        let storage = textView.textStorage
        guard runs.allSatisfy({
            $0.range.location >= 0 && $0.range.length > 0
                && $0.range.location <= storage.length
                && $0.range.length <= storage.length - $0.range.location
        }) else { return }

        // Streaming usually changes only the last few runs. Keep the identical
        // prefix instead of restyling thousands of unchanged tokens each batch.
        var shared = 0
        while shared < min(runs.count, appliedRuns.count), runs[shared] == appliedRuns[shared] {
            shared += 1
        }
        let oldStart = shared < appliedRuns.count ? appliedRuns[shared].range.location : storage.length
        let newStart = shared < runs.count ? runs[shared].range.location : storage.length
        let start = min(oldStart, newStart, storage.length)
        guard start < storage.length else {
            appliedRuns = runs
            return
        }
        storage.beginEditing()
        storage.addAttribute(
            .foregroundColor, value: baseColor,
            range: NSRange(location: start, length: storage.length - start)
        )
        for run in runs.dropFirst(shared) {
            let color = UIColor(
                red: CGFloat((run.rgb >> 16) & 255) / 255,
                green: CGFloat((run.rgb >> 8) & 255) / 255,
                blue: CGFloat(run.rgb & 255) / 255, alpha: 1
            )
            storage.addAttribute(.foregroundColor, value: color, range: run.range)
        }
        storage.endEditing()
        appliedRuns = runs
        didApplyColors?()
    }
}
