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
    var id: String            // stop code
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
// Endpoint pattern: https://bustracker.sbmtd.gov/bustime/wireless/html/eta.jsp?route=---&direction=---&displaydirection=---&stop=---&findstop=on&selectedRtpiFeeds=&id=STOPID
// We parse simple "#<route> <headsign> <N MIN | APPROACHING | DUE>" rows.
final class SBMTDBusTrackerProvider: DeparturesProvider {
    func fetch(stopId: String) async throws -> [Prediction] {
        // Request the full departure board by stop ID using the canonical query shape.
        let url = URL(string: "https://bustracker.sbmtd.gov/bustime/wireless/html/eta.jsp?route=---&direction=---&displaydirection=---&stop=---&findstop=on&selectedRtpiFeeds=&id=\(stopId)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8), !html.isEmpty else {
#if DEBUG
            print("SBMTD fetch stop \(stopId): no HTML or bad status for URL: \(url.absoluteString)")
#endif
            return []
        }
#if DEBUG
        do {
            let preview = html.count > 4000 ? String(html.prefix(4000)) + "…(truncated)" : html
            print("\n===== SBMTD RAW HTML for stop \(stopId) via \(url.absoluteString) =====\n\(preview)\n===== END RAW HTML (len=\(html.count)) =====\n")
        }
#endif
        let predictions = parse(html: html)
#if DEBUG
        print("SBMTD fetch stop \(stopId) via \(url.absoluteString) -> \(predictions.count) predictions")
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

        // Two regex patterns for different formats:
        let pattern1 = "#\\s*#?([0-9]{1,2}X?)\\s+([^\\n\\r]+?)\\s+(APPROACHING|DUE|ARRIVING|\\d+\\s*MIN\\w*)"
        let pattern2 = "(?m)^\\s*([0-9]{1,2}X?)\\s+([^\\n\\r]+?)\\s+(APPROACHING|DUE|ARRIVING|\\d+\\s*MIN\\w*)"

        func collect(using pattern: String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let ns = text as NSString
            let matches = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges >= 4 else { continue }
                let route = ns.substring(with: m.range(at: 1)).uppercased()
                var headsign = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                headsign = headsign.replacingOccurrences(of: "\u{00A0}", with: " ")
                let rawMin = ns.substring(with: m.range(at: 3)).uppercased()

                let minutes: Int?
                if rawMin.contains("APPROACHING") || rawMin.contains("DUE") || rawMin.contains("ARRIVING") { minutes = 0 }
                else {
                    // Extract first integer found (handles MIN, MINS, MINUTES, etc.)
                    if let dig = rawMin.range(of: "[0-9]+", options: .regularExpression) {
                        minutes = Int(rawMin[dig])
                    } else { minutes = nil }
                }
                results.append(.init(route: route, headsign: headsign, minutes: minutes))
            }
        }
        collect(using: pattern1)
        if results.isEmpty { collect(using: pattern2) }

#if DEBUG
        if results.isEmpty {
            let preview = text.count > 600 ? String(text.prefix(600)) + "…" : text
            print("SBMTD parse: no matches found; text preview: \(preview)")
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
        // Use only user-defined stops; if none are enabled, show nothing
        let enabledCustom = loadUserStops().filter { $0.enabled }
        guard !enabledCustom.isEmpty else {
            boards = []
            return
        }

        for cfg in enabledCustom {
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
        boards = next
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showingSettings = false
    @State private var showingLookup = false

    @State private var showingEdit = false
    @State private var editingStopId: String? = nil
    @State private var editingKeyword: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.boards) { board in
                    Section {
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
                    } header: {
                        HStack {
                            Text(board.stop.label)
                            Spacer()
                            if board.stop.purpose == .custom {
                                Button {
                                    startEdit(stopId: board.stop.id)
                                } label: {
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit filters")

                                Button {
                                    removeFromHome(stopId: board.stop.id)
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove stop")
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("SB MTD — Next buses").font(.headline)
                        Text("Data Provided by Santa Barbara MTD")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                        Button { showingLookup = true } label: { Image(systemName: "text.page.badge.magnifyingglass") }
                            .accessibilityLabel("Lookup stop")
                    }
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
            .sheet(isPresented: $showingLookup) {
                StopLookupView()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingEdit) {
                if let stopId = editingStopId {
                    EditStopFilterView(stopId: stopId, initialKeyword: editingKeyword) { newKeyword in
                        saveKeyword(for: stopId, keyword: newKeyword)
                        showingEdit = false
                    }
                }
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
    
    private func removeFromHome(stopId: String) {
        var stops = loadUserStops()
        stops.removeAll { $0.id == stopId }
        saveUserStops(stops)
        Task { await model.refresh() }
    }

    private func startEdit(stopId: String) {
        let stops = loadUserStops()
        if let cfg = stops.first(where: { $0.id == stopId }) {
            editingStopId = stopId
            editingKeyword = cfg.headsignIncludes
        } else {
            editingStopId = stopId
            editingKeyword = ""
        }
        showingEdit = true
    }

    private func saveKeyword(for stopId: String, keyword: String) {
        var stops = loadUserStops()
        if let idx = stops.firstIndex(where: { $0.id == stopId }) {
            stops[idx].headsignIncludes = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            saveUserStops(stops)
        } else {
            // If the stop isn't in custom list for some reason, add it with this keyword
            let cfg = UserStopConfig(id: stopId, label: stopId, selectedRoutes: [], headsignIncludes: keyword.trimmingCharacters(in: .whitespacesAndNewlines), enabled: true)
            stops.append(cfg)
            saveUserStops(stops)
        }
        Task { await model.refresh() }
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

private struct EditStopFilterView: View {
    let stopId: String
    let initialKeyword: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String = ""

    init(stopId: String, initialKeyword: String, onSave: @escaping (String) -> Void) {
        self.stopId = stopId
        self.initialKeyword = initialKeyword
        self.onSave = onSave
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter") {
                    TextField("Headsign contains (optional)", text: $keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                Section(footer: Text("Trips whose headsign contains this text will be shown. Leave blank to show all.").font(.footnote).foregroundStyle(.secondary)) { EmptyView() }
            }
            .navigationTitle("Edit Stop")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(keyword)
                    }.bold()
                }
            }
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
                    TextField("Stop Code", text: $newStopId)
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
                                Text("Stop Code: \(cfg.id)")
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

// MARK: - Stop catalog (from stops.txt)
private struct StopCatalogEntry: Identifiable, Hashable {
    let id: String      // stop_id for fetching
    let code: String    // stop_code (searchable)
    let name: String    // stop_name (searchable)
}

private enum StopCatalog {
    static var cached: [StopCatalogEntry]? = nil

    static var usedFallback: Bool = false

    static let minimalStops: [StopCatalogEntry] = [
        StopCatalogEntry(id: "371", code: "371", name: "Storke & Sierra Madre"),
        StopCatalogEntry(id: "1023", code: "1023", name: "UCSB Elings Hall Outbound"),
        StopCatalogEntry(id: "42", code: "42", name: "UCSB North Hall Outbound")
    ]

    static let embeddedCSV: String = """
    stop_id,stop_code,stop_name
    1,1,Modoc & Portesuello
    2,10,Milpas & Montecito
    3,100,Via Real & Santa Ynez
    4,1001,Cathedral Oaks & Camino Del Rio
    5,102,Via Real & Sandpiper MHP
    6,1023,UCSB Elings Hall Outbound
    7,1024,Cathedral Oaks & Via Chaparral
    8,103,Carpinteria & Palm
    10,104,Anapamu & Santa Barbara
    13,1044,Hollister & Sumida
    15,1052,Seville & Embarcadero Del Mar
    16,1053,Seville & Embarcadero Del Mar
    17,1054,Embarcadero & Sabado Tarde
    18,1055,Embarcadero & Sabado Tarde
    19,1056,Abrego & Camino Pescadero
    20,1063,El Colegio & Embarcadero Del Mar
    21,1064,El Colegio & Los Carneros
    22,1065,El Colegio & Los Carneros
    23,1066,El Colegio & Embarcadero Del Mar
    25,1069,El Colegio & Camino Corto
    27,108,Storke & Hollister 108
    29,1081,Encina Road & Encina Lane
    30,109,Hollister & Cathedral Oaks
    31,110,Hollister & Entrance
    32,114,Calle Real & Kingston
    33,115,Arrellaga & Castillo
    34,116,Cabrillo & State
    36,118,Cabrillo & State
    37,119,Santa Barbara Zoo
    38,12,San Andres & Valerio
    39,120,Harbor
    41,123,Santa Ynez & Via Real
    45,128,Franklin Center
    46,136,Cathedral Oaks & Alpha Resource
    47,14,Treasure & Samarkand
    48,143,Winchester Canyon & Bradford
    49,144,Hollister & Pacific Oaks
    50,15,State & San Roque
    51,153,Cota & Olive
    52,156,State & La Cumbre 156
    53,157,Hollister & Turnpike
    54,16,State & La Cumbre
    55,164,Encina & Fairview
    56,17,State & Broadmoor
    58,173,State & Mission
    59,174,Milpas & Cota
    60,175,Anacapa & De La Guerra
    62,181,Hollister & Nectarine
    63,182,Haley & Garden
    64,183,Anapamu & State
    65,184,Anacapa & Carrillo
    66,186,Cota & State
    67,187,Haley & Bath
    69,189,Montecito & Rancheria
    70,19,Hillside House
    71,190,Cliff & Weldon
    72,191,Cliff & La Marina
    73,192,Cliff & Terrace
    74,193,Cliff & Santa Fe
    75,194,Cliff & Mira Mesa
    76,195,Meigs & Dolores
    77,196,Meigs & Aurora
    78,197,Meigs & La Coronilla
    79,198,Carrillo & Miramonte
    80,199,Carrillo & Vista Del Pueblo
    81,2,San Andres & Valerio
    82,20,Arroyo Burro Beach Park
    83,200,Carrillo & Bath
    84,203,Carrillo & Anapamu
    85,206,Carrillo & Chino
    86,208,Meigs & Red Rose
    87,209,Cliff & Salida Del Sol
    88,21,Cliff & Meigs
    89,210,Cliff & Santa Cruz
    90,211,Cliff & San Rafael
    91,212,Cliff & Oceano
    92,213,Chapala & Haley
    93,216,Chapala & Anapamu
    94,217,Sola & Chapala
    95,218,Portesuello & Gillespie
    96,219,Mission & Chino
    97,22,Cliff & Loma Alta
    98,220,San Andres & Pedregosa
    99,221,San Andres & Micheltorena
    100,222,San Andres & Sola
    101,223,San Andres & Anapamu
    102,224,Carrillo & San Andres
    103,225,Modoc & Oak
    104,227,Anapamu & Garden
    105,228,Anapamu & Olive
    106,229,Milpas & Figueroa
    107,23,Cliff & Loma Alta
    108,230,Milpas & Canon Perdido
    109,231,Milpas & De La Guerra
    110,233,Salinas & Clifton
    111,234,Salinas & Mason
    112,235,Salinas & Cacique
    113,236,Punta Gorda at Bridge
    114,237,Voluntario & Hutash
    115,238,Voluntario & Carpinteria
    116,239,Milpas & Carpinteria
    117,24,Hollister & Turnpike
    118,240,Milpas & Mason
    119,241,Milpas & Haley
    120,242,Milpas & Ortega
    121,243,Anapamu & Nopal
    122,244,State & Sola
    123,245,State & Arrellaga
    124,246,State & Valerio
    125,247,State & Islay
    126,248,State & Pueblo
    127,249,State & Quinto
    128,25,Hollister & Kellogg
    129,250,State & Constance
    131,252,State & Calle Laureles
    132,253,State & Calle Palo Colorado
    133,254,State & Broadmoor
    134,255,State & Ontare
    135,256,State & Hope
    136,257,State & Highway 154
    137,258,Hollister & Nogal
    138,259,Hollister & Auhay East
    139,26,Storke & Hollister
    140,260,Hollister & Sport Center
    141,261,Hollister & San Antonio
    143,263,Hollister & San Marcos
    145,265,Hollister & Lassen
    147,268,Hollister & Ward
    148,269,Hollister & Wendy's
    149,27,Santa Felicia & Marketplace
    150,270,Hollister & Orange
    152,272,Hollister & David Love
    161,281,Storke & Marketplace
    162,282,Santa Felicia & Storke
    163,283,Santa Felicia & Girsh Park
    164,284,Hollister & Camino Real Marketplace
    170,29,State & Las Positas
    172,291,Hollister & San Ricardo
    173,292,Hollister & Via El Cuadro
    176,295,State & Hitchcock
    178,297,State & Los Olivos
    179,298,State & Pedregosa
    180,299,Anacapa & Sola
    181,3,Carrillo & San Pascual
    182,300,Westside Community Center
    183,307,Calle Real & Kingston
    184,308,Encina & Calle Real
    185,31,Calle Real & Turnpike West
    186,312,Hollister & Cannon Green
    187,313,Hollister & Palo Alto
    188,314,Hollister & Santa Barbara Shores
    189,315,Hollister & Viajero
    192,318,Milpas & Quinientos
    193,319,Milpas & Cacique
    194,32,University & Patterson
    195,320,Coast Village & Butterfly
    196,321,Coast Village & Middle
    197,322,Coast Village & Olive Mill
    198,323,Carpinteria & Reynolds
    199,324,Coast Village & Coast Village Ciricle
    200,325,Milpas & De La Guerra
    201,326,Milpas & Puerto Vallarta
    202,327,Bath & Los Olivos
    203,328,Junipero & Alamar
    204,329,Junipero & Calle Real
    205,33,Fairview & Encina
    206,330,San Onofre & Las Positas
    208,332,De La Vina & Mission
    209,333,De La Vina & Islay
    210,334,De La Vina & Micheltorena
    211,335,Cabrillo & Los Patos
    212,336,El Colegio & Stadium
    213,342,Carpinteria & Casitas Plaza Out
    214,343,Chapala & Cota
    216,345,Chapala & Canon Perdido
    217,346,De La Vina & Canon Perdido
    218,347,De La Vina & Ortega
    219,348,De La Vina & Haley
    220,349,Cliff & Fellowship
    221,35,Encina & Fairview
    222,350,Cliff & Flora Vista
    223,351,Cliff & Alan
    225,353,Las Positas & Las Positas Park
    226,354,Las Positas & Richelle
    227,355,Torino & Veronica Springs
    228,356,Torino & Palermo
    229,357,Torino & Barcelona
    230,358,Torino & Calle De Los Amigos
    231,359,Calle De Los Amigos & Senda Verde
    232,360,Mariana & Vista del Monte
    233,361,Calle De Los Amigos & Mariana
    234,362,Calle De Los Amigos & Modoc
    235,363,Modoc & La Cumbre Country Club
    236,364,La Cumbre Plaza & Plaza Ave
    237,365,Calle De Los Amigos & Cinco Amigos
    238,366,Casiano & Mariana
    239,367,Veronica Springs & Torino
    240,368,Cliff & Las Positas
    241,369,Cliff & Mohawk
    242,37,Cathedral Oaks & Fairview
    243,370,Cliff & Oliver
    246,373,Storke & Phelps
    247,374,Storke & Santa Felicia
    249,386,Cabrillo & Garden
    251,389,Chapala & Sola
    252,39,Cathedral Oaks & Turnpike
    253,390,Arrellaga & De La Vina
    254,391,San Pascual & Ortega
    255,392,Coronel & Wentworth
    256,394,Anapamu & Bath
    257,395,Bath & Victoria
    258,396,Bath & Micheltorena
    259,397,Bath & Valerio
    260,398,Bath & Islay
    261,399,Bath & Mission
    262,4,Transit Center
    263,40,Foothill & Cieneguitas
    264,400,Calle Real & Treasure
    265,401,Las Positas & Stanley
    266,402,Hitchcock & State
    267,403,Hitchcock & La Rada
    268,404,Hitchcock & Calle Real
    269,405,Calle Real & La Cumbre
    270,406,Treasure & Calle Real
    271,407,De La Vina & Victoria
    272,408,De La Vina & Anapamu
    273,409,Calle Real & Pesetas
    274,410,Calle Real & Old Mill
    275,411,Calle Real & El Sueno
    276,414,Calle Real & San Antonio
    277,415,Calle Real & Turnpike
    278,416,Calle Real & Pebble Hill
    279,417,San Marcos & Calle Real
    280,418,University & San Marcos
    281,419,University & Ribera
    282,42,UCSB North Hall Outbound
    283,420,Calle Real & Patterson
    284,421,Calle Real & Maravilla
    285,422,Pesetas & Calle Real
    286,423,La Colina & Pesetas
    287,424,La Colina & Lee
    288,425,La Cumbre & La Colina
    289,426,La Cumbre & Via Lucero
    290,427,Haley & Santa Barbara
    291,428,Haley & Laguna
    292,429,Haley & Salsipuedes
    293,43,Winchester Canyon & Bradford
    294,430,Haley & Quarantina
    295,431,Haley & Milpas
    296,432,Lillie & Valencia
    297,433,Lillie & Olive
    298,434,Lillie & Greenwell
    299,435,Via Real & West Padaro
    300,436,Via Real & Toro Canyon
    301,437,Via Real & Sentar
    302,438,Via Real & Nidever
    303,439,Via Real & Gallup & Stribling
    304,44,De La Guerra & Laguna
    305,440,Via Real & East Padaro
    306,441,Via Real & Via Real Flowers
    307,442,Via Real & Cravens
    308,443,Via Real & Casas De Las Flores
    309,445,Via Real & Santa Monica East
    310,447,Carpinteria & Elm
    311,448,Carpinteria & Maple
    312,45,Milpas & Gutierrez
    313,450,Carpinteria & Concha Loma
    314,452,Carpinteria & Bailard
    315,453,Carpinteria & S&S Seed
    316,454,Carpinteria Tech Park
    317,455,Carpinteria & Highway 150
    318,456,Hwy 150 & Camino Carreta
    319,457,Via Real & Business Park
    320,458,Via Real & Vista de Santa Barbara
    321,459,Via Real & Bailard
    322,46,Coast Village & Hot Springs
    323,460,Carpinteria & Eugenia
    325,462,Lillie & Colville
    326,463,Gutierrez & Nopal
    327,464,Gutierrez & Salsipuedes
    328,465,Gutierrez & Laguna
    329,466,Gutierrez & Santa Barbara
    330,467,Gutierrez & State
    331,468,Anacapa & Ortega
    332,469,Colusa & Del Norte
    333,47,East Valley & San Ysidro
    334,470,Del Norte & Mendocino
    335,471,Placer & Padova
    336,472,Ellwood Station & San Blanco
    337,473,Calle Real & San Rossano
    338,474,Brandon & Hempstead
    339,475,Brandon & Padova
    340,476,Salisbury & San Napoli
    341,477,Salisbury & Padova
    342,479,Calle Real & Winchester
    343,48,East Valley & Romero Canyon
    344,480,Evergreen & Redwood
    345,481,Brandon & Durham
    346,482,Brandon & Calle Real
    347,483,Placer & Del Norte
    348,484,Del Norte & Calaveras
    349,485,Del Norte & Colusa
    350,49,North Jameson & Sheffield
    351,490,Ocean & Sabado Tarde
    352,492,State & Mason
    353,493,State & Yanonali
    359,50,San Ysidro & San Leandro
    364,504,Cabrillo & Garden
    365,505,Cabrillo & Calle Cesar Chavez
    366,506,Cabrillo & Puerto Vallarta
    367,508,Cabrillo & Milpas
    368,509,Ninos & Por La Mar
    369,51,El Colegio & Camino Corto
    370,510,Cabrillo & Ninos
    371,511,Cabrillo & Chase Palm Park
    372,512,Cabrillo & Anacapa
    373,513,Cabrillo & Chapala
    374,514,Cabrillo & Bath
    375,515,Cabrillo & Castillo
    376,518,North Jameson & Miramar
    378,521,Fairview and Fowler
    379,523,Moffett & Goleta Beach
    383,529,Cathedral Oaks & Via Chaparral
    384,53,San Pascual & Canon Perdido
    385,530,Cathedral Oaks & El Sueno
    386,531,Cathedral Oaks & Camino Del Retiro
    387,533,Cathedral Oaks & San Marcos
    388,534,Cathedral Oaks & Ribera
    389,535,Cathedral Oaks & Patterson
    390,536,Cathedral Oaks & Kellogg
    391,537,Cathedral Oaks & Camino Cascada
    392,538,Cathedral Oaks & Cambridge
    393,539,Cathedral Oaks & Arundel
    394,54,Canon Perdido & San Pascual
    395,540,Cathedral Oaks & Windsor
    396,542,Cathedral Oaks & Camino Laguna Vista
    397,543,Cathedral Oaks & Los Carneros
    398,544,Cathedral Oaks & Glen Annie
    399,546,Cathedral Oaks & Santa Marguerita
    400,547,Cathedral Oaks & Arundel
    401,548,Cathedral Oaks & Avenida Pequena
    402,549,Cathedral Oaks & Camino Del Remedio
    403,55,Las Positas & Richelle
    404,551,La Cumbre & Via La Cumbre
    408,56,Cliff & Mesa
    420,580,East Valley & Live Oaks
    421,581,East Valley & Knowlwood Club
    422,582,State & Mission
    423,584,State & Alamar
    424,590,Alameda & Padova 590
    425,60,Camino Del Sur & Picasso
    426,603,Abrego & Camino Corto
    427,606,Abrego & Camino Del Sur
    428,608,Abrego & Camino Pescadero
    429,609,Alameda & Bassano
    430,610,Anacapa & Canon Perdido
    431,611,Alameda & Padova
    433,613,Anacapa & Figueroa
    435,615,Anapamu & Alta Vista
    436,616,Anapamu & Nopal
    437,618,Anapamu & Garden
    438,620,Bath & Los Olivos
    439,621,Bath & Pueblo
    441,625,Brandon & Evergreen
    442,626,Brandon & Padova
    443,627,Cabrillo & Bath
    444,628,Cabrillo & Chapala
    445,629,Cabrillo & Milpas
    446,63,Haley & De La Vina
    447,630,Cabrillo & Ninos
    448,631,Cabrillo & Puerto Vallarta
    449,632,Calle De los Amigos & Senda Verde
    450,635,Calle Real & Calle Real Center
    451,636,Calle Real & Calle Real Center
    452,637,Calle Real & El Sueno
    453,638,Calle Real & Kellogg
    454,64,Castillo & Montecito
    455,641,Calle Real & Maravilla
    456,642,Calle Real & Pebble Hill
    457,643,Calle Real & Old Mill
    458,651,San Andres & Anapamu
    459,652,San Andres & Micheltorena
    460,653,San Andres & Canon Perdido
    461,655,San Andres & Pedregosa
    462,656,San Andres & Sola
    463,660,Calle Real & Jenna
    464,662,Carpinteria & City Hall
    465,663,Carpinteria & City Hall
    466,664,Carpinteria & Motel 6
    467,665,Carpinteria & Holly
    468,667,Carrillo & Bath
    469,668,Carrillo & Vista Del Pueblo
    470,670,Cathedral Oaks & Cambridge
    471,671,Cathedral Oaks & Camino Cascada
    472,672,Cathedral Oaks & Camino Laguna Vista
    473,673,Cathedral Oaks & El Sueno
    474,674,Cathedral Oaks & Glen Annie
    475,675,Cathedral Oaks & Kellogg
    476,676,Cathedral oaks & Los Carneros
    477,677,Cathedral Oaks & Ribera
    478,678,Cathedral Oaks & San Marcos
    479,679,Cathedral Oaks & Santa Marguerita
    480,680,Cathedral Oaks & Turnpike
    481,681,Cathedral Oaks & Windsor
    483,689,Cliff & La Marina
    485,691,Coast Village & Butterfly
    486,693,Coast Village & Middle
    487,694,Coronel & Wentworth
    489,696,Cota & Garden
    492,699,Cota & Quarantina
    493,7,Montecito & Milpas
    494,700,Cota & Anacapa
    495,701,County Health & Social Services
    496,702,County Health & Social Services
    497,703,County Health
    498,704,County Health & Veteran Clinic
    499,705,County Health & Veteran Clinic
    500,706,De La Guerra & Milpas
    501,707,De La Guerra & Olive
    502,708,De La Guerra & Olive
    503,709,De La Guerra & Quarantina
    504,710,De La Guerra & Quarantina
    505,711,De La Guerra & Salsipuedes
    506,713,East Valley & Glen Oaks
    507,714,East Valley & Hot Springs
    508,715,East Valley & Lilac
    509,716,East Valley & San Ysidro
    510,717,East Valley & Birnam Wood
    511,719,El Colegio & Stadium
    512,720,Ellwood Station & San Blanco
    513,721,Encina & Calle Real
    514,722,Encina Road & Encina Lane
    515,727,Fairview & Fowler
    516,728,Fairview & Carson
    517,730,Foothill & La Colina JHS
    520,75,Rancheria & Gutierrez
    522,753,Hollister & Cannon Green
    525,756,Hollister & Palo Alto
    527,765,Hot Springs & East Valley
    528,766,Hot Springs & Pepper
    529,767,Hot Springs & School House
    530,77,Calle Real & Jenna
    531,771,La Cumbre & Pueblo
    532,772,La Cumbre & Foothill
    533,774,Las Positas & Stanley
    534,776,Ortega Hill & Evans
    535,778,Lillie & Greenwell
    536,78,Brandon & Evergreen
    539,788,Meigs & La Coronilla
    540,789,Meigs & Aurora
    541,79,Hollister & Santa Barbara Shores
    545,795,Micheltorena & State
    549,8,Salinas & Montecito
    556,811,Modoc & La Cumbre Country Club
    557,814,State & Calle Laureles
    559,816,State & Arrellaga
    562,819,State & Constance
    563,82,Cathedral Oaks & Fairview 82
    567,823,State & Hope
    569,825,State & Mason
    573,83,Foothill & Cieneguitas
    574,830,State & Quinto
    575,831,State & Ontare
    577,834,Ocean & Sabado Tarde
    578,836,Olive Mill & Coast Village
    579,838,Olive Mill & Hot Springs
    580,839,Olive Mill & Olive Mill Lane
    581,840,Olive Mill & Hot Springs
    582,846,Rancheria & Gutierrez
    583,85,Hollister & Patterson
    584,856,Salisbury & Padova
    585,858,San Marcos & Calle Real
    586,861,San Onofre & Las Positas
    587,863,San Pascual & Ortega
    588,864,San Ysidro & Monte Vista
    589,865,State & Yanonali
    590,867,San Ysidro & Santa Rosa
    591,868,San Ysidro & Sinaloa
    593,871,Sheffield & Birnam Wood Gate
    594,872,Sheffield & San Leandro
    596,876,Storke & El Colegio
    597,877,Storke & Santa Felicia
    598,879,Storke & Phelps
    600,884,Calle De Los Amigos & Torino
    601,885,Torino & Palermo
    602,887,Treasure & Tallant
    603,890,University & Patterson
    604,891,University & Ribera
    606,893,University & San Marcos
    608,9,Punta Gorda & Salinas
    609,902,Via Real & East Padaro
    610,903,Via Real & Via Real Flowers #3896
    611,904,Via Real & Nidever
    612,905,Via Real & Gallup & Stribling #3450
    613,907,Via Real & Sentar
    614,908,Via Real & Cramer
    615,909,Via Real & Toro Canyon
    616,910,Via Real & West Padaro
    618,912,Casa De Los Flores
    619,919,Milpas & Figueroa
    620,92,Santa Catalina Hall
    621,920,Milpas & Mason
    623,922,Junipero & Calle Real
    624,925,Hollister & Kellogg
    625,926,Hollister & Puente
    626,927,Hollister & San Marcos
    627,928,Hollister & Storke 928
    628,929,Hollister & Viajero
    632,933,Cliff & Meigs
    634,939,Olive Mill & San Benito
    635,940,Calle Real & E Turnpike
    636,941,Calle Real & Turnpike East
    637,942,Calle Real & Kellogg
    638,943,Cathedral Oaks & La Patera
    639,944,Figueroa & Anacapa
    640,945,Figueroa & Santa Barbara
    641,946,Garden & Carrillo
    642,947,Garden & Canon Perdido
    643,948,De La Guerra & Laguna
    644,949,Coast Village & Hot Springs
    645,95,Ortega Hill & Evans
    646,950,North Jameson & La Vuelta
    648,952,Milpas & Cacique
    649,953,Garden & Canon Perdido
    650,954,Via Real & Santa Monica West
    651,955,Lillie & Olive
    652,956,Via Real & Santa Monica
    653,959,Hollister & Entrance
    654,96,Carpinteria & Seventh
    655,960,Hollister & Cathedral Oaks 960
    656,961,Cabrillo & Calle Cesar Chavez
    658,963,Santa Barbara Airport
    659,965,Moffett & Goleta Beach
    660,966,Santa Barbara Airport
    661,97,Carpinteria & Palm
    662,98,Via Real & Mark
    663,99,Carpinteria & Casitas Plaza In
    664,1025,Turnpike & Cathedral Oaks
    665,1036,Fairview & Stow Canyon
    666,1037,Fairview & Berkeley
    667,1082,Modoc & Portesuello
    668,1084,Palermo & Portofino
    669,1086,Castillo & Pershing Park
    670,382,Turnpike & Ukiah
    671,58,Santa Barbara  Jr High School
    672,59,Camino Pescadero & El Colegio 59
    674,647,Camino Pescadero & El Colegio
    675,67,Turnpike & La Gama
    676,68,La Colina JH
    677,69,Rhoads & Ripley
    678,70,Walnut & San Lorenzo
    679,72,Goleta Valley Junior High
    680,726,Fairview & Encina
    681,773,Las Positas & Modoc
    684,810,Modoc & Hacienda
    685,84,San Marcos High School
    686,847,Rhoads & La Roda
    687,848,Rhoads & San Marcos
    688,889,Turnpike & La Gama
    689,89,Palermo & Portofino
    690,90,Modoc & Palmero
    691,914,Walnut & Rhoads
    692,958,Hollister & Pacific Oaks
    779,1045,Hollister & Sumida
    780,126,Anacapa & Anapamu
    781,180,Hollister & Aero Camino
    782,251,State & Alamar
    783,262,Hollister & Puente
    784,264,Hollister & Walnut
    785,266,Hollister & Patterson
    786,271,Hollister & Lopez
    787,273,Hollister & La Patera
    788,274,Hollister & Robin Hill
    789,276,Hollister & Willow Springs
    790,277,Hollister & Los Carneros Way
    791,278,Hollister & Cremona
    792,279,Hollister & Los Carneros Road
    793,28,Hollister & Storke
    794,280,Hollister & Coromar
    795,285,Hollister & Adams
    796,286,Hollister & Hartley
    797,287,Hollister & Griggs
    798,288,Hollister & Fairview
    799,289,Hollister & Pine
    800,290,Hollister & Community Center
    801,293,Hollister & Auhay West
    802,294,Hollister & El Mercado
    803,296,State & De La Vina
    804,371,Storke & Sierra Madre
    805,372,Storke & Whittier
    806,520,Fairview & Carson
    807,752,Hollister & Auhay East
    808,754,Hollister & Coromar
    809,755,Hollister & La Patera
    810,761,Hollister & Walnut
    811,824,State & Highway 154
    812,829,State & Pueblo
    813,87,Hollister & Arboleda
    814,892,State & Valerio
    815,930,Hollister & Ward
    816,931,Hollister & Los Carneros Way
    817,932,Hollister & Los Carneros Road
    899,1089,Via Real & Lomita Lane
    983,1104,Turnpike & San Gordiano
    1067,1003,Cathedral Oaks & Patterson
    1069,1085,La Colina Rd & Pestas Ln (Bishop HS
    1073,1102,Hollister & Village Way
    1074,683,Cieneguitas & Foothill
    1075,684,Cieneguitas & Foothill
    1076,685,Cieneguitas & Primavera
    1077,686,Cieneguitas & Primavera
    1078,843,Primavera & Verano
    1079,898,Verano & Primavera
    1080,899,Verano & San Martin
    1081,900,Verano & San Martin
    1164,1100,Cathedral Oaks and Brandon
    1165,1110,Cliff & Las Positas
    1169,1111,Modoc & Arroyo Verde
    1183,1117,Pueblo & Castillo Cottage Hospital
    1188,1120,UCSB North Hall Inbound
    1189,1121,UCSB Elings Hall Inbound
    1190,1122,Oak Park Ln. & Junipero
    1191,1123,Pueblo & Castillo Cottage Hospital
    1192,1124,State & Hitchcock
    1193,550,Cathedral Oaks & Rancho SB Mob Home
    1197,1125,Los Carneros & Karl Storz Inbound
    1199,1126,Los Carneros & Karl Storz Outbound
    """

    static func load() -> [StopCatalogEntry] {
        if let cached { return cached }
        var sourceText: String?
        if let url = Bundle.main.url(forResource: "stops", withExtension: "txt"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            sourceText = text
        } else {
            sourceText = embeddedCSV
            usedFallback = true
        }
        guard let text = sourceText else { return [] }
        var entries: [StopCatalogEntry] = []
        let lines = text.split(whereSeparator: { "\n\r".contains($0) })
        guard !lines.isEmpty else { return [] }
        // Expect header: stop_id,stop_code,stop_name,...
        for (i, rawLine) in lines.enumerated() {
            if i == 0 { continue } // skip header
            let fields = parseCSVLine(String(rawLine))
            if fields.count < 3 { continue }
            let stopId = fields[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let stopCode = fields[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let stopName = fields[2].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if stopId.isEmpty || stopCode.isEmpty || stopName.isEmpty { continue }
            entries.append(StopCatalogEntry(id: stopId, code: stopCode, name: stopName))
        }

        if entries.isEmpty && !usedFallback {
            // Retry with embedded fallback CSV if bundled file parsed to zero entries
            let fallbackLines = embeddedCSV.split(whereSeparator: { "\n\r".contains($0) })
            for (i, rawLine) in fallbackLines.enumerated() {
                if i == 0 { continue }
                let fields = parseCSVLine(String(rawLine))
                if fields.count < 3 { continue }
                let stopId = fields[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let stopCode = fields[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let stopName = fields[2].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if stopId.isEmpty || stopCode.isEmpty || stopName.isEmpty { continue }
                entries.append(StopCatalogEntry(id: stopId, code: stopCode, name: stopName))
            }
            if !entries.isEmpty { usedFallback = true }
        }

        if entries.isEmpty {
            entries = minimalStops
            usedFallback = true
        }

        // Sort by name for stable UI
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = entries
        return entries
    }

    // Minimal CSV line parser handling commas inside quotes
    private static func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Stop lookup UI
private struct StopLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var entries: [StopCatalogEntry] = StopCatalog.load()

    var body: some View {
        NavigationStack {
            List {
                if StopCatalog.usedFallback {
                    Section {
                        Text("Bus stop numbers are written on the yellow but stop sign.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(filtered(entries)) { e in
                    NavigationLink(destination: StopBoardDetailView(stopId: e.code, title: "#\(e.code) — \(e.name)")) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(.body)
                            Text("#\(e.code)  (ID: \(e.id))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            addToHome(e)
                        } label: {
                            Label("Add to Home", systemImage: "plus")
                        }
                        .tint(.accentColor)
                    }
                }
            }
            .navigationTitle("Find a stop")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name, code, or ID")
        }
    }

    private func filtered(_ list: [StopCatalogEntry]) -> [StopCatalogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return list }
        let qLower = q.lowercased()
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.code.localizedCaseInsensitiveContains(q) ||
            $0.id.lowercased().contains(qLower)
        }
    }
    
    private func addToHome(_ entry: StopCatalogEntry) {
        var stops = loadUserStops()
        if !stops.contains(where: { $0.id == entry.code }) {
            let cfg = UserStopConfig(id: entry.code, label: entry.name, selectedRoutes: [], headsignIncludes: "", enabled: true)
            stops.append(cfg)
            saveUserStops(stops)
        }
    }
}

// MARK: - Stop board detail
private struct StopBoardDetailView: View {
    let stopId: String
    let title: String
    @State private var predictions: [Prediction] = []
    @State private var isRefreshing = false
    @State private var fetchedAt: Date? = nil
    private let provider: DeparturesProvider = SBMTDBusTrackerProvider()

    var body: some View {
        List {
            Section(footer: footerView) {
                if predictions.isEmpty {
                    Text("No predictions found right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(predictions) { p in
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
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { Task { await refresh() } }) {
                    if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .accessibilityLabel("Refresh")
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    @ViewBuilder private var footerView: some View {
        if let ts = fetchedAt {
            ElapsedSinceView(since: ts).padding(.top, 4)
        } else {
            EmptyView()
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let preds = try await provider.fetch(stopId: stopId)
            // No filtering: show complete board sorted by soonest
            let sorted = preds.sorted { (a, b) in (a.minutes ?? 9_999) < (b.minutes ?? 9_999) }
            predictions = sorted
            fetchedAt = Date()
        } catch {
            predictions = []
            fetchedAt = Date()
        }
    }

    private func etaString(_ minutes: Int?) -> String {
        guard let m = minutes else { return "—" }
        if m <= 0 { return "Approaching" }
        if m == 1 { return "1 min" }
        return "\(m) min"
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

