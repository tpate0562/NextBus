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

// NOTE: This code uses CoreLocation for user's location. You must add NSLocationWhenInUseUsageDescription key to Info.plist for location permission prompt.

import SwiftUI
import Combine
import MapKit
import CoreLocation


@MainActor
final class VehicleViewModel: ObservableObject {
    @Published var vehicles: [VehicleLocation] = []
    @Published var errorMessage: String?
    private let service = MTDVehicleService()
    func refresh() {
        guard let url = URL(string: GTFS_RT_URL_STRING) else {
            errorMessage = "Bad GTFS-RT URL"
            return
        }
        service.fetchVehicleLocations(from: url) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let vehicles): self?.vehicles = vehicles
                case .failure(let error): self?.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Location Manager
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    private let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    func request() {
        if CLLocationManager.locationServicesEnabled() == false {
            // Location services disabled at system level; nothing to do here.
            return
        }

        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            // Optionally guide the user to Settings; for now we just don't start updates.
            break
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        @unknown default:
            break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { self.location = loc }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .restricted, .denied, .notDetermined:
            manager.stopUpdatingLocation()
        @unknown default:
            break
        }
    }
}

private struct VehicleAnnotationView: View {
    let route: String
    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 18, height: 18)
            Text(route).font(.caption2).bold().foregroundStyle(.white)
        }
    }
}

