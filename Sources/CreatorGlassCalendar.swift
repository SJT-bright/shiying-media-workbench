import SwiftUI
import AppKit

// 玻璃日期面板。材质只用现有 ShiyingGlassSurface / QQTheme，不用系统 DatePicker。
// 日期计算走 CreatorCalendarDate.calendar（公历、Asia/Shanghai、en_US_POSIX）。
// 只有激活当月日格才写 selection 并调用 onSelect；翻年月和外部关闭都不提交。

enum CreatorGlassCalendarMetrics {
    static let panelWidth: CGFloat = 308
    static let panelPadding: CGFloat = 12
    static let sectionGap: CGFloat = 8
    static let cellHeight: CGFloat = 36
    static let gridGap: CGFloat = 4
    static let headerHeight: CGFloat = 32
    static let headerGap: CGFloat = 6
    static let chevronSide: CGFloat = 32
    static let monthButtonWidth: CGFloat = 72
    static let weekdayRowHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10
    static let dayRadius: CGFloat = 8
    static let minimumHit: CGFloat = 32
    static let gridRowCount = 6
    static let gridColumnCount = 7

    static var contentWidth: CGFloat { panelWidth - panelPadding * 2 }

    static var dayColumnWidth: CGFloat {
        (contentWidth - gridGap * CGFloat(gridColumnCount - 1)) / CGFloat(gridColumnCount)
    }

    static var yearButtonWidth: CGFloat {
        contentWidth - chevronSide * 2 - monthButtonWidth - headerGap * 3
    }

    static var gridHeight: CGFloat {
        cellHeight * CGFloat(gridRowCount) + gridGap * CGFloat(gridRowCount - 1)
    }

    static var panelHeight: CGFloat {
        panelPadding * 2 + headerHeight + sectionGap + weekdayRowHeight + sectionGap + gridHeight
    }
}

