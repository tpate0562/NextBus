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
import MapKit
import Compression

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

fileprivate let GTFS_RT_URL_STRING = "https://bustracker.sbmtd.gov/gtfsrt/vehicles" // TODO: replace with real GTFS-RT VehiclePositions URL

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

// MARK: - Vehicle locations (GTFS-RT manual decoder)

// Public model
struct VehicleLocation: Identifiable, Equatable {
    let id: String
    let routeID: String?
    let tripID: String?
    let latitude: Double
    let longitude: Double
    let bearing: Double?
    let speedMetersPerSecond: Double?
    let timestamp: Date?

    var coordinates: (Double, Double) { (latitude, longitude) }
}

fileprivate let _iso8601Fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

fileprivate func debugDumpVehicles(_ vehicles: [VehicleLocation]) {
#if DEBUG
    print("\n===== GTFS-RT VehiclePositions decoded: \(vehicles.count) vehicles =====")
    for v in vehicles {
        let ts = v.timestamp.map { _iso8601Fractional.string(from: $0) } ?? "nil"
        let bearingStr = v.bearing.map { String(format: "%.0f°", $0) } ?? "nil"
        let speedMS = v.speedMetersPerSecond.map { String(format: "%.1f m/s", $0) } ?? "nil"
        let speedMPH = v.speedMetersPerSecond.map { String(format: "%.1f mph", $0 * 2.236936) } ?? "nil"
        let latStr = String(format: "%.6f", v.latitude)
        let lonStr = String(format: "%.6f", v.longitude)
        print("id=\(v.id) route=\(v.routeID ?? "nil") trip=\(v.tripID ?? "nil") lat=\(latStr) lon=\(lonStr) bearing=\(bearingStr) speed=\(speedMS) (\(speedMPH)) ts=\(ts)")
    }
    print("===== END GTFS-RT dump =====\n")
#endif
}

// Internal message models (minimal GTFS-RT subset)
private struct Position { var latitude: Double?; var longitude: Double?; var bearing: Double?; var speed: Double? }
private struct TripDescriptor { var tripID: String?; var routeID: String? }
private struct VehicleDescriptor { var id: String? }
private struct VehiclePositionMessage { var trip: TripDescriptor?; var position: Position?; var vehicle: VehicleDescriptor?; var timestamp: UInt64? }
private struct FeedEntity { var id: String?; var vehicle: VehiclePositionMessage? }

// Minimal Protobuf reader
private struct ProtobufReader {
    let data: Data
    private(set) var offset: Int = 0
    var isAtEnd: Bool { offset >= data.count }
    init(data: Data) { self.data = data }
    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count && shift < 64 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
        }
        return nil
    }
    mutating func readFixed32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let slice = data[offset ..< offset + 4]
        offset += 4
        var value: UInt32 = 0
        for (i, b) in slice.enumerated() { value |= UInt32(b) << (8 * i) }
        return value
    }
    mutating func readLengthDelimited() -> Data? {
        guard let len64 = readVarint() else { return nil }
        let len = Int(len64)
        guard offset + len <= data.count else { return nil }
        let sub = data.subdata(in: offset ..< offset + len)
        offset += len
        return sub
    }
    mutating func readString() -> String? { guard let bytes = readLengthDelimited() else { return nil }; return String(data: bytes, encoding: .utf8) }
    mutating func readKey() -> (fieldNumber: Int, wireType: Int)? {
        guard let key = readVarint() else { return nil }
        let wireType = Int(key & 0x7)
        let fieldNumber = Int(key >> 3)
        return (fieldNumber, wireType)
    }
    mutating func skipField(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: offset = min(data.count, offset + 8)
        case 2: if let len64 = readVarint() { let len = Int(len64); offset = min(data.count, offset + len) }
        case 5: offset = min(data.count, offset + 4)
        default: break
        }
    }
}

// Parsers for GTFS-RT subset
private func parsePosition(_ data: Data) -> Position {
    var reader = ProtobufReader(data: data)
    var position = Position()
    while let (field, wire) = reader.readKey() {
        switch field {
        case 1: // latitude (float, fixed32)
            if wire == 5, let bits = reader.readFixed32() { position.latitude = Double(Float(bitPattern: bits)) } else { reader.skipField(wireType: wire) }
        case 2: // longitude (float, fixed32)
            if wire == 5, let bits = reader.readFixed32() { position.longitude = Double(Float(bitPattern: bits)) } else { reader.skipField(wireType: wire) }
        case 3: // bearing (float, fixed32)
            if wire == 5, let bits = reader.readFixed32() { position.bearing = Double(Float(bitPattern: bits)) } else { reader.skipField(wireType: wire) }
        case 4: // odometer (double, fixed64) — not used here; skip
            reader.skipField(wireType: wire)
        case 5: // speed (float, fixed32)
            if wire == 5, let bits = reader.readFixed32() { position.speed = Double(Float(bitPattern: bits)) } else { reader.skipField(wireType: wire) }
        default:
            reader.skipField(wireType: wire)
        }
    }
    return position
}

