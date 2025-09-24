// SB MTD Next Departures — SwiftUI single-file MVP
// Tejas, drop this file into a fresh Xcode > iOS > App (SwiftUI) project as ContentView.swift.
// Runs on iOS 16+. No API keys needed. It scrapes SBMTD BusTracker HTML for the stops you asked about
// and filters for routes 11, 27, 28, 24X.
//
// Notes / roadmap:
// - Uses official stop IDs we verified on SBMTD BusTracker.
// - Heuristic direction filter for Elings & North Hall to show trips heading toward Storke & El Colegio.
// - You can later swap the backend to GTFS-RT or Google Directions Transit easily via the provider protocol.
// - Pull-to-refresh, auto-refresh, offline caching, beautiful widgets can be added in follow‑ups.

import SwiftUI
import Combine

// MARK: - User settings
struct UserStopConfig: Identifiable, Codable, Hashable {
    var id: String            // stop id
    var label: String         // user label
    var selectedRoutes: Set<String> = [] // empty means all
    var headsignIncludes: String = ""   // optional contains filter
    var enabled: Bool = true
}

fileprivate let USER_STOPS_KEY = "userStops.v1"
fileprivate let USE_CUSTOM_STOPS_ONLY_KEY = "useCustomStopsOnly.v1"

fileprivate func loadUserStops() -> [UserStopConfig] {
    if let data = UserDefaults.standard.data(forKey: USER_STOPS_KEY) {
        if let decoded = try? JSONDecoder().decode([UserStopConfig].self, from: data) {
            return decoded
        }
    }
    return []
}

fileprivate func saveUserStops(_ stops: [UserStopConfig]) {
    if let data = try? JSONEncoder().encode(stops) {
        UserDefaults.standard.set(data, forKey: USER_STOPS_KEY)
    }
}

fileprivate func loadUseCustomStopsOnly() -> Bool {
    UserDefaults.standard.bool(forKey: USE_CUSTOM_STOPS_ONLY_KEY)
}

fileprivate func saveUseCustomStopsOnly(_ flag: Bool) {
    UserDefaults.standard.set(flag, forKey: USE_CUSTOM_STOPS_ONLY_KEY)
}

// MARK: - Config
fileprivate enum Routes: String, CaseIterable {
    case r11 = "11"
    case r27 = "27"
    case r28 = "28"
    case r24X = "24X"
}

struct Stop: Identifiable, Hashable {
    let id: String        // SBMTD BusTracker stop id
    let label: String     // UI label
    let purpose: Purpose
    enum Purpose { case storkeAndSierraMadre, ucsbElings, ucsbNorthHall, custom }
}

// Official stop IDs observed on SBMTD BusTracker (public site)
//  - Storke & Sierra Madre: 371
//  - UCSB Elings Hall (Outbound): 1023 (the /wireless page sometimes shows this as Outbound/Downtown SB)
//  - UCSB North Hall (Outbound): 42
// If these ever change, just update the IDs here.
fileprivate let STOPS: [Stop] = [
    .init(id: "371", label: "Storke & Sierra Madre", purpose: .storkeAndSierraMadre),
    .init(id: "1023", label: "UCSB Elings Hall", purpose: .ucsbElings),
    .init(id: "42", label: "UCSB North Hall", purpose: .ucsbNorthHall)
]

// MARK: - Models
struct Prediction: Identifiable, Hashable {
    let id = UUID()
    let route: String       // e.g. "11", "27", "28", "24X"
    let headsign: String    // e.g. "UCSB North Hall", "Downtown SB", "Camino Real Mkt"
    let minutes: Int?       // nil if not parsable; 0 for APPROACHING/DUE
}

struct StopBoard: Identifiable {
    let id = UUID()
    let stop: Stop
    let predictions: [Prediction]
    let fetchedAt: Date
}

// MARK: - Provider abstraction
protocol DeparturesProvider {
    func fetch(stopId: String) async throws -> [Prediction]
}

