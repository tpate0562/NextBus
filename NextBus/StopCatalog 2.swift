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
    494,700,Cota & Anapamu
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
        if let url = Bundle.main.url(forResource: "stops", withExtension: "txt") {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                sourceText = text
            } else {
                sourceText = embeddedCSV
                usedFallback = true
            }
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
