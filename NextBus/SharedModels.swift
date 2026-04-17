//
//  SharedModels.swift
//  NextBus
//
//  Shared models, networking, and data persistence used by both the main app
//  and the NextBusWidget extension.
//
//  To share this file with the widget target:
//    Select SharedModels.swift in Xcode → File Inspector → Target Membership → check NextBusWidget
//

import Foundation
import Compression
import CoreLocation

// MARK: - App Group Configuration

let appGroupID = "group.tejaspatel.NextBus"

var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: appGroupID) ?? .standard
}

// MARK: - User settings

struct UserStopConfig: Identifiable, Codable, Hashable {
    var id: String            // stop code
    var label: String         // user label
    var selectedRoutes: Set<String> = [] // empty means all
    var headsignIncludes: String = ""   // optional contains filter
    var enabled: Bool = true
    var stopLat: Double?      // stop latitude (from stops.txt)
    var stopLon: Double?      // stop longitude (from stops.txt)
}

let USER_STOPS_KEY = "userStops.v1"
let USE_CUSTOM_STOPS_ONLY_KEY = "useCustomStopsOnly.v1"

let GTFS_RT_URL_STRING = "https://bustracker.sbmtd.gov/gtfsrt/vehicles"

func loadUserStops() -> [UserStopConfig] {
    if let data = sharedDefaults.data(forKey: USER_STOPS_KEY) {
        if let decoded = try? JSONDecoder().decode([UserStopConfig].self, from: data) {
            return decoded
        }
    }
    return []
}

func saveUserStops(_ stops: [UserStopConfig]) {
    if let data = try? JSONEncoder().encode(stops) {
        sharedDefaults.set(data, forKey: USER_STOPS_KEY)
    }
}

func loadUseCustomStopsOnly() -> Bool {
    sharedDefaults.bool(forKey: USE_CUSTOM_STOPS_ONLY_KEY)
}

func saveUseCustomStopsOnly(_ flag: Bool) {
    sharedDefaults.set(flag, forKey: USE_CUSTOM_STOPS_ONLY_KEY)
}

// MARK: - UserDefaults migration (standard → App Group)

private let MIGRATION_KEY = "didMigrateToAppGroup.v1"

/// Copies user stops from UserDefaults.standard to the App Group suite if not done yet.
func migrateUserDefaultsToAppGroupIfNeeded() {
    guard !sharedDefaults.bool(forKey: MIGRATION_KEY) else { return }
    // If App Group already has data, skip
    if sharedDefaults.data(forKey: USER_STOPS_KEY) != nil {
        sharedDefaults.set(true, forKey: MIGRATION_KEY)
        return
    }
    // Copy from standard defaults
    if let data = UserDefaults.standard.data(forKey: USER_STOPS_KEY) {
        sharedDefaults.set(data, forKey: USER_STOPS_KEY)
    }
    if UserDefaults.standard.object(forKey: USE_CUSTOM_STOPS_ONLY_KEY) != nil {
        sharedDefaults.set(UserDefaults.standard.bool(forKey: USE_CUSTOM_STOPS_ONLY_KEY), forKey: USE_CUSTOM_STOPS_ONLY_KEY)
    }
    sharedDefaults.set(true, forKey: MIGRATION_KEY)
}

// MARK: - Stop coordinate lookup (from bundled stops.txt)