private func parseTripDescriptor(_ data: Data) -> TripDescriptor {
    var reader = ProtobufReader(data: data)
    var trip = TripDescriptor()
    while let (field, wire) = reader.readKey() {
        switch field {
        case 1: if wire == 2 { trip.tripID = reader.readString() } else { reader.skipField(wireType: wire) }
        case 5: if wire == 2 { trip.routeID = reader.readString() } else { reader.skipField(wireType: wire) }
        default: reader.skipField(wireType: wire)
        }
    }
    return trip
}

private func parseVehicleDescriptor(_ data: Data) -> VehicleDescriptor {
    var reader = ProtobufReader(data: data)
    var vehicle = VehicleDescriptor()
    while let (field, wire) = reader.readKey() {
        switch field {
        case 1: if wire == 2 { vehicle.id = reader.readString() } else { reader.skipField(wireType: wire) }
        default: reader.skipField(wireType: wire)
        }
    }
    return vehicle
}

private func parseVehiclePosition(_ data: Data) -> VehiclePositionMessage {
    var reader = ProtobufReader(data: data)
    var vp = VehiclePositionMessage()
    while let (field, wire) = reader.readKey() {
        switch field {
        case 1: // trip
            if wire == 2, let sub = reader.readLengthDelimited() { vp.trip = parseTripDescriptor(sub) } else { reader.skipField(wireType: wire) }
        case 2: // position
            if wire == 2, let sub = reader.readLengthDelimited() { vp.position = parsePosition(sub) } else { reader.skipField(wireType: wire) }
        case 5: // timestamp (varint)
            if wire == 0, let ts = reader.readVarint() { vp.timestamp = ts } else { reader.skipField(wireType: wire) }
        case 8: // vehicle descriptor
            if wire == 2, let sub = reader.readLengthDelimited() { vp.vehicle = parseVehicleDescriptor(sub) } else { reader.skipField(wireType: wire) }
        default:
            reader.skipField(wireType: wire)
        }
    }
    return vp
}

private func parseFeedEntity(_ data: Data) -> FeedEntity {
    var reader = ProtobufReader(data: data)
    var entity = FeedEntity()
    while let (field, wire) = reader.readKey() {
        switch field {
        case 1: // id
            if wire == 2 { entity.id = reader.readString() } else { reader.skipField(wireType: wire) }
        case 4: // vehicle (length-delimited, field 4)
            if wire == 2, let sub = reader.readLengthDelimited() { entity.vehicle = parseVehiclePosition(sub) } else { reader.skipField(wireType: wire) }
        default:
            reader.skipField(wireType: wire)
        }
    }
    return entity
}

// Public decoder
enum GTFSRTManualDecoder {
    static func decodeVehicles(from data: Data) -> [VehicleLocation] {
        var reader = ProtobufReader(data: data)
        var locations: [VehicleLocation] = []
        while let (field, wire) = reader.readKey() {
            if field == 2 && wire == 2, let entityData = reader.readLengthDelimited() {
                let entity = parseFeedEntity(entityData)
                guard let vp = entity.vehicle, let pos = vp.position, let lat = pos.latitude, let lon = pos.longitude else { continue }
                let vehID = vp.vehicle?.id ?? entity.id ?? ""
                let routeID = vp.trip?.routeID
                let tripID = vp.trip?.tripID
                let bearing = pos.bearing
                let speed = pos.speed
                let tsDate: Date? = vp.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let location = VehicleLocation(id: vehID, routeID: routeID, tripID: tripID, latitude: lat, longitude: lon, bearing: bearing, speedMetersPerSecond: speed, timestamp: tsDate)
                locations.append(location)
            } else {
                reader.skipField(wireType: wire)
            }
        }
        return locations
    }
}

