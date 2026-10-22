import SwiftUI

@main
struct HermesWatchApp: App {
    @State private var connection = WatchConnection()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchSessionsView(connection: connection)
                .onChange(of: phase) { _, phase in
                    if phase == .active { Task { await connection.refresh() } }
                }
        }
        .backgroundTask(.watchConnectivity) { await connection.receiveContext() }
    }
}

private struct WatchSessionsView: View {
    let connection: WatchConnection
    @State private var composing = false
    @State private var confirmsAnother = false
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Selected iPhone server", tableName: "Watch").font(.caption)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading) {
                            if let count = connection.snapshot.count {
                                Text("\(count) active", tableName: "Watch").font(.title2).monospacedDigit()
                            } else { Text("Count unavailable", tableName: "Watch").font(.headline) }
                            if connection.snapshot.isStale(at: context.date) { Text("Stale · refresh needed", tableName: "Watch").foregroundStyle(.secondary) }
                        }
                    }
                    if connection.snapshot.allProfiles { Text("All Profiles", tableName: "Watch").font(.caption) }
                    if let profile = connection.snapshot.profile {
                        Text("New sessions in \(profile)", tableName: "Watch").font(.caption)
                    }
                    if let problem = connection.snapshot.problem { Text(problem.message).font(.caption) }
                    if connection.pending != nil {
                        Button(String(localized: "Check Result", table: "Watch")) { Task { await connection.checkOutcome() } }
                            .disabled(connection.busy)
                        Button(String(localized: "Start Another…", table: "Watch")) { confirmsAnother = true }.disabled(connection.busy)
                    } else {
                        Button { composing = true } label: { Label(String(localized: "New Session", table: "Watch"), systemImage: "plus") }
                            .disabled(connection.busy || !connection.snapshot.canCreate(at: Date()))
                    }
                    Button(String(localized: "Refresh", table: "Watch")) { Task { await connection.refresh() } }.disabled(connection.busy)
                    if connection.busy { ProgressView().accessibilityLabel(String(localized: "Contacting iPhone", table: "Watch")) }
                    if let status = connection.status { Text(status).font(.caption) }
                    if let id = connection.sessionID { Text(verbatim: id).font(.caption2) }
                    Text(connection.snapshot.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(String(localized: "Hermex", table: "Watch"))
            .sheet(isPresented: $composing) {
                ScrollView {
                    VStack(spacing: 12) {
                        Text("New Session", tableName: "Watch").font(.headline)
                        if let profile = connection.snapshot.profile { Text("Profile: \(profile)", tableName: "Watch").font(.caption) }
                        TextField(String(localized: "First message", table: "Watch"), text: $text)
                        Text("Creates a session and sends this message through your paired iPhone.", tableName: "Watch").font(.caption2)
                        Button(String(localized: "New Session", table: "Watch")) {
                            let message = text
                            composing = false
                            text = ""
                            Task { await connection.create(text: message) }
                        }
                        .disabled(connection.busy || connection.pending != nil || !connection.snapshot.canCreate(at: Date())
                                  || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4_000)
                    }
                }
            }
            .confirmationDialog(String(localized: "Check sessions on iPhone first. The previous request may have succeeded.", table: "Watch"), isPresented: $confirmsAnother) {
                Button(String(localized: "Start Another", table: "Watch"), role: .destructive) { connection.startAnother(); composing = true }
            }
            .onOpenURL { url in
                if url == WatchSnapshotStore.newSessionURL { composing = true }
            }
            .task { await connection.refresh() }
        }
    }
}