// MARK: - SBMTD BusTracker HTML provider (no key required)
// Endpoint pattern: https://bustracker.sbmtd.gov/bustime/wireless/html/eta.jsp?id=STOPID&showAllBuses=on
// We parse simple "#<route> <headsign> <N MIN | APPROACHING | DUE>" rows.
final class SBMTDBusTrackerProvider: DeparturesProvider {
    func fetch(stopId: String) async throws -> [Prediction] {
        // Try a few direction flavors that SBMTD uses to ensure results show up.
        let base = "https://bustracker.sbmtd.gov/bustime/wireless/html/eta.jsp"
        let variants: [URL] = {
            if ["42", "1023", "371"].contains(stopId) {
                // Special-case these stops per user-provided working URL format that includes id=STOPID
                return [URL(string: "https://bustracker.sbmtd.gov/bustime/wireless/html/eta.jsp?route=---&direction=---&displaydirection=---&stop=---&findstop=on&selectedRtpiFeeds=&id=\(stopId)")!]
            } else {
                return [
                    URL(string: "\(base)?id=\(stopId)&showAllBuses=on"),
                    URL(string: "\(base)?direction=UCSB&id=\(stopId)&showAllBuses=on"),
                    URL(string: "\(base)?direction=DOWNTOWN+SB&id=\(stopId)&showAllBuses=on"),
                    URL(string: "\(base)?direction=UCSB+Only&id=\(stopId)&showAllBuses=on")
                ].compactMap { $0 }
            }
        }()

        var usedURL: URL? = nil
        var html = ""
        for url in variants {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let s = String(data: data, encoding: .utf8), s.contains("Selected Stop") || s.contains("Welcome to SBMTD") {
                html = s
                usedURL = url
#if DEBUG
    let preview = s.count > 4000 ? String(s.prefix(4000)) + "…(truncated)" : s
    print("\n===== SBMTD RAW HTML for stop \(stopId) via \(url.absoluteString) =====\n\(preview)\n===== END RAW HTML (len=\(s.count)) =====\n")
#endif
                break
            }
        }
        guard !html.isEmpty else {
#if DEBUG
            print("SBMTD fetch stop \(stopId): no HTML from variants")
#endif
            return []
        }
        let predictions = parse(html: html)
#if DEBUG
        print("SBMTD fetch stop \(stopId) via \(usedURL?.absoluteString ?? "unknown URL") -> \(predictions.count) predictions")
        for p in predictions {
            let eta: String
            if let m = p.minutes {
                eta = m <= 0 ? "APPROACHING" : "\(m) MIN"
            } else {
                eta = "—"
            }
            print("  #\(p.route)  \(p.headsign)  \(eta)")
        }
#endif
        return predictions
    }

    private func parse(html: String) -> [Prediction] {
        // Extremely lightweight parsing: look for blocks that start with "##  #" and then capture route, headsign, minutes.
        // Example snippets:
        //   ##  #28  UCSB North Hall   5 MIN
        //   ##  #11  Downtown SB   APPROACHING
        //   ##  #24X  UCSB / Camino Real Mkt   19 MIN
        var results: [Prediction] = []

        // Normalize whitespace to simplify regex.
        let squished = html.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\n\n", with: "\n")

        let text = squished.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Regex: route token (allow optional extra #), then headsign (greedy but trimmed), then minutes or APPROACHING/DUE.
        let pattern = "#\\s*#?([0-9]{1,2}X?)\\s+([^\\n\\r]+?)\\s+(APPROACHING|DUE|\\d+\\s*MIN(?:S)?)"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = text as NSString
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) ?? []

        for m in matches {
            guard m.numberOfRanges >= 4 else { continue }
            let route = ns.substring(with: m.range(at: 1)).uppercased()
            var headsign = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            headsign = headsign.replacingOccurrences(of: "\u{00A0}", with: " ")
            let rawMin = ns.substring(with: m.range(at: 3)).uppercased()

            let minutes: Int?
            if rawMin.contains("APPROACHING") || rawMin.contains("DUE") { minutes = 0 }
            else if let n = Int(rawMin.replacingOccurrences(of: "MIN", with: "").trimmingCharacters(in: CharacterSet.whitespaces)) { minutes = n }
            else { minutes = nil }

            results.append(.init(route: route, headsign: headsign, minutes: minutes))
        }
#if DEBUG
        if results.isEmpty {
            print("SBMTD parse: no matches found; first 500 chars: \(text.prefix(500))")
        }
#endif
        return results
    }
}

// MARK: - Direction filter heuristics
fileprivate func towardStorkeElColegio(_ p: Prediction) -> Bool {
    // We want trips heading toward the Storke & El Colegio area.
    // Common headsigns that move in that direction: "UCSB", "Camino Real", "Isla Vista", "Storke", "Marketplace".
    let h = p.headsign.lowercased()
    return h.contains("ucsb") || h.contains("camino real") || h.contains("isla vista") || h.contains("storke") || h.contains("market")
}

