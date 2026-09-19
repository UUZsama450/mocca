import Foundation
import SwiftUI

@MainActor
private enum MoccaCalendarDateText {
    private static let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    private static func components(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
    }

    static func monthTitle(_ date: Date) -> String {
        let value = components(date)
        return L10n.format("%@年%@月", [String(describing: value.year ?? 0), String(describing: value.month ?? 0)])
    }

    static func monthDay(_ date: Date) -> String {
        let value = components(date)
        return L10n.format("%@月%@日", [String(describing: value.month ?? 0), String(describing: value.day ?? 0)])
    }

    static func fullDate(_ date: Date) -> String {
        let value = components(date)
        return L10n.format("%@年%@月%@日", [String(describing: value.year ?? 0), String(describing: value.month ?? 0), String(describing: value.day ?? 0)])
    }

    static func weekday(_ date: Date) -> String {
        let index = max(1, min(components(date).weekday ?? 1, weekdayNames.count)) - 1
        return L10n.lookup(weekdayNames[index])
    }

    static func day(_ date: Date) -> String {
        String(components(date).day ?? 0)
    }

    static func time(_ date: Date) -> String {
        let value = components(date)
        return String(format: "%02d:%02d", value.hour ?? 0, value.minute ?? 0)
    }
}

struct MoccaCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: .now)
    ) ?? .now
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var editorRoute: MoccaCalendarEditorRoute?
    @State private var settingsPresented = false

    private var accent: Color { Color(uiColor: model.themeAccentUIColor) }
    private var controlTint: Color { Color(uiColor: model.themeSwitchUIColor) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if !countdownItems.isEmpty {
                        countdownSection
                    }

                    monthCard
                    selectedDaySection
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(L10n.lookup("日历"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel(L10n.lookup("返回"))
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        settingsPresented = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(L10n.lookup("日历设置"))

                    Button {
                        editorRoute = MoccaCalendarEditorRoute(event: nil, date: selectedDate)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.lookup("添加日历事项"))
                }
            }
            .tint(controlTint)
        }
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .sheet(item: $editorRoute) { route in
            MoccaCalendarEventEditorView(event: route.event, selectedDate: route.date)
                .environment(model)
        }
        .sheet(isPresented: $settingsPresented) {
            MoccaCalendarSettingsView()
                .environment(model)
        }
    }

    private var countdownItems: [MoccaCalendarOccurrence] {
        model.calendarEvents
            .filter { $0.kind != .todo || !$0.isCompleted }
            .filter(\.showsCountdown)
            .compactMap { MoccaCalendarEngine.nextOccurrence(of: $0) }
            .filter { MoccaCalendarEngine.daysUntil($0.date) >= 0 }
            .sorted {
                let lhsDays = MoccaCalendarEngine.daysUntil($0.date)
                let rhsDays = MoccaCalendarEngine.daysUntil($1.date)
                if lhsDays == rhsDays {
                    return $0.event.importance.rank > $1.event.importance.rank
                }
                return lhsDays < rhsDays
            }
            .prefix(4)
            .map { $0 }
    }

    private var countdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.lookup("倒计时"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Text(L10n.lookup("最近"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(countdownItems) { occurrence in
                        let days = MoccaCalendarEngine.daysUntil(occurrence.date)
                        Button {
                            selectedDate = Calendar.current.startOfDay(for: occurrence.date)
                            displayedMonth = monthStart(for: occurrence.date)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 7) {
                                    Image(systemName: occurrence.event.kind.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(occurrence.event.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                }
                                Text(days == 0 ? L10n.lookup("就是今天") : L10n.format("还有 %@ 天", [String(describing: days)]))
                                    .font(.system(size: 23, weight: .bold, design: .rounded))
                                Text(MoccaCalendarDateText.monthDay(occurrence.date))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(15)
                            .frame(width: 174, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(accent.opacity(0.10))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(accent.opacity(0.20), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var monthCard: some View {
        VStack(spacing: 14) {
            HStack {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let today = Calendar.current.startOfDay(for: .now)
                    selectedDate = today
                    displayedMonth = monthStart(for: today)
                } label: {
                    Text(MoccaCalendarDateText.monthTitle(displayedMonth))
                        .font(.system(size: 20, weight: .bold))
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach([L10n.lookup("一"), L10n.lookup("二"), L10n.lookup("三"), L10n.lookup("四"), L10n.lookup("五"), L10n.lookup("六"), L10n.lookup("日")], id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                spacing: 7
            ) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let occurrences = MoccaCalendarEngine.occurrences(of: model.calendarEvents, on: day)
                        MoccaCalendarDayCell(
                            date: day,
                            occurrences: occurrences,
                            selected: Calendar.current.isDate(day, inSameDayAs: selectedDate),
                            today: Calendar.current.isDateInToday(day),
                            accent: accent
                        ) {
                            withAnimation(.snappy(duration: 0.22)) {
                                selectedDate = day
                            }
                        }
                    } else {
                        Color.clear.frame(height: 50)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(MoccaCalendarDateText.monthDay(selectedDate))
                        .font(.system(size: 21, weight: .bold))
                    Text(MoccaCalendarDateText.weekday(selectedDate))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editorRoute = MoccaCalendarEditorRoute(event: nil, date: selectedDate)
                } label: {
                    Label(L10n.lookup("添加"), systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if selectedDayOccurrences.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(accent.opacity(0.75))
                    Text(L10n.lookup("这一天还是空白的"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L10n.lookup("可以放下一件事、一句话或一个重要日子"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                VStack(spacing: 9) {
                    ForEach(selectedDayOccurrences) { occurrence in
                        Button {
                            editorRoute = MoccaCalendarEditorRoute(
                                event: occurrence.event,
                                date: occurrence.date
                            )
                        } label: {
                            MoccaCalendarEventRow(occurrence: occurrence, accent: accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedDayOccurrences: [MoccaCalendarOccurrence] {
        MoccaCalendarEngine.occurrences(of: model.calendarEvents, on: selectedDate)
    }

    private var monthDays: [Date?] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var days = Array<Date?>(repeating: nil, count: leading)
        days.append(contentsOf: range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: first)
        }.map(Optional.some))
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private func moveMonth(by delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        withAnimation(.snappy(duration: 0.24)) {
            displayedMonth = monthStart(for: next)
            selectedDate = displayedMonth
        }
    }

    private func monthStart(for date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date)) ?? date
    }
}

private struct MoccaCalendarEditorRoute: Identifiable {
    let id = UUID()
    let event: MoccaCalendarEvent?
    let date: Date
}

private struct MoccaCalendarDayCell: View {
    let date: Date
    let occurrences: [MoccaCalendarOccurrence]
    let selected: Bool
    let today: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(MoccaCalendarDateText.day(date))
                    .font(.system(size: 15, weight: selected || today ? .bold : .medium, design: .rounded))
                HStack(spacing: 2) {
                    ForEach(Array(occurrences.prefix(3).enumerated()), id: \.offset) { _, occurrence in
                        Circle()
                            .fill(dotColor(for: occurrence.event.importance))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? accent.opacity(0.14) : Color.primary.opacity(occurrences.isEmpty ? 0.018 : 0.045))
            )
            .overlay {
                if today || selected {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(accent.opacity(selected ? 0.70 : 0.38), lineWidth: selected ? 1.5 : 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MoccaCalendarDateText.fullDate(date))
        .accessibilityValue(occurrences.isEmpty ? L10n.lookup("无事项") : L10n.format("%@ 个事项", [String(describing: occurrences.count)]))
    }

    private func dotColor(for importance: MoccaCalendarImportance) -> Color {
        switch importance {
        case .normal: accent.opacity(0.55)
        case .important: accent.opacity(0.82)
        case .critical: accent
        }
    }
}

private struct MoccaCalendarEventRow: View {
    let occurrence: MoccaCalendarOccurrence
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(accent.opacity(0.11))
                Image(systemName: occurrence.event.kind == .todo && occurrence.event.isCompleted
                      ? "checkmark.circle.fill"
                      : occurrence.event.kind.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(occurrence.event.title)
                        .font(.system(size: 16, weight: .semibold))
                        .strikethrough(occurrence.event.kind == .todo && occurrence.event.isCompleted)
                        .lineLimit(1)
                    if occurrence.event.importance != .normal {
                        Circle()
                            .fill(accent.opacity(occurrence.event.importance == .critical ? 1 : 0.65))
                            .frame(width: 6, height: 6)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(13)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 1)
        }
    }

    @MainActor private var subtitle: String {
        var parts: [String] = []
        if !occurrence.event.isAllDay {
            parts.append(MoccaCalendarDateText.time(occurrence.date))
        }
        parts.append(occurrence.event.kind.title)
        if occurrence.event.recurrence != .none {
            parts.append(occurrence.event.recurrence.title)
        }
        if occurrence.event.isBuiltIn {
            parts.append(L10n.lookup("默认"))
        }
        return parts.joined(separator: " · ")
    }
}

struct MoccaCalendarEventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var event: MoccaCalendarEvent
    @State private var deleteConfirmationPresented = false

    private let isNew: Bool

    init(event: MoccaCalendarEvent?, selectedDate: Date) {
        isNew = event == nil
        let calendar = Calendar.current
        let baseDate = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: selectedDate
        ) ?? selectedDate
        _event = State(initialValue: event ?? MoccaCalendarEvent(title: "", startAt: baseDate))
    }

    private var controlTint: Color { Color(uiColor: model.themeSwitchUIColor) }
    private var surface: Color { Color(uiColor: model.themeSurfaceUIColor) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    editorCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.lookup("写下这一天"))
                                .font(.system(size: 18, weight: .bold))
                            TextField(L10n.lookup("标题"), text: $event.title)
                                .font(.system(size: 18, weight: .semibold))
                                .padding(13)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            TextField(L10n.lookup("想补充的话（可选）"), text: $event.notes, axis: .vertical)
                                .lineLimit(2...5)
                                .padding(13)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    editorCard {
                        VStack(spacing: 0) {
                            pickerRow(L10n.lookup("类型"), selection: $event.kind) {
                                ForEach(MoccaCalendarEventKind.allCases) { kind in
                                    Label(L10n.lookup(kind.title), systemImage: kind.systemImage).tag(kind)
                                }
                            }
                            if event.kind == .todo {
                                Divider().padding(.leading, 16)
                                Toggle(isOn: $event.isCompleted) {
                                    Label(L10n.lookup("已经完成"), systemImage: "checkmark.circle")
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 54)
                            }
                            Divider().padding(.leading, 16)
                            Toggle(isOn: $event.isAllDay) {
                                Label(L10n.lookup("全天"), systemImage: "sun.max")
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                            Divider().padding(.leading, 16)
                            if event.isAllDay {
                                DatePicker(
                                    L10n.lookup("日期"),
                                    selection: $event.startAt,
                                    displayedComponents: .date
                                )
                                .padding(.horizontal, 16)
                                .frame(minHeight: 54)
                            } else {
                                DatePicker(
                                    L10n.lookup("日期与时间"),
                                    selection: $event.startAt,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .padding(.horizontal, 16)
                                .frame(minHeight: 54)
                            }
                            Divider().padding(.leading, 16)
                            pickerRow(L10n.lookup("重复"), selection: $event.recurrence) {
                                ForEach(MoccaCalendarRecurrence.allCases) { recurrence in
                                    Text(L10n.lookup(recurrence.title)).tag(recurrence)
                                }
                            }
                        }
                    }

                    editorCard {
                        VStack(spacing: 0) {
                            pickerRow(L10n.lookup("重要性"), selection: $event.importance) {
                                ForEach(MoccaCalendarImportance.allCases) { importance in
                                    Text(L10n.lookup(importance.title)).tag(importance)
                                }
                            }
                            Divider().padding(.leading, 16)
                            Toggle(isOn: $event.showsCountdown) {
                                Label(L10n.lookup("显示倒计时"), systemImage: "hourglass")
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                        }
                    }

                    editorCard {
                        VStack(spacing: 0) {
                            reminderPicker(
                                title: L10n.lookup("提醒我"),
                                systemImage: "bell",
                                selection: $event.notificationLeadDays
                            )
                            Divider().padding(.leading, 16)
                            reminderPicker(
                                title: L10n.lookup("让助手知道"),
                                systemImage: "brain.head.profile",
                                selection: $event.assistantLeadDays
                            )
                        }
                    }

                    if !isNew {
                        Button(role: .destructive) {
                            deleteConfirmationPresented = true
                        } label: {
                            Label(L10n.lookup("删除这个日子"), systemImage: "trash")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
            .background(surface.ignoresSafeArea())
            .navigationTitle(isNew ? L10n.lookup("添加日子") : L10n.lookup("编辑日子"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) { save() }
                        .foregroundStyle(controlTint)
                        .fontWeight(.semibold)
                        .disabled(event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .tint(controlTint)
        }
        .onChange(of: event.kind) { oldValue, newValue in
            guard oldValue != newValue, event.recurrence == .none else { return }
            if newValue == .birthday || newValue == .anniversary || newValue == .festival {
                event.recurrence = .yearly
            }
            if newValue == .birthday || newValue == .anniversary {
                event.showsCountdown = true
            }
        }
        .alert(L10n.lookup("删除这个日子？"), isPresented: $deleteConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("删除"), role: .destructive) {
                model.deleteCalendarEvent(event.id)
                dismiss()
            }
        } message: {
            Text(L10n.format("助手以后也不会再看到“%@”了。", [String(describing: event.title)]))
        }
    }

    @ViewBuilder
    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    private func pickerRow<Value: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    private func reminderPicker(
        title: String,
        systemImage: String,
        selection: Binding<Int?>
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Picker(title, selection: selection) {
                Text(L10n.lookup("关闭")).tag(Int?.none)
                Text(L10n.lookup("当天")).tag(Int?.some(0))
                Text(L10n.lookup("提前 1 天")).tag(Int?.some(1))
                Text(L10n.lookup("提前 2 天")).tag(Int?.some(2))
                Text(L10n.lookup("提前 7 天")).tag(Int?.some(7))
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
    }

    private func save() {
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = event.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.lastEditedBy = .user
        if isNew {
            event.author = .user
            event.createdAt = .now
        }
        event.updatedAt = .now
        model.upsertCalendarEvent(event)
        if event.notificationLeadDays != nil {
            let events = model.calendarEvents
            Task {
                _ = await MoccaCalendarNotificationScheduler.requestAuthorization()
                await MoccaCalendarNotificationScheduler.reschedule(events: events)
            }
        }
        dismiss()
    }
}

struct MoccaCalendarSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var restoreConfirmationPresented = false

    private var accent: Color { Color(uiColor: model.themeAccentUIColor) }
    private var controlTint: Color { Color(uiColor: model.themeSwitchUIColor) }
    private var action: Color { controlTint }
    private var surface: Color { Color(uiColor: model.themeSurfaceUIColor) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: assistantAccessBinding) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.lookup("允许助手使用日历"))
                                    .font(.system(size: 17, weight: .semibold))
                                Text(L10n.lookup("默认关闭"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        Text(model.calendarSettings.assistantAccessEnabled
                             ? L10n.lookup("已向助手提供日历提示词、增删改查工具与临近日子上下文。工具操作会显示在聊天中。")
                             : L10n.lookup("关闭时不会发送任何日历提示词、工具定义或日历内容，也不会增加上下文消耗。你仍然可以手动使用日历。"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(17)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(accent.opacity(model.calendarSettings.assistantAccessEnabled ? 0.24 : 0.07), lineWidth: 1)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(L10n.lookup("默认节日"), systemImage: "sparkles")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text(L10n.format("%@ 个", [String(describing: builtInFestivalCount)]))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(L10n.lookup("可以在日历里逐个编辑或删除。恢复只会补回缺少的默认节日，不会覆盖你的修改。"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button {
                            restoreConfirmationPresented = true
                        } label: {
                            Text(L10n.lookup("恢复缺少的默认节日"))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .foregroundStyle(action)
                                .background(action.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(17)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
            .background(surface.ignoresSafeArea())
            .navigationTitle(L10n.lookup("日历设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(controlTint)
                }
            }
            .tint(controlTint)
        }
        .alert(L10n.lookup("恢复默认节日？"), isPresented: $restoreConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("恢复")) { model.restoreDefaultCalendarFestivals() }
        } message: {
            Text(L10n.lookup("只补回被删除的默认节日，你编辑过的内容会保留。"))
        }
    }

    private var assistantAccessBinding: Binding<Bool> {
        Binding(
            get: { model.calendarSettings.assistantAccessEnabled },
            set: { enabled in
                model.updateCalendarSettings { $0.assistantAccessEnabled = enabled }
                model.performSwitchHaptic()
            }
        )
    }

    private var builtInFestivalCount: Int {
        model.calendarEvents.filter(\.isBuiltIn).count
    }
}
