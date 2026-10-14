import SwiftUI
import Foundation

enum CreatorCalendarDate {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 严格的 yyyy-MM-dd。前后空白按 CreatorCore 忽略；其余非法形态返回 nil。
    static func parse(_ text: String) -> Date? {
        let day = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if day.isEmpty { return nil }
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let dayNumber = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = dayNumber
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == dayNumber else { return nil }
        let canonical = String(format: "%04d-%02d-%02d", year, month, dayNumber)
        guard canonical == day else { return nil }
        // 上海 00:00 必须是非负整秒。1970-01-01 00:00（UTC+8）早于 epoch，CreatorCore 会判无效。
        let seconds = date.timeIntervalSince1970
        let nearest = seconds.rounded()
        guard abs(seconds - nearest) < 0.001, nearest >= 0, nearest < Double(Int64.max) else { return nil }
        return date
    }

    /// 把瞬间格式化成上海日历日。不保证该字符串能再被 parse 接受。
    static func format(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

}

struct CreatorDateFilterControl: View {
    var title: String
    @Binding var enabled: Bool
    @Binding var value: String
    var compact: Bool = false
    @State private var showingCalendar = false
    @State private var draft = Date()
    @Environment(\.isEnabled) private var isEnabled

    private var invalid: Bool { !value.isEmpty && CreatorCalendarDate.parse(value) == nil }

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Toggle(title, isOn: $enabled).toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
                .fixedSize().frame(minHeight: compact ? 30 : 36)
            Button {
                draft = CreatorCalendarDate.parse(value) ?? Date()
                showingCalendar = true
            } label: {
                HStack(spacing: 8) {
                    Text(value.isEmpty ? "选择日期" : value).monospacedDigit().lineLimit(1)
                        .foregroundStyle(invalid ? Color.orange : (value.isEmpty ? .secondary : .primary))
                    Spacer(minLength: 4)
                    Image(systemName: "calendar").foregroundStyle(QQTheme.cyan)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: compact ? 16 : 20)
            }.buttonStyle(QQSoftButtonStyle(tint: invalid ? .orange : QQTheme.cyan))
                .accessibilityLabel("选择\(title)日期")
                .accessibilityValue(value.isEmpty ? "未选择" : value)
                .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(title)日期").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button { showingCalendar = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(QQSoftButtonStyle())
                                .accessibilityLabel("关闭日期选择")
                        }
                        if invalid { Text("原日期格式无效，请重新选择；关闭会保留原值。").font(.system(size: 11)).foregroundStyle(.orange) }
                        CreatorGlassCalendar(selection: $draft, marksSelection: CreatorCalendarDate.parse(value) != nil) { date in
                            value = CreatorCalendarDate.format(date)
                            enabled = true
                            showingCalendar = false
                        }
                    }.padding(16).frame(width: 340)
                        .background { ShiyingGlassSurface(radius: 18) }
                        .presentationBackground(.clear)
                }
        }.onChange(of: isEnabled) { _, active in if !active { showingCalendar = false } }
    }
}