/// All 627 SBMTD stop coordinates, embedded for reliable access from both app and widget.
/// Generated from stops.txt — no file I/O needed.
private let embeddedStopCoordinates: [String: (lat: Double, lon: Double)] = [
    "1": (34.424858, -119.72607), "10": (34.424216, -119.68226), "100": (34.404568, -119.526952),
    "1001": (34.452776, -119.77957), "1002": (34.452697, -119.77975), "1003": (34.453013, -119.8077),
    "102": (34.39811, -119.51822), "1023": (34.449481, -119.79073), "1024": (34.456152, -119.78388),
    "1025": (34.450914, -119.79032), "103": (34.41319, -119.69024), "1036": (34.448666, -119.830779),
    "1037": (34.445966, -119.830775), "104": (34.418174, -119.69768), "1044": (34.429447, -119.81547),
    "1045": (34.435018, -119.813179), "1052": (34.416084, -119.861665), "1053": (34.416273, -119.861671),
    "1054": (34.416508, -119.859846), "1055": (34.416402, -119.859887), "1056": (34.415282, -119.858277),
    "1063": (34.414073, -119.860082), "1064": (34.413456, -119.862789), "1065": (34.413619, -119.862971),
    "1066": (34.413877, -119.860145), "1069": (34.413755, -119.858052), "108": (34.425803, -119.76153),
    "1081": (34.413832, -119.853507), "1082": (34.424735, -119.72618), "1084": (34.427596, -119.74672),
    "1085": (34.444241, -119.7589), "1086": (34.409457, -119.695892), "1089": (34.386014, -119.4894),
    "109": (34.44032, -119.76832), "1100": (34.441411, -119.891964), "1102": (34.430184, -119.87387),
    "1104": (34.438929, -119.78949), "1110": (34.405195, -119.738485), "1111": (34.427687, -119.739112),
    "1117": (34.42918, -119.723538), "1120": (34.415404, -119.847934), "1121": (34.414983, -119.839624),
    "1122": (34.429195, -119.725335), "1123": (34.429764, -119.722713), "1124": (34.44058, -119.744017),
    "1125": (34.433052, -119.855264), "1126": (34.433254, -119.855469),
    "110": (34.411279, -119.69751), "111": (34.411269, -119.69753), "112": (34.413259, -119.70008),
    "113": (34.413264, -119.70008), "114": (34.414884, -119.69735), "115": (34.425038, -119.72461),
    "116": (34.419373, -119.6902), "117": (34.414912, -119.69739), "118": (34.419342, -119.6892),
    "119": (34.411277, -119.6975), "12": (34.414918, -119.70046), "120": (34.411281, -119.69762),
    "121": (34.413302, -119.70477), "122": (34.413265, -119.70479), "123": (34.425014, -119.7245),
    "124": (34.420373, -119.69396), "125": (34.42034, -119.69385), "126": (34.42408, -119.70295),
    "127": (34.423843, -119.7067), "128": (34.419, -119.6927), "129": (34.42167, -119.6979),
    "130": (34.426115, -119.72799), "131": (34.42597, -119.72816), "132": (34.425755, -119.73045),
    "133": (34.425877, -119.73064), "134": (34.425786, -119.73327), "135": (34.425899, -119.73335),
    "136": (34.424073, -119.73487), "137": (34.410597, -119.71127), "138": (34.410583, -119.71124),
    "139": (34.410576, -119.71403), "14": (34.42189, -119.72028), "140": (34.410595, -119.7141),
    "141": (34.413, -119.71483), "142": (34.413009, -119.71481), "143": (34.424076, -119.73483),
    "144": (34.422766, -119.72169), "145": (34.411091, -119.69875), "146": (34.425128, -119.72448),
    "147": (34.42511, -119.72459), "148": (34.42371, -119.72166), "149": (34.423696, -119.72165),
    "150": (34.427735, -119.72706), "151": (34.427711, -119.72696), "152": (34.425726, -119.73078),
    "153": (34.425795, -119.73316), "154": (34.426247, -119.73286), "155": (34.424082, -119.73486),
    "156": (34.41358, -119.71469), "157": (34.413585, -119.71474), "158": (34.417023, -119.70944),
    "159": (34.417104, -119.70947), "16": (34.424, -119.72209), "160": (34.418494, -119.71234),
    "161": (34.418499, -119.71253), "162": (34.420451, -119.71587), "163": (34.420485, -119.71587),
    "164": (34.421398, -119.71799), "165": (34.421426, -119.71808), "166": (34.422787, -119.72178),
    "167": (34.422765, -119.72172), "168": (34.410572, -119.71403), "169": (34.410581, -119.71407),
    "17": (34.424065, -119.72208), "170": (34.430414, -119.73151), "171": (34.430441, -119.73147),
    "172": (34.431682, -119.73298), "173": (34.431718, -119.73326), "174": (34.432543, -119.73298),
    "175": (34.432566, -119.73308), "176": (34.433295, -119.73337), "177": (34.433305, -119.73333),
    "178": (34.434291, -119.73344), "179": (34.434286, -119.73353), "18": (34.425753, -119.73035),
    "180": (34.431494, -119.848003), "181": (34.435683, -119.73367), "182": (34.435723, -119.73362),
    "183": (34.439413, -119.72781), "184": (34.436553, -119.73262), "185": (34.436602, -119.73259),
    "186": (34.439467, -119.72769), "187": (34.440375, -119.72783), "188": (34.440407, -119.72798),
    "189": (34.44178, -119.72848), "190": (34.44176, -119.72847), "191": (34.44295, -119.72915),
    "192": (34.44293, -119.72917), "193": (34.444, -119.72936), "194": (34.443988, -119.72934),
    "195": (34.445127, -119.72849), "196": (34.445127, -119.72788), "197": (34.445614, -119.72651),
    "198": (34.445569, -119.72646), "199": (34.446175, -119.72504), "2": (34.42605, -119.7336),
    "200": (34.446095, -119.72497), "201": (34.447043, -119.72264), "202": (34.447054, -119.72271),
    "203": (34.447932, -119.72188), "204": (34.44775, -119.72185), "205": (34.448635, -119.72054),
    "206": (34.448522, -119.72052), "207": (34.450046, -119.71817), "208": (34.44999, -119.71816),
    "209": (34.451059, -119.71614), "21": (34.426162, -119.73278), "210": (34.45106, -119.71596),
    "211": (34.452035, -119.71393), "212": (34.452, -119.71385), "213": (34.429097, -119.73107),
    "214": (34.429143, -119.73094), "215": (34.419702, -119.71384), "216": (34.419724, -119.71382),
    "217": (34.445622, -119.72686), "218": (34.448584, -119.7205), "219": (34.448608, -119.72036),
    "220": (34.415936, -119.70503), "221": (34.415975, -119.70509), "222": (34.416938, -119.70945),
    "223": (34.418587, -119.71226), "224": (34.41859, -119.71235), "225": (34.416987, -119.70951),
    "227": (34.417037, -119.70563), "228": (34.41755, -119.70693), "229": (34.417539, -119.70696),
    "230": (34.416978, -119.70571), "231": (34.418539, -119.70863), "232": (34.418511, -119.70866),
    "233": (34.420549, -119.71589), "234": (34.420553, -119.71587), "235": (34.42144, -119.71815),
    "236": (34.421434, -119.71805), "237": (34.422803, -119.72175), "238": (34.422782, -119.72164),
    "24": (34.424099, -119.73492), "240": (34.415974, -119.70508), "241": (34.415941, -119.70506),
    "242": (34.410575, -119.71104), "243": (34.410585, -119.71101), "244": (34.424037, -119.73486),
    "245": (34.432437, -119.73296), "246": (34.432562, -119.7331), "247": (34.434297, -119.73356),
    "248": (34.434291, -119.73342), "249": (34.43572, -119.73362), "25": (34.413821, -119.71473),
    "250": (34.435681, -119.73373), "251": (34.438141, -119.724501), "252": (34.436556, -119.73265),
    "253": (34.436601, -119.73263), "254": (34.445076, -119.7281), "255": (34.445053, -119.72791),
    "256": (34.44609, -119.72498), "257": (34.447078, -119.72265), "258": (34.44776, -119.72194),
    "259": (34.450017, -119.71809), "26": (34.413841, -119.7148), "260": (34.451068, -119.71593),
    "261": (34.452049, -119.71385), "262": (34.437568, -119.783424), "264": (34.434737, -119.801836),
    "266": (34.434861, -119.809438), "27": (34.42587, -119.76154), "271": (34.43435, -119.835804),
    "273": (34.432855, -119.841708), "274": (34.431927, -119.845667), "276": (34.431171, -119.849878),
    "277": (34.430963, -119.853649), "278": (34.430791, -119.857232), "279": (34.430332, -119.85909),
    "28": (34.430076, -119.868335), "280": (34.430373, -119.863106), "285": (34.431265, -119.847942),
    "286": (34.43344, -119.838328), "287": (34.434283, -119.835058), "288": (34.435679, -119.831435),
    "289": (34.435713, -119.826232), "290": (34.435557, -119.823499), "293": (34.437948, -119.78139),
    "294": (34.440444, -119.762261), "296": (34.440275, -119.7312), "3": (34.413, -119.71484),
    "300": (34.414861, -119.55793), "301": (34.414968, -119.55801), "302": (34.41082, -119.5483),
    "303": (34.414723, -119.557456), "304": (34.41013, -119.54862), "31": (34.441655, -119.78024),
    "310": (34.41662, -119.56943), "311": (34.41614, -119.56867), "312": (34.41694, -119.57564),
    "313": (34.41639, -119.57574), "314": (34.41648, -119.57988), "315": (34.41712, -119.58022),
    "316": (34.41774, -119.58525), "317": (34.41786, -119.58543), "32": (34.441561, -119.78028),
    "320": (34.41901, -119.59135), "321": (34.41773, -119.59082), "322": (34.41906, -119.59435),
    "323": (34.4188, -119.59413), "324": (34.41936, -119.59893), "325": (34.41948, -119.59782),
    "326": (34.42185, -119.60286), "327": (34.42173, -119.60263), "328": (34.42189, -119.60717),
    "329": (34.42158, -119.60712), "33": (34.44319, -119.78002), "330": (34.42139, -119.61279),
    "331": (34.42117, -119.61269), "332": (34.4211, -119.61738), "333": (34.42228, -119.61801),
    "334": (34.42152, -119.62134), "335": (34.42172, -119.62139), "336": (34.42238, -119.63),
    "337": (34.42205, -119.63001), "338": (34.42258, -119.6354), "339": (34.42238, -119.63534),
    "34": (34.44323, -119.78001), "340": (34.42148, -119.64008), "341": (34.42153, -119.63999),
    "342": (34.42227, -119.65138), "343": (34.42214, -119.65163), "344": (34.42082, -119.65977),
    "345": (34.42081, -119.65958), "346": (34.41974, -119.67611), "347": (34.41973, -119.67607),
    "348": (34.42002, -119.66773), "349": (34.42013, -119.66766), "35": (34.445123, -119.77986),
    "350": (34.42152, -119.6571), "351": (34.42151, -119.65705), "352": (34.42253, -119.64489),
    "353": (34.42243, -119.64516), "354": (34.42299, -119.64063), "355": (34.42289, -119.64062),
    "357": (34.41886, -119.68413), "358": (34.41893, -119.68403), "36": (34.44502, -119.77992),
    "360": (34.42282, -119.68816), "361": (34.42282, -119.68813), "362": (34.42463, -119.69213),
    "363": (34.42466, -119.69249), "365": (34.42469, -119.68926), "366": (34.42481, -119.68916),
    "367": (34.42474, -119.6971), "368": (34.42484, -119.69711), "369": (34.42606, -119.69935),
    "37": (34.44506, -119.77991), "370": (34.4261, -119.69932), "371": (34.419847, -119.869891),
    "372": (34.422113, -119.869622), "38": (34.44616, -119.78043), "382": (34.432549, -119.789752),
    "39": (34.44591, -119.78038), "4": (34.42478, -119.72624), "40": (34.44754, -119.78147),
    "400": (34.42561, -119.73039), "401": (34.42586, -119.73052), "402": (34.42574, -119.73314),
    "403": (34.42583, -119.73315), "404": (34.42424, -119.73497), "405": (34.42408, -119.73487),
    "406": (34.42149, -119.73818), "407": (34.42147, -119.73823), "408": (34.41997, -119.74123),
    "409": (34.42001, -119.74098), "41": (34.44786, -119.78144), "410": (34.41921, -119.74398),
    "411": (34.41917, -119.74378), "412": (34.41768, -119.74581), "413": (34.41771, -119.74575),
    "414": (34.41633, -119.7472), "415": (34.41636, -119.74714), "416": (34.41554, -119.74918),
    "417": (34.41547, -119.74921), "418": (34.41315, -119.7539), "419": (34.41322, -119.75396),
    "42": (34.414984, -119.79084), "420": (34.41274, -119.75578), "421": (34.41283, -119.75588),
    "422": (34.41186, -119.7573), "423": (34.41189, -119.7574), "424": (34.41054, -119.75839),
    "425": (34.4105, -119.75853), "426": (34.40951, -119.7609), "427": (34.40957, -119.76027),
    "428": (34.40794, -119.76252), "429": (34.40784, -119.76265), "43": (34.44823, -119.79086),
    "430": (34.40779, -119.76552), "431": (34.40788, -119.76567), "434": (34.40502, -119.7213),
    "435": (34.40399, -119.7208), "436": (34.40178, -119.72309), "437": (34.40272, -119.72254),
    "438": (34.39973, -119.72297), "439": (34.40035, -119.72308), "44": (34.44984, -119.79),
    "440": (34.39867, -119.72221), "441": (34.39894, -119.72224), "442": (34.39698, -119.72069),
    "443": (34.39743, -119.72099), "444": (34.39558, -119.71896), "445": (34.3959, -119.71902),
    "45": (34.44989, -119.78998), "46": (34.45136, -119.7904), "47": (34.45133, -119.79043),
    "48": (34.45265, -119.79123), "49": (34.45264, -119.79127), "5": (34.43157, -119.72953),
    "50": (34.45481, -119.79219), "51": (34.45481, -119.79217), "520": (34.4328, -119.830705),
    "53": (34.45503, -119.79136), "54": (34.455, -119.7914), "55": (34.45639, -119.78997),
    "550": (34.449353, -119.766952), "56": (34.4559, -119.78977), "57": (34.4574, -119.78758),
    "58": (34.426174, -119.687958), "59": (34.416935, -119.85878), "6": (34.42477, -119.72623),
    "60": (34.40588, -119.76817), "600": (34.41536, -119.71233), "601": (34.41552, -119.71238),
    "602": (34.41657, -119.71089), "603": (34.41655, -119.71096), "604": (34.41762, -119.70944),
    "605": (34.41754, -119.70944), "606": (34.41922, -119.70619), "607": (34.41926, -119.70627),
    "608": (34.4153, -119.71246), "609": (34.41551, -119.71254), "61": (34.40579, -119.76826),
    "610": (34.41647, -119.71094), "611": (34.41655, -119.71097), "612": (34.41756, -119.70951),
    "613": (34.41759, -119.70955), "614": (34.41854, -119.70831), "615": (34.41859, -119.70838),
    "616": (34.42035, -119.70425), "617": (34.42042, -119.70434), "618": (34.42172, -119.70273),
    "619": (34.42174, -119.70282), "620": (34.429108, -119.720197), "621": (34.43044, -119.721815),
    "625": (34.4397, -119.89289), "626": (34.437493, -119.892808), "627": (34.409306, -119.692418),
    "628": (34.411304, -119.690062), "629": (34.416818, -119.67149), "63": (34.414885, -119.697468),
    "630": (34.417197, -119.669602), "631": (34.416208, -119.674942), "632": (34.425593, -119.751145),
    "635": (34.441368, -119.82436), "636": (34.441126, -119.82357), "637": (34.441336, -119.768668),
    "638": (34.441071, -119.81865), "64": (34.411069, -119.697841), "641": (34.441717, -119.81504),
    "642": (34.441962, -119.795831), "643": (34.44135, -119.76517), "647": (34.416678, -119.858631),
    "651": (34.415801, -119.712188), "652": (34.418829, -119.716366), "653": (34.413663, -119.7093),
    "655": (34.422341, -119.721157), "656": (34.417592, -119.71469), "660": (34.436617, -119.898376),
    "662": (34.39078, -119.506561), "663": (34.390717, -119.506761), "664": (34.393057, -119.511234),
    "665": (34.400487, -119.520333), "667": (34.417825, -119.705588), "668": (34.411297, -119.715355),
    "67": (34.446617, -119.790411), "670": (34.451324, -119.819789), "671": (34.452323, -119.817751),
    "672": (34.448477, -119.849833), "673": (34.449664, -119.770187), "674": (34.440864, -119.873883),
    "675": (34.45285, -119.81343), "676": (34.44567, -119.855776), "677": (34.451486, -119.80059),
    "678": (34.451431, -119.796469), "679": (34.451194, -119.837189), "68": (34.451387, -119.758635),
    "680": (34.451485, -119.790789), "681": (34.450926, -119.844361), "683": (34.451174, -119.759761),
    "684": (34.451181, -119.75994), "685": (34.44806, -119.75958), "686": (34.447944, -119.75976),
    "689": (34.402765, -119.707811), "69": (34.430451, -119.791498), "691": (34.421415, -119.64818),
    "693": (34.421014, -119.64401), "694": (34.411246, -119.701558), "696": (34.421081, -119.693328),
    "699": (34.425045, -119.689166), "7": (34.424932, -119.6822), "70": (34.430403, -119.802272),
    "700": (34.419373, -119.695157), "701": (34.443896, -119.77906), "702": (34.443758, -119.779136),
    "703": (34.444594, -119.78047), "704": (34.443035, -119.777906), "705": (34.443036, -119.778007),
    "706": (34.42894, -119.689475), "707": (34.424829, -119.693849), "708": (34.425025, -119.693469),
    "709": (34.426909, -119.691627), "710": (34.427136, -119.691232), "711": (34.425881, -119.692732),
    "713": (34.439162, -119.620731), "714": (34.436108, -119.640962), "715": (34.438116, -119.610185),
    "716": (34.436956, -119.632321), "717": (34.43878, -119.612877), "719": (34.416898, -119.8533),
    "72": (34.448986, -119.83597), "720": (34.433708, -119.884987), "721": (34.441833, -119.82778),
    "722": (34.44282, -119.82816), "726": (34.443274, -119.830553), "727": (34.427112, -119.83039),
    "728": (34.433392, -119.830486), "730": (34.451595, -119.757295), "75": (34.410384, -119.699705),
    "752": (34.4393, -119.774186), "753": (34.429823, -119.883074), "754": (34.43016, -119.862874),
    "755": (34.43264, -119.841502), "756": (34.429695, -119.890464), "761": (34.434982, -119.80257),
    "765": (34.435821, -119.64142), "766": (34.4332, -119.64095), "767": (34.4326, -119.64078),
    "77": (34.436588, -119.898208), "771": (34.451623, -119.751161), "772": (34.454905, -119.751177),
    "773": (34.425859, -119.735344), "774": (34.43567, -119.733539), "776": (34.421575, -119.602367),
    "778": (34.418655, -119.590435), "78": (34.439787, -119.892721), "788": (34.408498, -119.720905),
    "789": (34.405776, -119.72104), "79": (34.429663, -119.892777), "795": (34.426462, -119.707922),
    "8": (34.428849, -119.67659), "810": (34.425584, -119.733549), "811": (34.435676, -119.75167),
    "814": (34.440314, -119.72796), "816": (34.426886, -119.709439), "819": (34.436151, -119.722109),
    "82": (34.451331, -119.830168), "823": (34.440345, -119.746336), "824": (34.440319, -119.758847),
    "825": (34.412955, -119.690115), "829": (34.433429, -119.718382), "83": (34.451575, -119.760153),
    "830": (34.435289, -119.720929), "831": (34.440325, -119.739774), "834": (34.41089, -119.853462),
    "836": (34.421903, -119.64004), "838": (34.42864, -119.640856), "839": (34.423941, -119.640254),
    "84": (34.440101, -119.789225), "840": (34.42873, -119.640732), "843": (34.447855, -119.76064),
    "846": (34.410534, -119.699714), "847": (34.427411, -119.79872), "848": (34.428081, -119.795769),
    "85": (34.435111, -119.81001), "856": (34.437079, -119.895155), "858": (34.442538, -119.797363),
    "861": (34.432328, -119.73345), "863": (34.412529, -119.705), "864": (34.426394, -119.63146),
    "865": (34.414055, -119.69195), "867": (34.432986, -119.63188), "868": (34.429185, -119.63155),
    "87": (34.439699, -119.771946), "871": (34.431662, -119.604609), "872": (34.423783, -119.61315),
    "876": (34.419003, -119.86957), "877": (34.426371, -119.86987), "879": (34.423789, -119.86986),
    "884": (34.422514, -119.750308), "885": (34.425021, -119.74742), "887": (34.431015, -119.732),
    "889": (34.446147, -119.789722), "89": (34.427564, -119.74689), "890": (34.44537, -119.80724),
    "891": (34.445226, -119.803329), "892": (34.42809, -119.711089), "893": (34.445126, -119.797221),
    "898": (34.447595, -119.76051), "899": (34.445181, -119.76055), "9": (34.422963, -119.668508),
    "90": (34.429115, -119.742034), "900": (34.445351, -119.76035), "902": (34.411026, -119.551985),
    "903": (34.407072, -119.547339), "904": (34.416497, -119.56145), "905": (34.41506, -119.558047),
    "907": (34.416662, -119.569033), "908": (34.40452, -119.527596), "909": (34.415785, -119.576076),
    "910": (34.417449, -119.584224), "912": (34.405118, -119.534935), "914": (34.426878, -119.802372),
    "919": (34.43178, -119.69297), "92": (34.417525, -119.86801), "920": (34.422338, -119.680071),
    "922": (34.427748, -119.72705), "925": (34.435796, -119.82115), "926": (34.437692, -119.78393),
    "927": (34.435391, -119.79632), "928": (34.430292, -119.86873), "929": (34.429796, -119.897653),
    "930": (34.435141, -119.816373), "931": (34.430724, -119.853635), "932": (34.43047, -119.860405),
    "933": (34.401852, -119.723022), "939": (34.423659, -119.640085), "940": (34.443739, -119.788345),
    "941": (34.443651, -119.788596), "942": (34.441237, -119.81938), "943": (34.450805, -119.847155),
    "944": (34.423279, -119.702191), "945": (34.42482, -119.70058), "946": (34.424741, -119.698688),
    "947": (34.423547, -119.697049), "948": (34.423995, -119.694548), "949": (34.42207, -119.65199),
    "95": (34.421634, -119.600844), "950": (34.421153, -119.622639), "952": (34.419746, -119.67615),
    "953": (34.423915, -119.697363), "954": (34.404804, -119.532571), "955": (34.41967, -119.594537),
    "956": (34.404743, -119.52942), "958": (34.430158, -119.87791), "959": (34.429982, -119.886619),
    "96": (34.401673, -119.525869), "960": (34.430995, -119.90548), "961": (34.415399, -119.68119),
    "963": (34.425152, -119.83544), "965": (34.419703, -119.8353), "966": (34.425008, -119.8352),
    "97": (34.396497, -119.515319), "98": (34.38527, -119.486667), "99": (34.394268, -119.512994)
]