enum CreatorGlassCalendarModel {
    /// Calendar 的 weekday：周日是 1。中文面板从周一开始，不跟 en_US_POSIX 的周日首列走。
    static let weekStart = 2
    static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]
    static let weekdayNames = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
    static let yearPageSize = 12
    static let minimumYear = 1970
    static let maximumYear = 9999
    static let slotCount = CreatorGlassCalendarMetrics.gridRowCount * CreatorGlassCalendarMetrics.gridColumnCount

    struct DaySlot: Equatable {
        var day: Int?
        var date: Date?

        static let empty = DaySlot(day: nil, date: nil)
        var isSelectable: Bool { day != nil && date != nil }
    }

    static func day(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (minimumYear...maximumYear).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 0
        parts.minute = 0
        parts.second = 0
        guard let date = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    static func startOfDay(_ date: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return self.day(year: year, month: month, day: day, calendar: calendar)
    }

    static func monthStart(containing date: Date, calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return day(year: year, month: month, day: 1, calendar: calendar)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    /// 当月日格才能提交。其它月份、溢出日、空位都不是有效选择。
    static func canCommit(_ date: Date, visibleMonthStart: Date, calendar: Calendar) -> Bool {
        guard let dayStart = startOfDay(date, calendar: calendar),
              let month = monthStart(containing: dayStart, calendar: calendar),
              let visible = monthStart(containing: visibleMonthStart, calendar: calendar) else { return false }
        return isSameDay(month, visible, calendar: calendar)
    }

    static func slots(in monthAnchor: Date, calendar: Calendar) -> [DaySlot] {
        guard let first = monthStart(containing: monthAnchor, calendar: calendar) else {
            return Array(repeating: .empty, count: slotCount)
        }
        let parts = calendar.dateComponents([.year, .month], from: first)
        guard let year = parts.year,
              let month = parts.month,
              let range = calendar.range(of: .day, in: .month, for: first) else {
            return Array(repeating: .empty, count: slotCount)
        }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - weekStart + 7) % 7
        var slots = Array(repeating: DaySlot.empty, count: leading)
        for number in range {
            guard let date = day(year: year, month: month, day: number, calendar: calendar) else { continue }
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            // 空位保持 nil。这里不补上月或下月的日期，避免把相邻月点成有效选择。
            guard back.year == year, back.month == month, back.day == number else { continue }
            slots.append(DaySlot(day: number, date: date))
        }
        if slots.count < slotCount {
            slots.append(contentsOf: Array(repeating: .empty, count: slotCount - slots.count))
        }
        return slots
    }

    static func addingMonths(_ delta: Int, to monthAnchor: Date, calendar: Calendar) -> Date? {
        guard let base = monthStart(containing: monthAnchor, calendar: calendar) else { return nil }
        if delta == 0 { return base }
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: base),
              let start = monthStart(containing: shifted, calendar: calendar) else { return nil }
        guard yearStepAllowed(from: base, to: start, calendar: calendar) else { return nil }
        return start
    }

    static func addingYears(_ delta: Int, to monthAnchor: Date, calendar: Calendar) -> Date? {
        guard let base = monthStart(containing: monthAnchor, calendar: calendar) else { return nil }
        if delta == 0 { return base }
        guard let shifted = calendar.date(byAdding: .year, value: delta, to: base),
              let start = monthStart(containing: shifted, calendar: calendar) else { return nil }
        guard yearStepAllowed(from: base, to: start, calendar: calendar) else { return nil }
        return start
    }

    static func addingDays(_ delta: Int, to date: Date, calendar: Calendar) -> Date? {
        guard let shifted = calendar.date(byAdding: .day, value: delta, to: date) else { return nil }
        return startOfDay(shifted, calendar: calendar)
    }

    static func yearPageStart(for year: Int) -> Int {
        let size = yearPageSize
        let offset = year - minimumYear
        let page = floorDiv(offset, size)
        return minimumYear + page * size
    }

    static func yearSlots(pageStart: Int) -> [Int?] {
        (0..<yearPageSize).map { offset in
            let year = pageStart + offset
            return (minimumYear...maximumYear).contains(year) ? year : nil
        }
    }

    static func pageStart(after pageStart: Int, step: Int) -> Int? {
        guard step != 0 else { return pageStart }
        let next = pageStart + step * yearPageSize
        guard yearSlots(pageStart: next).contains(where: { $0 != nil }) else { return nil }
        return next
    }

    static func clampDayFocus(_ date: Date, toMonth monthAnchor: Date, calendar: Calendar) -> Date? {
        let slots = slots(in: monthAnchor, calendar: calendar).compactMap(\.date)
        guard !slots.isEmpty else { return nil }
        if let matched = slots.first(where: { isSameDay($0, date, calendar: calendar) }) {
            return matched
        }
        let wanted = calendar.component(.day, from: date)
        if let exact = slots.first(where: { calendar.component(.day, from: $0) == wanted }) {
            return exact
        }
        return slots.last
    }

    private static func yearStepAllowed(from: Date, to: Date, calendar: Calendar) -> Bool {
        let current = calendar.component(.year, from: from)
        let next = calendar.component(.year, from: to)
        if next > maximumYear && next >= current { return false }
        if next < minimumYear && next <= current { return false }
        return true
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        if remainder != 0 && value < 0 { return quotient - 1 }
        return quotient
    }
}

private enum CreatorGlassCalendarMode: Equatable {
    case days
    case months
    case years
}

private enum CreatorGlassCalendarMotion {
    // 与约定的 QQMotion.hoverResponse / hoverDamping / pressResponse / pressDamping 相同。
    // 不直接引用这四个新符号，日历可以在 Motion 候选合并前单独编译。
    static let hoverResponse = 0.30
    static let hoverDamping = 0.88
    static let pressResponse = 0.18
    static let pressDamping = 0.90
}

