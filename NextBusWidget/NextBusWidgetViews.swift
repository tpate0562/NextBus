//
//  NextBusWidgetViews.swift
//  NextBusWidget
//
//  Widget view layouts for small, medium, and large bus departure widgets.
//

import SwiftUI
import WidgetKit

// MARK: - Time Formatter

private let widgetTimeFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "h:mm a"
    return fmt
}()

// MARK: - Departure Row View

/// A single departure row showing clock+time, route number, and pin+distance.
struct DepartureRowView: View {
    let departure: DepartureInfo
    let timeStyle: TimeDisplayStyle
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 6) {
            // Time
            HStack(spacing: 2) {
                Image(systemName: "clock")
                    .font(.system(size: compact ? 9 : 12))
                    .foregroundStyle(.secondary)
                Text(timeText)
                    .font(.system(size: compact ? 10 : 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Route badge with official SBMTD color
            let color = sbmtdRouteColor(for: departure.route)
            Text(departure.route)
                .font(.system(size: compact ? 11 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 4 : 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                )

            // Distance (bus to stop)
            HStack(spacing: 2) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: compact ? 9 : 12))
                    .foregroundStyle(.secondary)
                Text(distanceText)
                    .font(.system(size: compact ? 10 : 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var timeText: String {
        switch timeStyle {
        case .minutesUntil:
            guard let m = departure.minutes else { return "—" }
            if m <= 0 { return "Now" }
            return "\(m) min"
        case .departureTime:
            guard let date = departure.departureDate else { return "—" }
            return widgetTimeFormatter.string(from: date)
        }
    }

    private var distanceText: String {
        guard let d = departure.distanceMiles else {
            // Temporary: show debug info to diagnose
            return departure.debugInfo.isEmpty ? "—" : departure.debugInfo
        }
        if d < 0.1 { return "<0.1" }
        return String(format: "%.1f", d)
    }
}

// MARK: - Stop Column View

/// Displays a stop name and its departures in a vertical column.
struct StopColumnView: View {
    let stopData: StopDepartureData
    let timeStyle: TimeDisplayStyle
    let compact: Bool
    let showHeadsign: Bool
    var refreshDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 0) {
                Text(stopData.stopLabel)
                    .font(compact ? .system(size: 11, weight: .semibold) : .system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                Spacer(minLength: 2)
                if let date = refreshDate {
                    RefreshTimestamp(date: date)
                }
            }

            if stopData.departures.isEmpty {
                Text("No departures")
                    .font(compact ? .system(size: 9) : .caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else {
                ForEach(stopData.departures) { dep in
                    VStack(spacing: 0) {
                        DepartureRowView(departure: dep, timeStyle: timeStyle, compact: compact)
                        if showHeadsign {
                            Text("→ \(dep.headsign)")
                                .font(.system(size: compact ? 8 : 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Refresh Timestamp

/// Tiny auto-updating time-since-refresh indicator for the top-left corner.
struct RefreshTimestamp: View {
    let date: Date

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8, weight: .medium))
            Text(date, style: .timer)
                .font(.system(size: 8, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .lineLimit(1)
    }
}

// MARK: - Empty Widget Placeholder

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bus.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a stop")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Long-press to configure")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: NextBusEntry

    var body: some View {
        if let stop = entry.stops.first {
            StopColumnView(
                stopData: stop,
                timeStyle: entry.timeDisplayStyle,
                compact: false,
                showHeadsign: false,
                refreshDate: entry.date
            )
            .padding(.horizontal, -5)
        } else {
            EmptyWidgetView()
        }
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: NextBusEntry

    var body: some View {
        if entry.stops.isEmpty {
            EmptyWidgetView()
        } else {
            HStack(spacing: 0) {
                if let first = entry.stops.first {
                    StopColumnView(
                        stopData: first,
                        timeStyle: entry.timeDisplayStyle,
                        compact: false,
                        showHeadsign: false,
                        refreshDate: entry.date
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 4)
                }

                if entry.stops.count >= 2 {
                    Divider()
                        .padding(.vertical, 4)

                    StopColumnView(
                        stopData: entry.stops[1],
                        timeStyle: entry.timeDisplayStyle,
                        compact: false,
                        showHeadsign: false
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Large Widget View

struct LargeWidgetView: View {
    let entry: NextBusEntry

    var body: some View {
        if entry.stops.isEmpty {
            EmptyWidgetView()
        } else if entry.layoutStyle == .twoColumnFull {
            twoColumnFullLayout
        } else {
            fourStopGridLayout
        }
    }

    // Option A: Two columns with full departure info including headsign
    private var twoColumnFullLayout: some View {
        HStack(spacing: 0) {
            if let first = entry.stops.first {
                StopColumnView(
                    stopData: first,
                    timeStyle: entry.timeDisplayStyle,
                    compact: false,
                    showHeadsign: true,
                    refreshDate: entry.date
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.trailing, 4)
            }

            if entry.stops.count >= 2 {
                Divider()
                    .padding(.vertical, 4)

                StopColumnView(
                    stopData: entry.stops[1],
                    timeStyle: entry.timeDisplayStyle,
                    compact: false,
                    showHeadsign: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 2)
    }

    // Option B: 2×2 grid showing 4 stops
    private var fourStopGridLayout: some View {
        VStack(spacing: 0) {
            // Top row
            HStack(spacing: 0) {
                if entry.stops.count > 0 {
                    StopColumnView(
                        stopData: entry.stops[0],
                        timeStyle: entry.timeDisplayStyle,
                        compact: true,
                        showHeadsign: false,
                        refreshDate: entry.date
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, 4)
                }

                if entry.stops.count > 1 {
                    Divider().padding(.vertical, 2)

                    StopColumnView(
                        stopData: entry.stops[1],
                        timeStyle: entry.timeDisplayStyle,
                        compact: true,
                        showHeadsign: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 4)
                }
            }
            .frame(maxHeight: .infinity)

            if entry.stops.count > 2 {
                Divider().padding(.horizontal, 2)

                // Bottom row
                HStack(spacing: 0) {
                    StopColumnView(
                        stopData: entry.stops[2],
                        timeStyle: entry.timeDisplayStyle,
                        compact: true,
                        showHeadsign: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.trailing, 4)

                    if entry.stops.count > 3 {
                        Divider().padding(.vertical, 2)

                        StopColumnView(
                            stopData: entry.stops[3],
                            timeStyle: entry.timeDisplayStyle,
                            compact: true,
                            showHeadsign: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 4)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Widget Definitions

struct NextBusSmallWidget: Widget {
    let kind: String = "NextBusSmallWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SmallWidgetIntent.self, provider: SmallWidgetProvider()) { entry in
            SmallWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bus Stop")
        .description("Next 3 departures for one stop.")
        .supportedFamilies([.systemSmall])
    }
}

struct NextBusMediumWidget: Widget {
    let kind: String = "NextBusMediumWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: MediumWidgetIntent.self, provider: MediumWidgetProvider()) { entry in
            MediumWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Two Stops")
        .description("Next 5 departures for two stops.")
        .supportedFamilies([.systemMedium])
    }
}

struct NextBusLargeWidget: Widget {
    let kind: String = "NextBusLargeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LargeWidgetIntent.self, provider: LargeWidgetProvider()) { entry in
            LargeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Departure Board")
        .description("Full departure board for up to 4 stops.")
        .supportedFamilies([.systemLarge])
    }
}
