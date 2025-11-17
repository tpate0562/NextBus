import Foundation

public struct StopCatalogEntry: Identifiable, Hashable, Codable {
    public let id: String      // internal stable id (e.g., GTFS stop_id)
    public let code: String    // public-facing stop code printed on signs
    public let name: String    // human-readable stop name

    public init(id: String, code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }
}

public enum StopCatalog {
    // Indicates whether we fell back to a tiny built-in list because no bundled/remote catalog was found.
    public static var usedFallback: Bool = true

    // Load a catalog of stops. In this MVP we return a small hardcoded list that covers common UCSB/Goleta stops.
    // You can later replace this with a JSON file in the bundle or a remote fetch.
    public static func load() -> [StopCatalogEntry] {
        // Try to load from a bundled JSON file named "stops.json" if present.
        if let url = Bundle.main.url(forResource: "stops", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([StopCatalogEntry].self, from: data) {
            usedFallback = false
            return decoded
        }

        // Fallback: a concise, curated set of known SBMTD stops around UCSB/Isla Vista
        usedFallback = true
        return [
            StopCatalogEntry(id: "3001", code: "3001", name: "UCSB North Hall"),
            StopCatalogEntry(id: "3002", code: "3002", name: "UCSB Elings Hall"),
            StopCatalogEntry(id: "1465", code: "1465", name: "Storke & El Colegio"),
            StopCatalogEntry(id: "1466", code: "1466", name: "Storke & Hollister"),
            StopCatalogEntry(id: "2750", code: "2750", name: "Camino Real Marketplace"),
            StopCatalogEntry(id: "1100", code: "1100", name: "Downtown Transit Center"),
        ]
    }
}