// Optional: gunzip helper for raw gzip payloads without Content-Encoding
private func gunzipIfNeeded(_ data: Data) -> Data {
    // gzip magic header 0x1f 0x8b
    guard data.count >= 2, data[0] == 0x1f, data[1] == 0x8b else { return data }

    var decoded = Data()

    var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!, src_size: 0, state: nil)
    var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
    guard status != COMPRESSION_STATUS_ERROR else { return data }
    defer { compression_stream_destroy(&stream) }

    return data.withUnsafeBytes { (srcBuf: UnsafeRawBufferPointer) in
        var srcIndex = 0
        decoded.removeAll(keepingCapacity: true)

        while srcIndex < data.count {
            let srcChunk = min(64 * 1024, data.count - srcIndex)
            stream.src_ptr = srcBuf.baseAddress!.advanced(by: srcIndex).assumingMemoryBound(to: UInt8.self)
            stream.src_size = srcChunk
            srcIndex += srcChunk

            var dstData = Data(count: 64 * 1024)
            dstData.withUnsafeMutableBytes { dstBuf in
                stream.dst_ptr = dstBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = dstBuf.count

                while true {
                    status = compression_stream_process(&stream, srcIndex >= data.count ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = dstBuf.count - stream.dst_size
                    if produced > 0 {
                        if let base = dstBuf.bindMemory(to: UInt8.self).baseAddress { decoded.append(base, count: produced) }
                        stream.dst_ptr = dstBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        stream.dst_size = dstBuf.count
                    }
                    if status == COMPRESSION_STATUS_OK && stream.src_size == 0 {
                        break // need more input
                    } else if status == COMPRESSION_STATUS_END {
                        return
                    } else if status == COMPRESSION_STATUS_ERROR {
                        decoded.removeAll()
                        return
                    }
                }
            }
        }
        return decoded.isEmpty ? data : decoded
    }
}

final class MTDVehicleService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func fetchVehicleLocations(from url: URL, completion: @escaping (Result<[VehicleLocation], Error>) -> Void) {
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error { completion(.failure(error)); return }
#if DEBUG
            if let http = response as? HTTPURLResponse {
                let lenHeader = http.value(forHTTPHeaderField: "Content-Length") ?? "(none)"
                print("GTFS-RT fetch: status=\(http.statusCode) mime=\(http.mimeType ?? "nil") content-length=\(lenHeader)")
            } else {
                print("GTFS-RT fetch: non-HTTP response")
            }
#endif
            guard let data = data else {
                let err = NSError(domain: "MTDVehicleService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data"])
                completion(.failure(err)); return
            }

            // Try decode as-is
            var vehicles = GTFSRTManualDecoder.decodeVehicles(from: data)

            // Fallback: gunzip if the payload appears to be gzipped without Content-Encoding
            if vehicles.isEmpty {
                let unzipped = gunzipIfNeeded(data)
                if unzipped != data {
                    vehicles = GTFSRTManualDecoder.decodeVehicles(from: unzipped)
                }
            }

#if DEBUG
            if vehicles.isEmpty {
                let prefix = data.prefix(24)
                print("GTFS-RT decode yielded 0 vehicles. First 24 bytes: \(prefix.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
            debugDumpVehicles(vehicles)
#endif
            completion(.success(vehicles))
        }
        task.resume()
    }
}

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
                        Annotation("#\(routeText)", coordinate: coord) {
                            VehicleAnnotationView(route: routeText)
                                .accessibilityLabel("Route \(v.routeID ?? "unknown") vehicle at latitude \(v.latitude), longitude \(v.longitude)")
                        }
                    }
                }
                .onChange(of: vm.vehicles) { _ in updateRegionToFit() }
                .task { await autoRefreshLoop() }
                .overlay(alignment: .topTrailing) {
                    Button { vm.refresh() } label: {
                        Image(systemName: "arrow.clockwise").padding(8).background(.thinMaterial).clipShape(Circle())
                    }.padding()
                }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .topBarLeading) { CloseButton() } }
            .onAppear { vm.refresh() }
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

    private func autoRefreshLoop() async {
        while true {
            if Task.isCancelled { break }
            vm.refresh()
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
        }
    }
}

private struct CloseButton: View { @Environment(\.dismiss) var dismiss; var body: some View { Button("Close") { dismiss() } } }

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
                                        Text(etaString(p.minutes))
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { presentedMap = .all }) {
                        Image(systemName: "map")
                    }
                    .accessibilityLabel("Show vehicle map")
                }
            }
            .task {
                // Initial fetch
                await model.refresh()
                // Auto-refresh every 30 seconds while the view is active
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    if Task.isCancelled { break }
                    await model.refresh()
                }
            }
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
                                Text("#\(e.code)  (ID: \(e.id))").font(.caption).foregroundStyle(.secondary)
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
                                Text(etaString(p.minutes))
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
        .task { await refresh() }
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
        } catch {
            predictions = []
            fetchedAt = Date()
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

