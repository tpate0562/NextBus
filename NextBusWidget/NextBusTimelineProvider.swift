//
//  NextBusTimelineProvider.swift
//  NextBusWidget
//
//  Timeline providers and entry models for the NextBus widgets.
//

import WidgetKit
import CoreLocation

// MARK: - Widget Entry Models

struct StopDepartureData {
    let stopLabel: String
    let departures: [DepartureInfo]
}

struct DepartureInfo: Identifiable {
    let id = UUID()
    let route: String
    let headsign: String
    let minutes: Int?
    let departureDate: Date?
    let distanceMiles: Double?  // distance from bus to the stop
    let debugInfo: String       // temporary: shows why distance is missing
}

struct NextBusEntry: TimelineEntry {
    let date: Date
    let stops: [StopDepartureData]
    let timeDisplayStyle: TimeDisplayStyle
    let layoutStyle: LargeWidgetLayout

    static let placeholder = NextBusEntry(
        date: Date(),
        stops: [
            StopDepartureData(stopLabel: "Storke & Sierra Madre", departures: [
                DepartureInfo(route: "11", headsign: "Downtown SB", minutes: 5, departureDate: Date().addingTimeInterval(300), distanceMiles: 1.2, debugInfo: ""),
                DepartureInfo(route: "27", headsign: "UCSB North Hall", minutes: 12, departureDate: Date().addingTimeInterval(720), distanceMiles: 2.4, debugInfo: ""),
                DepartureInfo(route: "28", headsign: "Camino Real Mkt", minutes: 19, departureDate: Date().addingTimeInterval(1140), distanceMiles: 3.1, debugInfo: ""),
            ])
        ],
        timeDisplayStyle: .minutesUntil,
        layoutStyle: .fourStopGrid
    )

    static let emptyPlaceholder = NextBusEntry(
        date: Date(),
        stops: [],
        timeDisplayStyle: .minutesUntil,
        layoutStyle: .fourStopGrid
    )
}

// MARK: - Shared Fetch Logic

/// Fetches departure predictions and bus-to-stop distances for the given stop IDs.
func fetchDeparturesForWidget(stopIDs: [String], maxPerStop: Int = 3) async -> [StopDepartureData] {
    let provider = SBMTDBusTrackerProvider()

    // Fetch vehicle locations for distance calculation
    var vehicleLocations: [VehicleLocation] = []
    if let url = URL(string: GTFS_RT_URL_STRING) {
        vehicleLocations = await withCheckedContinuation { continuation in
            MTDVehicleService().fetchVehicleLocations(from: url) { result in
                switch result {
                case .success(let vehicles): continuation.resume(returning: vehicles)
                case .failure: continuation.resume(returning: [])
                }
            }
        }
    }

    let savedStops = loadUserStops()

    var results: [StopDepartureData] = []

    for stopID in stopIDs {
        let config = savedStops.first(where: { $0.id == stopID })
        let label = config?.label ?? "Stop #\(stopID)"

        // Get stop coordinates for bus-to-stop distance
        // Try config first (backfilled by main app migration), then fallback to stops.txt in bundle
        let stopLocation: CLLocation? = {
            if let lat = config?.stopLat, let lon = config?.stopLon {
                return CLLocation(latitude: lat, longitude: lon)
            }
            // Fallback: look up from bundled stops.txt
            if let coords = lookupStopCoordinates(stopCode: stopID) {
                return CLLocation(latitude: coords.lat, longitude: coords.lon)
            }
            return nil
        }()

        do {
            var predictions = try await provider.fetch(stopId: stopID)

            // Apply per-stop route filter
            if let config = config, !config.selectedRoutes.isEmpty {
                predictions = predictions.filter { config.selectedRoutes.contains($0.route) }
            }

            // Apply headsign filter
            if let config = config {
                let filter = config.headsignIncludes.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !filter.isEmpty {
                    predictions = predictions.filter { $0.headsign.lowercased().contains(filter) }
                }
            }

            let sorted = predictions.sorted { ($0.minutes ?? 9999) < ($1.minutes ?? 9999) }

            let departures: [DepartureInfo] = Array(sorted.prefix(maxPerStop)).map { p in
                // Calculate bus distance TO THE STOP (not to the user)
                var dist: Double? = nil
                var debug = ""

                let vid = p.vehicleID
                if vid == nil {
                    debug = "no vid"
                } else if vid == "SCH" {
                    debug = "SCH"
                } else if stopLocation == nil {
                    debug = "no coords"
                } else if vehicleLocations.isEmpty {
                    debug = "0 veh"
                } else {
                    if let veh = matchVehicle(by: vid!, in: vehicleLocations) {
                        let vLoc = CLLocation(latitude: veh.latitude, longitude: veh.longitude)
                        dist = vLoc.distance(from: stopLocation!) / 1609.344
                        debug = String(format: "%.1f mi", dist!)
                    } else {
                        debug = "no match:\(vid!)"
                    }
                }

                return DepartureInfo(
                    route: p.route,
                    headsign: p.headsign,
                    minutes: p.minutes,
                    departureDate: p.minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) },
                    distanceMiles: dist,
                    debugInfo: debug
                )
            }

            results.append(StopDepartureData(stopLabel: label, departures: departures))
        } catch {
            results.append(StopDepartureData(stopLabel: label, departures: []))
        }
    }

    return results
}