/// 年月日玻璃面板。`CreatorDateFilterControl` 用 popover 装入本视图。
/// `marksSelection == false` 时仍用 selection 决定打开的月份，但不把它画成已选日期。
/// 空值或非法原字符串应传 false，避免面板把锚点日期伪装成已提交的今天。
struct CreatorGlassCalendar: View {
    @Binding private var selection: Date
    private let marksSelection: Bool
    private let onSelect: (Date) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var visibleMonth: Date
    @State private var mode: CreatorGlassCalendarMode = .days
    @State private var yearPageStart: Int
    @FocusState private var focusedDay: Date?

    init(selection: Binding<Date>, marksSelection: Bool = true, onSelect: @escaping (Date) -> Void) {
        _selection = selection
        self.marksSelection = marksSelection
        self.onSelect = onSelect
        let calendar = CreatorCalendarDate.calendar
        let anchor = CreatorGlassCalendarModel.monthStart(containing: selection.wrappedValue, calendar: calendar)
            ?? selection.wrappedValue
        _visibleMonth = State(initialValue: anchor)
        let year = calendar.component(.year, from: anchor)
        _yearPageStart = State(initialValue: CreatorGlassCalendarModel.yearPageStart(for: year))
    }

    private var calendar: Calendar { CreatorCalendarDate.calendar }

    var body: some View {
        VStack(spacing: CreatorGlassCalendarMetrics.sectionGap) {
            header
            caption.frame(height: CreatorGlassCalendarMetrics.weekdayRowHeight)
            grid.frame(height: CreatorGlassCalendarMetrics.gridHeight)
        }
        .padding(CreatorGlassCalendarMetrics.panelPadding)
        .frame(width: CreatorGlassCalendarMetrics.panelWidth, height: CreatorGlassCalendarMetrics.panelHeight)
        .background { ShiyingGlassSurface(radius: CreatorGlassCalendarMetrics.cornerRadius, tint: QQTheme.cyan.opacity(0.045), control: true) }
        .clipShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("日期面板")
        .accessibilityIdentifier("CreatorGlassCalendar")
        .onAppear { alignFocus(preferSelection: true) }
        .onChange(of: selection) { _, newValue in
            guard let start = CreatorGlassCalendarModel.monthStart(containing: newValue, calendar: calendar) else { return }
            visibleMonth = start
        }
        .onChange(of: visibleMonth) { _, _ in
            alignFocus(preferSelection: false)
        }
    }

    private var header: some View {
        HStack(spacing: CreatorGlassCalendarMetrics.headerGap) {
            stepButton(forward: false)
            yearButton
            monthButton
            stepButton(forward: true)
        }
        .frame(height: CreatorGlassCalendarMetrics.headerHeight)
    }

