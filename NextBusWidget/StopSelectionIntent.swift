//
//  StopSelectionIntent.swift
//  NextBusWidget
//
//  AppIntent-based configuration for widget stop selection (iOS 17+).
//

import AppIntents
import WidgetKit

// MARK: - Time display style

enum TimeDisplayStyle: String, AppEnum {
    case minutesUntil
    case departureTime

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Time Display")
    static var caseDisplayRepresentations: [TimeDisplayStyle: DisplayRepresentation] = [
        .minutesUntil: "Minutes Until",
        .departureTime: "Departure Time"
    ]
}

// MARK: - Large widget layout

enum LargeWidgetLayout: String, AppEnum {
    case twoColumnFull
    case fourStopGrid

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Layout")
    static var caseDisplayRepresentations: [LargeWidgetLayout: DisplayRepresentation] = [
        .twoColumnFull: "2 Stops (Full Board)",
        .fourStopGrid: "4 Stops (Grid)"
    ]
}

// MARK: - Bus stop entity

struct BusStopEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bus Stop")
    static var defaultQuery = BusStopQuery()

    var id: String
    var label: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "Stop #\(id)")
    }
}

struct BusStopQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [BusStopEntity] {
        let stops = loadUserStops()
        return identifiers.compactMap { id in
            guard let stop = stops.first(where: { $0.id == id }) else { return nil }
            return BusStopEntity(id: stop.id, label: stop.label)
        }
    }

    func suggestedEntities() async throws -> [BusStopEntity] {
        return loadUserStops()
            .filter { $0.enabled }
            .map { BusStopEntity(id: $0.id, label: $0.label) }
    }

    func defaultResult() async -> BusStopEntity? {
        return loadUserStops()
            .filter { $0.enabled }
            .first
            .map { BusStopEntity(id: $0.id, label: $0.label) }
    }
}

// MARK: - Widget Intents

struct SmallWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Bus Stop"
    static var description = IntentDescription("Choose a bus stop to display on the widget.")

    @Parameter(title: "Bus Stop")
    var stop: BusStopEntity?

    @Parameter(title: "Time Display", default: .minutesUntil)
    var timeDisplay: TimeDisplayStyle
}

struct MediumWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Bus Stops"
    static var description = IntentDescription("Choose two bus stops to display.")

    @Parameter(title: "First Stop")
    var stop1: BusStopEntity?

    @Parameter(title: "Second Stop")
    var stop2: BusStopEntity?

    @Parameter(title: "Time Display", default: .minutesUntil)
    var timeDisplay: TimeDisplayStyle
}

struct LargeWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Configure Large Widget"
    static var description = IntentDescription("Choose stops and layout for the large widget.")

    @Parameter(title: "Layout", default: .fourStopGrid)
    var layout: LargeWidgetLayout

    @Parameter(title: "First Stop")
    var stop1: BusStopEntity?

    @Parameter(title: "Second Stop")
    var stop2: BusStopEntity?

    @Parameter(title: "Third Stop")
    var stop3: BusStopEntity?

    @Parameter(title: "Fourth Stop")
    var stop4: BusStopEntity?

    @Parameter(title: "Time Display", default: .minutesUntil)
    var timeDisplay: TimeDisplayStyle
}
