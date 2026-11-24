import SwiftUI
import WidgetKit

@main
struct DailyWidgets: WidgetBundle {
    var body: some Widget {
        DailyNewNoteWidget()
        DailyReflectionWidget()
    }
}

struct DailyWidgetEntry: TimelineEntry {
    let date: Date
    let comment: DailyWidgetSnapshot?
}

struct DailyWidgetTimeline: TimelineProvider {
    func placeholder(in context: Context) -> DailyWidgetEntry {
        .init(date: .now, comment: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyWidgetEntry>) -> Void) {
        let current = entry()
        let midnight = Self.calendar.dateInterval(of: .day, for: current.date)?.end ?? current.date.addingTimeInterval(3600)
        completion(Timeline(entries: [current, .init(date: midnight, comment: nil)], policy: .after(midnight)))
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func entry() -> DailyWidgetEntry {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Self.calendar
        formatter.timeZone = Self.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: now)
        let snapshot = DailyWidgetSnapshot.read()
        return .init(date: now, comment: snapshot?.date == key ? snapshot : nil)
    }
}

struct DailyNewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyNewNote", provider: DailyWidgetTimeline()) { _ in
            DailyNewNoteWidgetView()
                .widgetURL(DailyAppleSurface.newNote)
                .containerBackground(for: .widget) { Color.blue.opacity(0.08) }
        }
        .configurationDisplayName("Yeni not")
        .description("dAIly’de bugünün yazma alanını aç.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

private struct DailyNewNoteWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            Image(systemName: "square.and.pencil").font(.title2)
                .accessibilityLabel("Yeni not")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "square.and.pencil").font(.title2.bold()).foregroundStyle(.blue)
                Text("Yeni not").font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DailyReflectionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyReflection", provider: DailyWidgetTimeline()) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Label("Günün yorumu", systemImage: "sparkles").font(.headline).foregroundStyle(.blue)
                if let comment = entry.comment {
                    Text(comment.preview).font(.subheadline).lineLimit(4).privacySensitive()
                } else {
                    Text("Bugünün yorumu hazır olduğunda burada görünür.").font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(entry.comment.map { DailyAppleSurface.reflection(date: $0.date) } ?? DailyAppleSurface.newNote)
            .containerBackground(for: .widget) { Color.blue.opacity(0.08) }
        }
        .configurationDisplayName("Günün yorumu")
        .description("Bugünün yorumundan kısa bir bölüm oku.")
        .supportedFamilies([.systemMedium])
    }
}