    private var caption: some View {
        Group {
            switch mode {
            case .days:
                HStack(spacing: CreatorGlassCalendarMetrics.gridGap) {
                    ForEach(Array(CreatorGlassCalendarModel.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(CreatorGlassCalendarModel.weekdayNames[index])
                    }
                }
            case .months:
                Text("选择月份")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .years:
                Text(yearPageTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("年份范围 \(yearPageTitle)")
            }
        }
    }

    @ViewBuilder private var grid: some View {
        switch mode {
        case .days:
            dayGrid
        case .months:
            monthGrid
        case .years:
            yearGrid
        }
    }

    private var dayGrid: some View {
        let slots = CreatorGlassCalendarModel.slots(in: visibleMonth, calendar: calendar)
        return VStack(spacing: CreatorGlassCalendarMetrics.gridGap) {
            ForEach(0..<CreatorGlassCalendarMetrics.gridRowCount, id: \.self) { row in
                HStack(spacing: CreatorGlassCalendarMetrics.gridGap) {
                    ForEach(0..<CreatorGlassCalendarMetrics.gridColumnCount, id: \.self) { column in
                        dayCell(slots[row * CreatorGlassCalendarMetrics.gridColumnCount + column])
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var monthGrid: some View {
        VStack(spacing: CreatorGlassCalendarMetrics.gridGap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: CreatorGlassCalendarMetrics.headerGap) {
                    ForEach(0..<4, id: \.self) { column in
                        let month = row * 4 + column + 1
                        pickButton(
                            title: "\(month)月",
                            prominent: month == visibleParts.month,
                            today: month == todayParts.month && visibleParts.year == todayParts.year,
                            identifier: "CreatorGlassCalendar.month.\(month)",
                            label: "\(String(visibleParts.year ?? 2026))年\(month)月",
                            hint: "显示该月日期，不提交"
                        ) {
                            pickMonth(month)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var yearGrid: some View {
        let years = CreatorGlassCalendarModel.yearSlots(pageStart: yearPageStart)
        return VStack(spacing: CreatorGlassCalendarMetrics.gridGap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: CreatorGlassCalendarMetrics.headerGap) {
                    ForEach(0..<4, id: \.self) { column in
                        yearCell(years[row * 4 + column])
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func dayCell(_ slot: CreatorGlassCalendarModel.DaySlot) -> some View {
        if let day = slot.day, let date = slot.date {
            let selected = marksSelection && CreatorGlassCalendarModel.isSameDay(date, selection, calendar: calendar)
            let today = CreatorGlassCalendarModel.isSameDay(date, Date(), calendar: calendar)
            let spoken = spokenDay(date)
            Button {
                choose(date)
            } label: {
                Text("\(day)")
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .buttonStyle(CreatorGlassHitButtonStyle(
                tint: QQTheme.cyan,
                radius: CreatorGlassCalendarMetrics.dayRadius,
                prominent: selected,
                today: today,
                alwaysGlass: true
            ))
            .frame(maxWidth: .infinity)
            .frame(height: CreatorGlassCalendarMetrics.cellHeight)
            .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.dayRadius, style: .continuous))
            .focused($focusedDay, equals: CreatorGlassCalendarModel.startOfDay(date, calendar: calendar) ?? date)
            .accessibilityLabel(spoken)
            .accessibilityValue(dayValue(selected: selected, today: today, date: date))
            .accessibilityHint("选定这一天")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(CreatorCalendarDate.parse(CreatorCalendarDate.format(date)) == nil)
            .accessibilityIdentifier("CreatorGlassCalendar.day.\(CreatorCalendarDate.format(date))")
            .onKeyPress(.leftArrow) { moveDays(-1); return .handled }
            .onKeyPress(.rightArrow) { moveDays(1); return .handled }
            .onKeyPress(.upArrow) { moveDays(-7); return .handled }
            .onKeyPress(.downArrow) { moveDays(7); return .handled }
        } else {
            // 其它月的位置不是日期，不能点，也不能显示成另一天。
            RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.dayRadius, style: .continuous)
                .fill(Color.primary.opacity(0.001))
                .frame(maxWidth: .infinity)
                .frame(height: CreatorGlassCalendarMetrics.cellHeight)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func yearCell(_ year: Int?) -> some View {
        if let year {
            pickButton(
                title: "\(year)",
                prominent: year == visibleParts.year,
                today: year == todayParts.year,
                identifier: "CreatorGlassCalendar.year.\(year)",
                label: "\(year)年",
                hint: "显示该年日期，不提交"
            ) {
                pickYear(year)
            }
        } else {
            RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.dayRadius, style: .continuous)
                .fill(Color.primary.opacity(0.001))
                .frame(maxWidth: .infinity)
                .frame(height: CreatorGlassCalendarMetrics.cellHeight)
                .accessibilityHidden(true)
        }
    }

    private func pickButton(
        title: String,
        prominent: Bool,
        today: Bool,
        identifier: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(CreatorGlassHitButtonStyle(
            tint: QQTheme.cyan,
            radius: CreatorGlassCalendarMetrics.dayRadius,
            prominent: prominent,
            today: today,
            alwaysGlass: true
        ))
        .frame(maxWidth: .infinity)
        .frame(height: CreatorGlassCalendarMetrics.cellHeight)
        .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.dayRadius, style: .continuous))
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    private var yearButton: some View {
        Button(action: toggleYears) {
            Text("\(String(visibleParts.year ?? 2026))年")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .buttonStyle(CreatorGlassHitButtonStyle(
            tint: QQTheme.cyan,
            radius: CreatorGlassCalendarMetrics.controlRadius,
            prominent: mode == .years,
            today: false,
            alwaysGlass: true
        ))
        .frame(maxWidth: .infinity)
        .frame(height: CreatorGlassCalendarMetrics.headerHeight)
        .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.controlRadius, style: .continuous))
        .accessibilityLabel("选择年份")
        .accessibilityValue("\(String(visibleParts.year ?? 2026))年")
        .accessibilityHint("打开年份后不提交日期")
        .accessibilityIdentifier("CreatorGlassCalendar.yearMenu")
    }

    private var monthButton: some View {
        Button(action: toggleMonths) {
            Text("\(visibleParts.month ?? 1)月")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .buttonStyle(CreatorGlassHitButtonStyle(
            tint: QQTheme.cyan,
            radius: CreatorGlassCalendarMetrics.controlRadius,
            prominent: mode == .months,
            today: false,
            alwaysGlass: true
        ))
        .frame(width: CreatorGlassCalendarMetrics.monthButtonWidth)
        .frame(height: CreatorGlassCalendarMetrics.headerHeight)
        .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.controlRadius, style: .continuous))
        .accessibilityLabel("选择月份")
        .accessibilityValue("\(visibleParts.month ?? 1)月")
        .accessibilityHint("打开月份后不提交日期")
        .accessibilityIdentifier("CreatorGlassCalendar.monthMenu")
    }

    private func stepButton(forward: Bool) -> some View {
        let enabled = canStep(forward: forward)
        return Button {
            step(forward: forward)
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(CreatorGlassHitButtonStyle(
            tint: QQTheme.cyan,
            radius: CreatorGlassCalendarMetrics.controlRadius,
            prominent: false,
            today: false,
            alwaysGlass: true
        ))
        .frame(width: CreatorGlassCalendarMetrics.chevronSide, height: CreatorGlassCalendarMetrics.headerHeight)
        .contentShape(RoundedRectangle(cornerRadius: CreatorGlassCalendarMetrics.controlRadius, style: .continuous))
        .disabled(!enabled)
        .accessibilityLabel(stepLabel(forward: forward))
        .accessibilityHint("不提交日期")
        .accessibilityIdentifier(forward ? "CreatorGlassCalendar.next" : "CreatorGlassCalendar.previous")
    }

    private var visibleParts: DateComponents {
        calendar.dateComponents([.year, .month], from: visibleMonth)
    }

    private var todayParts: DateComponents {
        calendar.dateComponents([.year, .month], from: Date())
    }

    private var yearPageTitle: String {
        let years = CreatorGlassCalendarModel.yearSlots(pageStart: yearPageStart).compactMap { $0 }
        guard let first = years.first, let last = years.last else { return "选择年份" }
        return first == last ? "\(first)年" : "\(first)–\(last)"
    }

    private func spokenDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return "\(year)年\(month)月\(day)日"
    }

    private func dayValue(selected: Bool, today: Bool, date: Date) -> String {
        var parts: [String] = [CreatorCalendarDate.format(date)]
        if today { parts.append("今天") }
        if selected { parts.append("已选中") }
        return parts.joined(separator: "，")
    }

    private func stepLabel(forward: Bool) -> String {
        switch mode {
        case .days: return forward ? "下个月" : "上个月"
        case .months: return forward ? "下一年" : "上一年"
        case .years: return forward ? "向后十二年" : "向前十二年"
        }
    }

    private func canStep(forward: Bool) -> Bool {
        let delta = forward ? 1 : -1
        switch mode {
        case .days:
            return CreatorGlassCalendarModel.addingMonths(delta, to: visibleMonth, calendar: calendar) != nil
        case .months:
            return CreatorGlassCalendarModel.addingYears(delta, to: visibleMonth, calendar: calendar) != nil
        case .years:
            return CreatorGlassCalendarModel.pageStart(after: yearPageStart, step: delta) != nil
        }
    }

    private func step(forward: Bool) {
        guard isEnabled, canStep(forward: forward) else { return }
        let delta = forward ? 1 : -1
        switch mode {
        case .days:
            guard let next = CreatorGlassCalendarModel.addingMonths(delta, to: visibleMonth, calendar: calendar) else { return }
            visibleMonth = next
        case .months:
            guard let next = CreatorGlassCalendarModel.addingYears(delta, to: visibleMonth, calendar: calendar) else { return }
            visibleMonth = next
        case .years:
            guard let next = CreatorGlassCalendarModel.pageStart(after: yearPageStart, step: delta) else { return }
            yearPageStart = next
        }
    }

    private func toggleYears() {
        guard isEnabled else { return }
        if mode == .years {
            mode = .days
            return
        }
        yearPageStart = CreatorGlassCalendarModel.yearPageStart(for: calendar.component(.year, from: visibleMonth))
        mode = .years
    }

    private func toggleMonths() {
        guard isEnabled else { return }
        mode = mode == .months ? .days : .months
    }

    private func pickYear(_ year: Int) {
        guard isEnabled else { return }
        let month = calendar.component(.month, from: visibleMonth)
        guard let next = CreatorGlassCalendarModel.day(year: year, month: month, day: 1, calendar: calendar) else { return }
        visibleMonth = next
        mode = .days
    }

    private func pickMonth(_ month: Int) {
        guard isEnabled else { return }
        let year = calendar.component(.year, from: visibleMonth)
        guard let next = CreatorGlassCalendarModel.day(year: year, month: month, day: 1, calendar: calendar) else { return }
        visibleMonth = next
        mode = .days
    }

    /// 同一天也回调。空字符串可能借用某个锚点打开面板，重选这一天才算提交。
    private func choose(_ date: Date) {
        guard isEnabled else { return }
        guard CreatorGlassCalendarModel.canCommit(date, visibleMonthStart: visibleMonth, calendar: calendar),
              let normalized = CreatorGlassCalendarModel.startOfDay(date, calendar: calendar),
              CreatorCalendarDate.parse(CreatorCalendarDate.format(normalized)) != nil else { return }
        selection = normalized
        onSelect(normalized)
    }

    private func moveDays(_ delta: Int) {
        guard isEnabled, mode == .days else { return }
        let origin = focusedDay ?? CreatorGlassCalendarModel.startOfDay(selection, calendar: calendar) ?? visibleMonth
        guard let next = CreatorGlassCalendarModel.addingDays(delta, to: origin, calendar: calendar),
              let month = CreatorGlassCalendarModel.monthStart(containing: next, calendar: calendar) else { return }
        focusedDay = next
        if !CreatorGlassCalendarModel.isSameDay(month, visibleMonth, calendar: calendar) {
            visibleMonth = month
        }
    }

    private func alignFocus(preferSelection: Bool) {
        guard mode == .days else { return }
        if preferSelection, marksSelection,
           let selected = CreatorGlassCalendarModel.startOfDay(selection, calendar: calendar),
           let matched = CreatorGlassCalendarModel.clampDayFocus(selected, toMonth: visibleMonth, calendar: calendar),
           CreatorGlassCalendarModel.isSameDay(matched, selected, calendar: calendar) {
            focusedDay = matched
            return
        }
        if let focusedDay,
           let matched = CreatorGlassCalendarModel.clampDayFocus(focusedDay, toMonth: visibleMonth, calendar: calendar) {
            self.focusedDay = matched
            return
        }
        focusedDay = CreatorGlassCalendarModel.slots(in: visibleMonth, calendar: calendar).compactMap(\.date).first
    }
}

/// 命中区域是按钮自己的布局框。缩放只作用在字形上，框本身不位移，避免悬停进出抖动。
/// 不额外挂 tap / drag。键盘涟漪沿用 QQMotion 的键盘判断，不安装鼠标监听。
private struct CreatorGlassHitButtonStyle: ButtonStyle {
    var tint: Color = QQTheme.cyan
    var radius: CGFloat = 8
    var prominent = false
    var today = false
    var alwaysGlass = false

    func makeBody(configuration: Configuration) -> some View {
        CreatorGlassHitButtonBody(
            configuration: configuration,
            tint: tint,
            radius: radius,
            prominent: prominent,
            today: today,
            alwaysGlass: alwaysGlass
        )
    }
}

private struct CreatorGlassHitButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var tint: Color
    var radius: CGFloat
    var prominent: Bool
    var today: Bool
    var alwaysGlass: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var rippleProgress: CGFloat = 0

    private var pressed: Bool { configuration.isPressed && isEnabled }

    private var glyphScale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if pressed { return 0.96 }
        if hovering { return 1.04 }
        return 1
    }

    private var showsGlass: Bool { alwaysGlass || prominent || today || (hovering && isEnabled) }

    var body: some View {
        ZStack {
            configuration.label
                .scaleEffect(glyphScale)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { glass.allowsHitTesting(false) }
        .overlay { todayRing.allowsHitTesting(false) }
        .overlay { keyboardRipple.allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .saturation(isEnabled ? 1 : 0.35)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .spring(response: CreatorGlassCalendarMotion.hoverResponse, dampingFraction: CreatorGlassCalendarMotion.hoverDamping), value: hovering)
        .animation(reduceMotion ? nil : .spring(response: CreatorGlassCalendarMotion.pressResponse, dampingFraction: CreatorGlassCalendarMotion.pressDamping), value: pressed)
        .onHover { inside in
            hovering = inside && isEnabled
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { hovering = false }
        }
        .onChange(of: reduceMotion) { _, _ in
            hovering = false
            rippleProgress = 0
        }
        .onChange(of: pressed) { _, down in
            startKeyboardRippleIfNeeded(down)
        }
    }

    @ViewBuilder private var glass: some View {
        if showsGlass {
            ShiyingGlassSurface(
                radius: radius,
                tint: tint.opacity(prominent ? 0.20 : (hovering && isEnabled ? 0.10 : 0.05)),
                inset: true,
                control: true
            )
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        }
    }

    @ViewBuilder private var todayRing: some View {
        if today {
            Circle()
                .strokeBorder(tint.opacity(prominent ? 0.95 : 0.78), lineWidth: prominent ? 1.5 : 1.15)
                .padding(5)
        }
    }

    private var keyboardRipple: some View {
        GeometryReader { geo in
            let side = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
            Circle()
                .fill(tint)
                .frame(width: side, height: side)
                .scaleEffect(reduceMotion ? 0 : rippleProgress)
                .opacity(reduceMotion ? 0 : (1 - rippleProgress) * 0.40)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
    }

    private func startKeyboardRippleIfNeeded(_ down: Bool) {
        guard down, isEnabled, !reduceMotion else {
            rippleProgress = 0
            return
        }
        let fields = qqButtonRippleEvent(NSApp.currentEvent)
        guard QQMotion.shouldDrawButtonRipple(
            isEnabled: true,
            reduceMotion: reduceMotion,
            eventType: fields.type,
            keyCode: fields.keyCode,
            characters: fields.characters
        ) else { return }
        rippleProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.42)) { rippleProgress = 1 }
        }
    }
}