// MARK: - Small Widget Provider

struct SmallWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NextBusEntry { .placeholder }

    func snapshot(for configuration: SmallWidgetIntent, in context: Context) async -> NextBusEntry {
        if context.isPreview { return .placeholder }
        return await makeEntry(for: configuration)
    }

    func timeline(for configuration: SmallWidgetIntent, in context: Context) async -> Timeline<NextBusEntry> {
        let entry = await makeEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
    }

    private func makeEntry(for config: SmallWidgetIntent) async -> NextBusEntry {
        guard let stop = config.stop else { return .emptyPlaceholder }
        let data = await fetchDeparturesForWidget(stopIDs: [stop.id], maxPerStop: 5)
        return NextBusEntry(date: Date(), stops: data, timeDisplayStyle: config.timeDisplay, layoutStyle: .fourStopGrid)
    }
}

// MARK: - Medium Widget Provider

struct MediumWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NextBusEntry { .placeholder }

    func snapshot(for configuration: MediumWidgetIntent, in context: Context) async -> NextBusEntry {
        if context.isPreview { return .placeholder }
        return await makeEntry(for: configuration)
    }

    func timeline(for configuration: MediumWidgetIntent, in context: Context) async -> Timeline<NextBusEntry> {
        let entry = await makeEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
    }

    private func makeEntry(for config: MediumWidgetIntent) async -> NextBusEntry {
        let ids = [config.stop1?.id, config.stop2?.id].compactMap { $0 }
        guard !ids.isEmpty else { return .emptyPlaceholder }
        let data = await fetchDeparturesForWidget(stopIDs: ids, maxPerStop: 5)
        return NextBusEntry(date: Date(), stops: data, timeDisplayStyle: config.timeDisplay, layoutStyle: .fourStopGrid)
    }
}

// MARK: - Large Widget Provider

struct LargeWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NextBusEntry { .placeholder }

    func snapshot(for configuration: LargeWidgetIntent, in context: Context) async -> NextBusEntry {
        if context.isPreview { return .placeholder }
        return await makeEntry(for: configuration)
    }

    func timeline(for configuration: LargeWidgetIntent, in context: Context) async -> Timeline<NextBusEntry> {
        let entry = await makeEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
    }

    private func makeEntry(for config: LargeWidgetIntent) async -> NextBusEntry {
        let maxStops = config.layout == .twoColumnFull ? 2 : 4
        let ids = Array([config.stop1?.id, config.stop2?.id, config.stop3?.id, config.stop4?.id]
            .compactMap { $0 }
            .prefix(maxStops))
        guard !ids.isEmpty else { return .emptyPlaceholder }
        let data = await fetchDeparturesForWidget(stopIDs: ids, maxPerStop: 5)
        return NextBusEntry(date: Date(), stops: data, timeDisplayStyle: config.timeDisplay, layoutStyle: config.layout)
    }
}