/// Looks up coordinates for a stop code from the embedded stop coordinate dictionary.
func lookupStopCoordinates(stopCode: String) -> (lat: Double, lon: Double)? {
    return embeddedStopCoordinates[stopCode]
}

// MARK: - Vehicle locations model

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

// MARK: - Vehicle ID matching helpers

func normalizeVehicleID(_ s: String) -> String {
    let allowed = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    return String(String.UnicodeScalarView(allowed)).uppercased()
}

func matchVehicle(by vehicleID: String, in vehicles: [VehicleLocation]) -> VehicleLocation? {
    let target = normalizeVehicleID(vehicleID)
    if let exact = vehicles.first(where: { normalizeVehicleID($0.id) == target }) { return exact }
    if let contains = vehicles.first(where: { normalizeVehicleID($0.id).contains(target) || target.contains(normalizeVehicleID($0.id)) }) { return contains }
    return nil
}

// MARK: - GTFS-RT Protobuf Internals

private let _iso8601Fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func debugDumpVehicles(_ vehicles: [VehicleLocation]) {
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

// MARK: - Config
enum Routes: String, CaseIterable {
    case r1 = "1"
    case r2 = "2"
    case r3 = "3"
    case r4 = "4"
    case r5 = "5"
    case r6 = "6"
    case r7 = "7"
    case r11 = "11"
    case r12X = "12X"
    case r14 = "14"
    case r15X = "15X"
    case r16 = "16"
    case r17 = "17"
    case r19X = "19X"
    case r20 = "20"
    case r23 = "23"
    case r24X = "24X"
    case r25 = "25"
    case r27 = "27"
    case r28 = "28"
}

import SwiftUI

/// Route colors matching official SBMTD branding
func sbmtdRouteColor(for route: String) -> Color {
    switch route {
    case "1":   return Color(red: 180/255, green: 37/255,  blue: 101/255)
    case "2":   return Color(red: 180/255, green: 37/255,  blue: 101/255)
    case "3":   return Color(red: 133/255, green: 189/255, blue: 86/255)
    case "4":   return Color(red: 126/255, green: 203/255, blue: 241/255)
    case "5":   return Color(red: 225/255, green: 127/255, blue: 172/255)
    case "6":   return Color(red: 217/255, green: 57/255,  blue: 52/255)
    case "7":   return Color(red: 71/255,  green: 146/255, blue: 205/255)
    case "11":  return Color(red: 217/255, green: 57/255,  blue: 52/255)
    case "12X": return Color(red: 172/255, green: 125/255, blue: 77/255)
    case "14":  return Color(red: 118/255, green: 78/255,  blue: 39/255)
    case "15X": return Color(red: 61/255,  green: 138/255, blue: 76/255)
    case "16":  return Color(red: 115/255, green: 118/255, blue: 120/255)
    case "17":  return Color(red: 248/255, green: 215/255, blue: 73/255)
    case "19X": return Color(red: 168/255, green: 153/255, blue: 214/255)
    case "20":  return Color(red: 227/255, green: 125/255, blue: 96/255)
    case "23":  return Color(red: 125/255, green: 203/255, blue: 242/255)
    case "24X": return Color(red: 171/255, green: 124/255, blue: 77/255)
    case "25":  return Color(red: 76/255,  green: 77/255,  blue: 79/255)
    case "27":  return Color(red: 122/255, green: 32/255,  blue: 116/255)
    case "28":  return Color(red: 66/255,  green: 147/255, blue: 212/255)
    default:    return Color.gray
    }
}

struct Stop: Identifiable, Hashable {
    let id: String        // SBMTD BusTracker stop id
    let label: String     // UI label
    let purpose: Purpose
    enum Purpose { case storkeAndSierraMadre, ucsbElings, ucsbNorthHall, custom }
}

// MARK: - Models
struct StopBoard: Identifiable, Hashable {
    let id = UUID()
    let stop: Stop
    let predictions: [Prediction]
    let fetchedAt: Date
}

struct Prediction: Identifiable, Hashable {
    let id = UUID()
    let route: String       // e.g. "11", "27", "28", "24X"
    let headsign: String    // e.g. "UCSB North Hall", "Downtown SB", "Camino Real Mkt"
    let minutes: Int?       // nil if not parsable; 0 for APPROACHING/DUE
    let vehicleID: String?
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
            return []
        }

        let predictions = parse(html: html)
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

        // Extract vehicle annotations in order of appearance per route
        // e.g., lines contain "(Vehicle 708)" or just "SCH" on a following line.
        // We'll build a per-route queue we can pop from as we collect predictions.
        var vehicleQueues: [String: [String]] = [:]
        do {
            let routeRx = try? NSRegularExpression(pattern: "#\\s*#?([0-9]{1,2}X?)", options: [.caseInsensitive])
            let vehicleRx = try? NSRegularExpression(pattern: "\\((?:Vehicle\\s+)?([A-Z0-9]+)\\)", options: [.caseInsensitive])
            // Split by <h2> sections to maintain order
            let sections = squished.components(separatedBy: "<h2>")
            for sec in sections {
                // Find the route tag within the section
                let ns = sec as NSString
                if let routeRx = routeRx, let m = routeRx.firstMatch(in: sec, range: NSRange(location: 0, length: ns.length)) {
                    let route = ns.substring(with: m.range(at: 1)).uppercased()
                    var vID: String? = nil
                    if let vehicleRx = vehicleRx, let vm = vehicleRx.firstMatch(in: sec, range: NSRange(location: 0, length: ns.length)) {
                        vID = ns.substring(with: vm.range(at: 1)).uppercased()
                    } else if sec.range(of: ">\n\n    \n    \n    &nbsp;SCH", options: .caseInsensitive) != nil || sec.range(of: ">SCH<", options: .caseInsensitive) != nil || sec.localizedCaseInsensitiveContains("SCH") {
                        vID = "SCH"
                    }
                    if let vID = vID {
                        vehicleQueues[route, default: []].append(vID)
                    }
                }
            }
        }

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

                let vID: String? = {
                    if var q = vehicleQueues[route], !q.isEmpty {
                        let first = q.removeFirst()
                        vehicleQueues[route] = q
                        return first
                    }
                    return nil
                }()
                results.append(.init(route: route, headsign: headsign, minutes: minutes, vehicleID: vID))
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
func towardStorkeElColegio(_ p: Prediction) -> Bool {
    // We want trips heading toward the Storke & El Colegio area.
    // Common headsigns that move in that direction: "UCSB", "Camino Real", "Isla Vista", "Storke", "Marketplace".
    let h = p.headsign.lowercased()
    return h.contains("ucsb") || h.contains("camino real") || h.contains("isla vista") || h.contains("storke") || h.contains("market")
}

func towardCaminoRealMarket(_ p: Prediction) -> Bool {
    // Strictly prefer trips heading toward Camino Real Market / Marketplace.
    // Common headsign variants observed: "Camino Real", "Camino Real Mkt", "Camino Real Market", "Marketplace".
    let h = p.headsign.lowercased()
    return h.contains("camino real mkt") || h.contains("marketplace") || h.contains("market") || h.contains("mkt")
}