// Map view for vehicles
private struct VehicleMapView: View {
    @StateObject private var vm = VehicleViewModel()
    @StateObject private var locManager = LocationManager()
    let title: String
    let routeFilter: String? // if set, only show vehicles whose routeID matches

    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 34.423, longitude: -119.84), span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: .constant(.region(region))) {
                    ForEach(filteredVehicles()) { v in
                        let coord = CLLocationCoordinate2D(latitude: v.latitude, longitude: v.longitude)
                        let routeText = v.routeID ?? "?"
                        Annotation("#\(v.id)", coordinate: coord) {
                            VehicleAnnotationView(route: routeText)
                                .accessibilityLabel("Route \(v.routeID ?? "unknown") vehicle at latitude \(v.latitude), longitude \(v.longitude)")
                        }
                    }
                    // Show the user's current location as a blue pulsing dot
                    if let userLoc = locManager.location {
                        Annotation("My Location", coordinate: userLoc.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 32, height: 32)
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 14, height: 14)
                                Circle()
                                    .stroke(Color.white, lineWidth: 2.5)
                                    .frame(width: 14, height: 14)
                            }
                            .accessibilityLabel("Your current location")
                        }
                    }
                }
                .onChange(of: vm.vehicles) { _ in updateRegionToFit() }
                .task { await autoRefreshLoop() }
                .overlay(alignment: .topTrailing) {
                    VStack(spacing: 10) {
                        Button { vm.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                        Button { centerOnUserLocation() } label: {
                            Image(systemName: "location.fill")
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .topBarLeading) { CloseButton() } }
            .onAppear {
                vm.refresh()
                locManager.request()
            }
        }
    }

    private func filteredVehicles() -> [VehicleLocation] {
        guard let route = routeFilter, !route.isEmpty else { return vm.vehicles }
        return vm.vehicles.filter { ($0.routeID ?? $0.tripID ?? "").localizedCaseInsensitiveContains(route) || ($0.routeID ?? "") == route }
    }

    private func updateRegionToFit() {
        let points = filteredVehicles()
        guard !points.isEmpty else { return }
        var minLat = points.first!.latitude, maxLat = points.first!.latitude
        var minLon = points.first!.longitude, maxLon = points.first!.longitude
        for v in points { minLat = min(minLat, v.latitude); maxLat = max(maxLat, v.latitude); minLon = min(minLon, v.longitude); maxLon = max(maxLon, v.longitude) }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat)/2.0, longitude: (minLon + maxLon)/2.0)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.6), longitudeDelta: max(0.01, (maxLon - minLon) * 1.6))
        region = MKCoordinateRegion(center: center, span: span)
    }

    private func centerOnUserLocation() {
        guard let userLoc = locManager.location else {
            // Re-request in case permissions weren't granted yet
            locManager.request()
            return
        }
        region = MKCoordinateRegion(
            center: userLoc.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    private func autoRefreshLoop() async {
        while true {
            if Task.isCancelled { break }
            vm.refresh()
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
        }
    }
}

private struct CloseButton: View { @Environment(\.dismiss) var dismiss; var body: some View { Button("Close") { dismiss() } } }


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
    @StateObject private var vehiclesVM = VehicleViewModel()
    @StateObject private var locationManager = LocationManager()
    @State private var showingSettings = false
    @State private var showingLookup = false

    @State private var showingEdit = false
    @State private var editingStopId: String? = nil
    @State private var editingKeyword: String = ""

    private enum PresentedMap: Identifiable {
        case all
        case route(String)
        var id: String { switch self { case .all: return "all"; case .route(let r): return "route_\(r)" } }
    }
    @State private var presentedMap: PresentedMap? = nil

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
                                        Text(formattedSubtitle(for: p))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Route \(p.route) to \(p.headsign), \(etaString(p.minutes)).")
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    presentedMap = .route(p.route)
                                }
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
                        Text("Data by Santa Barbara MTD")
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
                    Button(action: { Task { await model.refresh(); vehiclesVM.refresh() } }) {
                        if model.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .accessibilityLabel("Refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { presentedMap = .all }) {
                        Image(systemName: "map")
                    }
                    .accessibilityLabel("Show vehicle map")
                }
            }
            .task {
                // Migrate data from UserDefaults.standard → App Group (one-time)
                migrateUserDefaultsToAppGroupIfNeeded()
                // Backfill stop coordinates for widget distance
                migrateStopCoordinates()

                // Initial fetch
                await model.refresh()
                vehiclesVM.refresh()
                // Start vehicle refresh loop and request location
                vehiclesVM.refresh()
                locationManager.request()

                // Auto-refresh every 30 seconds while the view is active
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    if Task.isCancelled { break }
                    await model.refresh()
                    vehiclesVM.refresh()
                }
            }
            .refreshable {
                await model.refresh()
                vehiclesVM.refresh()
            }
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
            .sheet(item: $presentedMap) { item in
                switch item {
                case .all:
                    VehicleMapView(title: "All Vehicles", routeFilter: nil)
                        .presentationDetents([.large])
                case .route(let r):
                    VehicleMapView(title: "Route #\(r)", routeFilter: r)
                        .presentationDetents([.large])
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


    private func vehicleInfo(for p: Prediction) -> String? {
        guard let vid = p.vehicleID, !vid.isEmpty else { return nil }
        var parts: [String] = ["Vehicle \(vid)"]
        if vid != "SCH", let userLoc = locationManager.location {
#if DEBUG
            print("User location for distance calc: lat=\(userLoc.coordinate.latitude), lon=\(userLoc.coordinate.longitude)")
#endif
            if let match = matchVehicle(by: vid, in: vehiclesVM.vehicles) {
#if DEBUG
                print("Matched vehicle for route #\(p.route) vid=\(vid): lat=\(match.latitude), lon=\(match.longitude)")
#endif
                let vLoc = CLLocation(latitude: match.latitude, longitude: match.longitude)
                let meters = vLoc.distance(from: userLoc)
                let miles = meters / 1609.344
                let km = meters / 1000.0
                let distStr: String
                if Locale.current.usesMetricSystem { distStr = String(format: "%.1f km", km) } else { distStr = String(format: "%.1f mi", miles) }
                parts.append("\(distStr) away")
            }
        }
        return parts.joined(separator: " — ")
    }

    private func formattedSubtitle(for p: Prediction) -> String {
        let eta = etaString(p.minutes)
        guard let vid = p.vehicleID, !vid.isEmpty, vid != "SCH" else {
            return eta
        }
        // Try to compute distance from user to this vehicle (fall back to just vehicle label)
        var distancePart: String? = nil
        if let userLoc = locationManager.location {
#if DEBUG
            print("User location for distance calc: lat=\(userLoc.coordinate.latitude), lon=\(userLoc.coordinate.longitude)")
#endif
            if let match = matchVehicle(by: vid, in: vehiclesVM.vehicles) {
#if DEBUG
                print("Matched vehicle for route #\(p.route) vid=\(vid): lat=\(match.latitude), lon=\(match.longitude)")
#endif
                let vLoc = CLLocation(latitude: match.latitude, longitude: match.longitude)
                let meters = vLoc.distance(from: userLoc)
                let miles = meters / 1609.344
                let km = meters / 1000.0
                if Locale.current.usesMetricSystem {
                    distancePart = String(format: "%.1f km away", km)
                } else {
                    distancePart = String(format: "%.1f mi away", miles)
                }
            }
        }
        if let distancePart = distancePart {
            return "\(eta) - Vehicle \(vid) - \(distancePart)"
        } else {
            return "\(eta) - Vehicle \(vid)"
        }
    }
}

// MARK: - One-time migration: backfill stop coordinates
/// Fills in stopLat/stopLon for any saved UserStopConfig entries that are missing coordinates.
/// Safe to call multiple times; only writes if changes are needed.
private func migrateStopCoordinates() {
    var stops = loadUserStops()
    let needsMigration = stops.contains { $0.stopLat == nil || $0.stopLon == nil }
    guard needsMigration else { return }

    let catalog = StopCatalog.load()
    var changed = false
    for i in stops.indices {
        if stops[i].stopLat == nil || stops[i].stopLon == nil {
            // Try StopCatalog first
            if let entry = catalog.first(where: { $0.code == stops[i].id }), let lat = entry.lat, let lon = entry.lon {
                stops[i].stopLat = lat
                stops[i].stopLon = lon
                changed = true
            }
            // Fallback: direct lookup from stops.txt
            else if let coords = lookupStopCoordinates(stopCode: stops[i].id) {
                stops[i].stopLat = coords.lat
                stops[i].stopLon = coords.lon
                changed = true
            }
        }
    }
    if changed {
        saveUserStops(stops)
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
        var cfg = UserStopConfig(id: id, label: label.isEmpty ? id : label, selectedRoutes: [], headsignIncludes: "", enabled: true)
        // Look up coordinates for widget distance
        if let entry = StopCatalog.load().first(where: { $0.code == id }) {
            cfg.stopLat = entry.lat
            cfg.stopLon = entry.lon
            if cfg.label == id { cfg.label = entry.name } // auto-fill label
        } else if let coords = lookupStopCoordinates(stopCode: id) {
            cfg.stopLat = coords.lat
            cfg.stopLon = coords.lon
        }
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
            // Toggle chips (wrapped using LazyVGrid for simpler layout)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(allRoutes, id: \.self) { r in
                    let isOn = selected.isEmpty || selected.contains(r)
                    Button(action: { toggle(r) }) {
                        Text("#\(r)")
                            .font(.caption)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
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
                        Text("Bus stop numbers are written on the green sign under the phone number.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(filtered(entries)) { e in
                    NavigationLink(destination: StopBoardDetailView(stopId: e.code, title: "#\(e.code) — \(e.name)")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name).font(.body)
                                Text("#\(e.code)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                addToHome(e)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .imageScale(.large)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Add #\(e.code) — \(e.name) to Home")
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
            var cfg = UserStopConfig(id: entry.code, label: entry.name, selectedRoutes: [], headsignIncludes: "", enabled: true)
            cfg.stopLat = entry.lat
            cfg.stopLon = entry.lon
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

    @StateObject private var vehiclesVM = VehicleViewModel()
    @StateObject private var locationManager = LocationManager()

    private enum PresentedMap: Identifiable {
        case all
        case route(String)
        var id: String { switch self { case .all: return "all"; case .route(let r): return "route_\(r)" } }
    }
    @State private var presentedMap: PresentedMap? = nil

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
                                Text(formattedSubtitle(for: p))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Route \(p.route) to \(p.headsign), \(etaString(p.minutes)).")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            presentedMap = .route(p.route)
                        }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { addCurrentStopToHome() }) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to Home")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { presentedMap = .all }) { Image(systemName: "map") }
                    .accessibilityLabel("Show vehicle map")
            }
        }
        .task {
            vehiclesVM.refresh()
            locationManager.request()
            await refresh()
        }
        .refreshable { await refresh() }
        .sheet(item: $presentedMap) { item in
            switch item {
            case .all:
                VehicleMapView(title: "All Vehicles", routeFilter: nil)
                    .presentationDetents([.large])
            case .route(let r):
                VehicleMapView(title: "Route #\(r)", routeFilter: r)
                    .presentationDetents([.large])
            }
        }
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
            vehiclesVM.refresh()
        } catch {
            predictions = []
            fetchedAt = Date()
            vehiclesVM.refresh()
        }
    }

    private func addCurrentStopToHome() {
        var stops = loadUserStops()
        if !stops.contains(where: { $0.id == stopId }) {
            let label = title
            let cfg = UserStopConfig(id: stopId, label: label, selectedRoutes: [], headsignIncludes: "", enabled: true)
            stops.append(cfg)
            saveUserStops(stops)
        }
    }

    private func etaString(_ minutes: Int?) -> String {
        guard let m = minutes else { return "—" }
        if m <= 0 { return "Approaching" }
        if m == 1 { return "1 min" }
        return "\(m) min"
    }


    private func vehicleInfo(for p: Prediction) -> String? {
        guard let vid = p.vehicleID, !vid.isEmpty else { return nil }
        var parts: [String] = ["Vehicle \(vid)"]
        if vid != "SCH", let userLoc = locationManager.location {
#if DEBUG
            print("User location for distance calc: lat=\(userLoc.coordinate.latitude), lon=\(userLoc.coordinate.longitude)")
#endif
            if let match = matchVehicle(by: vid, in: vehiclesVM.vehicles) {
#if DEBUG
                print("Matched vehicle for route #\(p.route) vid=\(vid): lat=\(match.latitude), lon=\(match.longitude)")
#endif
                let vLoc = CLLocation(latitude: match.latitude, longitude: match.longitude)
                let meters = vLoc.distance(from: userLoc)
                let miles = meters / 1609.344
                let km = meters / 1000.0
                let distStr: String
                if Locale.current.usesMetricSystem { distStr = String(format: "%.1f km", km) } else { distStr = String(format: "%.1f mi", miles) }
                parts.append("\(distStr) away")
            }
        }
        return parts.joined(separator: " — ")
    }

    private func formattedSubtitle(for p: Prediction) -> String {
        let eta = etaString(p.minutes)
        guard let vid = p.vehicleID, !vid.isEmpty, vid != "SCH" else {
            return eta
        }
        var distancePart: String? = nil
        if let userLoc = locationManager.location {
#if DEBUG
            print("User location for distance calc: lat=\(userLoc.coordinate.latitude), lon=\(userLoc.coordinate.longitude)")
#endif
            if let match = matchVehicle(by: vid, in: vehiclesVM.vehicles) {
#if DEBUG
                print("Matched vehicle for route #\(p.route) vid=\(vid): lat=\(match.latitude), lon=\(match.longitude)")
#endif
                let vLoc = CLLocation(latitude: match.latitude, longitude: match.longitude)
                let meters = vLoc.distance(from: userLoc)
                let miles = meters / 1609.344
                let km = meters / 1000.0
                if Locale.current.usesMetricSystem {
                    distancePart = String(format: "%.1f km away", km)
                } else {
                    distancePart = String(format: "%.1f mi away", miles)
                }
            }
        }
        if let distancePart = distancePart {
            return "\(eta) - Vehicle \(vid) - \(distancePart)"
        } else {
            return "\(eta) - Vehicle \(vid)"
        }
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

