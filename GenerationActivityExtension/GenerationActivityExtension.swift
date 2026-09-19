import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct GenerationActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        MoccaGenerationActivityWidget()
    }
}

struct MoccaGenerationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MoccaGenerationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: context.state.isFinished ? "checkmark" : "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.assistantName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(context.state.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                elapsedView(context)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color(uiColor: .systemBackground))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.assistantName, systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedView(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.isFinished ? "checkmark" : "sparkles")
            } compactTrailing: {
                elapsedView(context)
            } minimal: {
                Image(systemName: context.state.isFinished ? "checkmark" : "sparkles")
            }
        }
    }

    @ViewBuilder
    private func elapsedView(
        _ context: ActivityViewContext<MoccaGenerationActivityAttributes>
    ) -> some View {
        if context.state.isFinished {
            Text("完成")
                .environment(\.locale, Locale(identifier: context.state.languageCode ?? Locale.current.identifier))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            Text(
                timerInterval: context.state.startedAt...Date.distantFuture,
                countsDown: false,
                showsHours: true
            )
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 42)
        }
    }
}
