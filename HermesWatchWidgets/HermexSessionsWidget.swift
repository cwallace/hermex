import SwiftUI
import WidgetKit

private struct SessionsEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot
}

private struct SessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: .now, snapshot: WatchSnapshot(count: 2, profile: "default", allProfiles: true))
    }
    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        completion(SessionsEntry(date: .now, snapshot: WatchSnapshotStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        let now = Date(), snapshot = WatchSnapshotStore.load()
        var entries = [SessionsEntry(date: now, snapshot: snapshot)]
        let expires = snapshot.date.addingTimeInterval(301)
        if expires > now { entries.append(SessionsEntry(date: expires, snapshot: snapshot)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}

@main
struct HermexSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchSnapshotStore.kind, provider: SessionsProvider()) { entry in
            SessionsComplication(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WatchSnapshotStore.newSessionURL)
                .privacySensitive()
        }
        .configurationDisplayName(String(localized: "Hermex Sessions", table: "Watch"))
        .description(String(localized: "Active sessions on the selected iPhone server. Tap to start a session.", table: "Watch"))
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

private struct SessionsComplication: View {
    @Environment(\.widgetFamily) private var family
    let entry: SessionsEntry
    private var stale: Bool { entry.snapshot.isStale(at: entry.date) }
    private var count: String { entry.snapshot.count.map(String.init) ?? "—" }
    private var state: String {
        if entry.snapshot.problem != nil { return String(localized: "Unavailable", table: "Watch") }
        return stale ? String(localized: "Stale", table: "Watch") : String(localized: "Active", table: "Watch")
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("Hermex \(count) · \(state)", tableName: "Watch")
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Text(verbatim: count).font(.title2).monospacedDigit()
                    Text(state).font(.caption2).minimumScaleFactor(0.6)
                }
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hermex · \(count) \(state)", tableName: "Watch").font(.headline).monospacedDigit()
                    Text(entry.snapshot.allProfiles ? String(localized: "Selected server · all Profiles", table: "Watch") : String(localized: "Selected server · active Profile", table: "Watch")).font(.caption2)
                    Text("+ New Session", tableName: "Watch").font(.caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Opens Hermex on Apple Watch to create a session through iPhone", table: "Watch"))
    }
}