fileprivate func towardCaminoRealMarket(_ p: Prediction) -> Bool {
    // Strictly prefer trips heading toward Camino Real Market / Marketplace.
    // Common headsign variants observed: "Camino Real", "Camino Real Mkt", "Camino Real Market", "Marketplace".
    let h = p.headsign.lowercased()
    return h.contains("camino real mkt") || h.contains("marketplace") || h.contains("market") || h.contains("mkt")
}

// MARK: - ViewModel
@MainActor
final class AppModel: ObservableObject {
    @Published var boards: [StopBoard] = []
    @Published var isRefreshing = false
    private let provider: DeparturesProvider = SBMTDBusTrackerProvider()

    private func currentUserStops() -> (useCustom: Bool, stops: [UserStopConfig]) {
        return (loadUseCustomStopsOnly(), loadUserStops())
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        var next: [StopBoard] = []
        let settings = currentUserStops()
        if settings.useCustom, !settings.stops.filter({ $0.enabled }).isEmpty {
            // Use user-defined stops
            for cfg in settings.stops where cfg.enabled {
                do {
                    let preds = try await provider.fetch(stopId: cfg.id)
                    // Apply per-stop route filter (empty means all)
                    let routeFiltered: [Prediction]
                    if cfg.selectedRoutes.isEmpty { routeFiltered = preds }
                    else { routeFiltered = preds.filter { cfg.selectedRoutes.contains($0.route) } }
                    // Apply optional headsign contains filter
                    let headsignFilter = cfg.headsignIncludes.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let final = headsignFilter.isEmpty ? routeFiltered : routeFiltered.filter { $0.headsign.lowercased().contains(headsignFilter) }
                    let sorted = final.sorted { (a, b) in (a.minutes ?? 9_999) < (b.minutes ?? 9_999) }
                    let stop = Stop(id: cfg.id, label: cfg.label.isEmpty ? cfg.id : cfg.label, purpose: .custom)
                    next.append(StopBoard(stop: stop, predictions: Array(sorted.prefix(6)), fetchedAt: Date()))
                } catch {
                    let stop = Stop(id: cfg.id, label: cfg.label.isEmpty ? cfg.id : cfg.label, purpose: .custom)
                    next.append(StopBoard(stop: stop, predictions: [], fetchedAt: Date()))
                }
            }
        } else {
            // Use built-in defaults
            for stop in STOPS {
                do {
                    let preds = try await provider.fetch(stopId: stop.id)
                    let filtered: [Prediction]
                    switch stop.purpose {
                    case .storkeAndSierraMadre:
                        filtered = preds.filter { Routes.allCases.map { $0.rawValue }.contains($0.route) }
                    case .ucsbElings, .ucsbNorthHall:
                        filtered = preds.filter { ["11","27","28"].contains($0.route) && towardCaminoRealMarket($0) }
                    case .custom:
                        filtered = preds
                    }
                    let sorted = filtered.sorted { (a, b) in (a.minutes ?? 9_999) < (b.minutes ?? 9_999) }
                    next.append(StopBoard(stop: stop, predictions: Array(sorted.prefix(6)), fetchedAt: Date()))
                } catch {
                    next.append(StopBoard(stop: stop, predictions: [], fetchedAt: Date()))
                }
            }
        }
        boards = next
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.boards) { board in
                    Section(board.stop.label) {
                        if board.predictions.isEmpty {
                            Text("No predictions found right now.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(board.predictions) { p in
                                HStack {
                                    Text(p.route)
                                        .font(.system(.title3, design: .rounded)).bold()
                                        .frame(width: 54)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.headsign)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text(etaString(p.minutes))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Route \(p.route) to \(p.headsign), \(etaString(p.minutes)).")
                            }
                        }

                        ElapsedSinceView(since: board.fetchedAt)
                            .padding(.top, 4)
                    }
                }
            }
            .navigationTitle("SB MTD — Next buses")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { Task { await model.refresh() } }) {
                        if model.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func etaString(_ minutes: Int?) -> String {
        guard let m = minutes else { return "—" }
        if m <= 0 { return "Approaching" }
        if m == 1 { return "1 min" }
        return "\(m) min"
    }

    private func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: .now)
    }
}

private struct ElapsedSinceView: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text("Last updated \(stopwatchString(since: since))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last updated \(stopwatchString(since: since))")
        }
    }
}

private func stopwatchString(since date: Date) -> String {
    let interval = max(0, Int(Date().timeIntervalSince(date)))
    let hours = interval / 3600
    let minutes = (interval % 3600) / 60
    let seconds = interval % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var useCustomOnly: Bool = loadUseCustomStopsOnly()
    @State private var stops: [UserStopConfig] = loadUserStops()
    @State private var newStopId: String = ""
    @State private var newStopLabel: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Toggle("Use custom stops only", isOn: $useCustomOnly)
                }

                Section("Add stop") {
                    TextField("Stop ID", text: $newStopId)
                        .keyboardType(.numberPad)
                    TextField("Label (optional)", text: $newStopLabel)
                    Button("Add") { addStop() }
                        .disabled(newStopId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Your stops") {
                    if stops.isEmpty {
                        Text("No custom stops added yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach($stops) { $cfg in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("Label", text: $cfg.label)
                                    Spacer()
                                    Toggle("Enabled", isOn: $cfg.enabled).labelsHidden()
                                }
                                Text("Stop ID: \(cfg.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                // Route choices
                                RoutePicker(selected: $cfg.selectedRoutes)

                                // Optional headsign contains filter
                                TextField("Headsign contains (optional)", text: $cfg.headsignIncludes)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                            .swipeActions {
                                Button(role: .destructive) { deleteStop(id: cfg.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Save") { saveAndClose() }.bold() }
            }
        }
    }

    private func addStop() {
        let id = newStopId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let label = newStopLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let cfg = UserStopConfig(id: id, label: label.isEmpty ? id : label, selectedRoutes: [], headsignIncludes: "", enabled: true)
        stops.append(cfg)
        newStopId = ""
        newStopLabel = ""
    }

    private func deleteStop(id: String) {
        stops.removeAll { $0.id == id }
    }

    private func saveAndClose() {
        saveUseCustomStopsOnly(useCustomOnly)
        saveUserStops(stops)
        dismiss()
    }
}

private struct RoutePicker: View {
    @State var allRoutes: [String] = Routes.allCases.map { $0.rawValue }
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Routes")
                Spacer()
                Button(selected.isEmpty ? "All" : "Clear") {
                    if selected.isEmpty { selected = Set(allRoutes) } else { selected.removeAll() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            // Toggle chips
            WrapHStack(spacing: 8) {
                ForEach(allRoutes, id: \.self) { r in
                    let isOn = selected.contains(r) || selected.isEmpty
                    Button(action: { toggle(r) }) {
                        Text("#\(r)")
                            .font(.caption)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
                    }
                }
            }
            .padding(.top, 2)
            Text("Select none to allow all routes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ r: String) {
        if selected.contains(r) { selected.remove(r) } else { selected.insert(r) }
    }
}

// Simple wrapping HStack for chips
private struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geo.size.width {
                            width = 0; height -= d.height + spacing
                        }
                        let result = width
                        if d[.trailing] > geo.size.width { width = 0; height -= d.height + spacing }
                        width -= d.width + spacing
                        return result
                    }
                    .alignmentGuide(.top) { _ in height }
            }
        }
        .frame(height: 80)
    }
}

// MARK: - App entry point
@main
struct SBMTDNextApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Optional: future Google / GTFS implementation sketch
// If you want to pivot to Google Directions (Transit) or GTFS-RT later, keep the DeparturesProvider protocol
// and add another provider. Example skeleton below — fill with your credentials and parsers.

final class GoogleTransitProvider: DeparturesProvider {
    // TODO: Use Google Directions API (mode=transit) with origin as a stop place_id and departure_time=now
    // then map legs to upcoming trips. Requires a Google Maps Platform API key & enabling the product.
    func fetch(stopId: String) async throws -> [Prediction] { return [] }
}

final class GTFSRealtimeProvider: DeparturesProvider {
    // TODO: If/when SBMTD publishes a public GTFS-RT TripUpdates/VehiclePositions URL without auth,
    // you can decode the protobuf and compute ETAs for each stop. Otherwise, keep using BusTracker.
    func fetch(stopId: String) async throws -> [Prediction] { return [] }
}

