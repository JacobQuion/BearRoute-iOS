//
//  DiningService.swift
//  BearTracks
//
//  Cal Dining does not publish a JSON API, so we fetch the public menus page
//  and read the structure the site renders:
//
//      <div class="location-name Crossroads">
//          <div class="preiod-name Lunch">        // note: "preiod" is their typo
//              <div class="recip"><span>Item name</span> ... </div>
//
//  The parser reads names out of the CSS classes rather than matching a fixed
//  list, so it survives Cal Dining renaming meal periods between semesters.
//

import Foundation

/// Cal Dining labels meal periods with the semester attached, e.g.
/// "Spring - Brunch", so we bucket them into something stable to filter on.
enum MealKind: String, CaseIterable, Identifiable, Hashable {
    case breakfast = "Breakfast"
    case brunch = "Brunch"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case allDay = "All Day"
    case other = "Other"

    var id: String { rawValue }

    init(periodName: String) {
        let name = periodName.lowercased()
        if name.contains("breakfast") { self = .breakfast }
        else if name.contains("brunch") { self = .brunch }
        else if name.contains("lunch") { self = .lunch }
        else if name.contains("dinner") || name.contains("supper") { self = .dinner }
        else if name.contains("all day") || name.contains("allday") { self = .allDay }
        else { self = .other }
    }

    var sortOrder: Int {
        switch self {
        case .breakfast: return 0
        case .brunch: return 1
        case .lunch: return 2
        case .dinner: return 3
        case .allDay: return 4
        case .other: return 5
        }
    }

    var symbol: String {
        switch self {
        case .breakfast: return "sunrise"
        case .brunch: return "sun.haze"
        case .lunch: return "sun.max"
        case .dinner: return "moon.stars"
        case .allDay: return "clock"
        case .other: return "fork.knife"
        }
    }

    /// Best guess at what the user wants to see right now.
    static var currentGuess: MealKind {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<11: return .breakfast
        case 11..<16: return .lunch
        default: return .dinner
        }
    }
}

// MARK: - Dietary tags

/// Every diet/allergen marker Cal Dining puts on a dish, plus the carbon
/// rating. Sourced from the CSS classes and icons on each menu `<li>`.
enum DietaryTag: String, CaseIterable, Identifiable, Hashable {
    // Diets / preferences
    case vegan, vegetarian, halal, kosher
    // Allergens
    case dairy, egg, fish, gluten, peanut, sesame, shellfish, soy, treenut, wheat, pork, alcohol

    var id: String { rawValue }

    /// True for the "I want to eat this" markers, as opposed to allergens.
    var isDiet: Bool {
        switch self {
        case .vegan, .vegetarian, .halal, .kosher: return true
        default: return false
        }
    }

    /// Maps a raw class token from a menu `<li class="recip …">` to a tag.
    /// Cal Dining's class names don't always match their icon names, so both
    /// spellings are accepted.
    init?(className: String) {
        switch className.lowercased() {
        case "vegan-option", "vegan": self = .vegan
        case "vegetarian-option", "vegetarian": self = .vegetarian
        case "halal": self = .halal
        case "kosher": self = .kosher
        case "milk", "dairy": self = .dairy
        case "egg": self = .egg
        case "fish": self = .fish
        case "gluten": self = .gluten
        case "peanuts", "peanut": self = .peanut
        case "sesame": self = .sesame
        case "shellfish", "shell": self = .shellfish
        case "soybeans", "soy": self = .soy
        case "tree-nuts", "treenut": self = .treenut
        case "wheat": self = .wheat
        case "pork": self = .pork
        case "alcohol": self = .alcohol
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .vegan: return "Vegan"
        case .vegetarian: return "Vegetarian"
        case .halal: return "Halal"
        case .kosher: return "Kosher"
        case .dairy: return "Dairy"
        case .egg: return "Egg"
        case .fish: return "Fish"
        case .gluten: return "Gluten"
        case .peanut: return "Peanut"
        case .sesame: return "Sesame"
        case .shellfish: return "Shellfish"
        case .soy: return "Soy"
        case .treenut: return "Tree Nut"
        case .wheat: return "Wheat"
        case .pork: return "Pork"
        case .alcohol: return "Alcohol"
        }
    }

    var symbol: String {
        switch self {
        case .vegan: return "leaf.fill"
        case .vegetarian: return "leaf"
        case .halal: return "moon.stars.fill"
        case .kosher: return "star.fill"
        default: return "exclamationmark.triangle"
        }
    }

    static let diets: [DietaryTag] = allCases.filter(\.isDiet)
    static let allergens: [DietaryTag] = allCases.filter { !$0.isDiet }
}

/// Cal Dining's carbon-footprint rating for a dish.
enum CarbonRating: String, Hashable {
    case low, med, high

    var label: String {
        switch self {
        case .low: return "Low carbon"
        case .med: return "Medium carbon"
        case .high: return "High carbon"
        }
    }
}

// MARK: - Menu item

struct MenuItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let tags: Set<DietaryTag>
    let carbon: CarbonRating?
    /// The menu station this dish is served at, e.g. "Center Plate" or
    /// "Griddle/Grill". Empty when Cal Dining didn't group the item.
    let station: String
    /// Keys for the nutrition lookup (Cal Dining's get_recipe_details AJAX).
    let location: String
    let recipeId: String
    let menuId: String

    var diets: [DietaryTag] { DietaryTag.diets.filter { tags.contains($0) } }
    var allergens: [DietaryTag] { DietaryTag.allergens.filter { tags.contains($0) } }

    /// Identifies the dish to the nutrition lookup. Stable across reloads,
    /// unlike `id`, which is freshly minted every time the page is parsed.
    var nutritionKey: String { "\(location)|\(recipeId)|\(menuId)" }

    /// Whether Cal Dining gave us enough to ask for this dish's nutrition.
    var hasNutritionLookup: Bool {
        !location.isEmpty && !recipeId.isEmpty && !menuId.isEmpty
    }
}

// MARK: - Nutrition

/// The serving size and macros Cal Dining publishes for one dish. Values are
/// optional because the recipe card occasionally omits a row.
struct NutritionFacts: Hashable, Sendable {
    /// As printed on the recipe card, e.g. "4 oz". Empty when absent.
    let servingSize: String
    let calories: Double?
    let protein: Double?
    let carbohydrate: Double?
    let fat: Double?

    /// The one-line macro summary shown under a dish, e.g.
    /// "Cal: 201.67  Protein: 23.2g  Carb: 10.38g  Fat: 6.75g". Nil when the
    /// recipe card carried no numbers at all.
    var macroSummary: String? {
        var parts: [String] = []
        if let calories { parts.append("Cal: \(Self.format(calories))") }
        if let protein { parts.append("Protein: \(Self.format(protein))g") }
        if let carbohydrate { parts.append("Carb: \(Self.format(carbohydrate))g") }
        if let fat { parts.append("Fat: \(Self.format(fat))g") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Two decimals at most, with trailing zeros dropped, so 23.20 reads as
    /// "23.2" and 94.0 as "94".
    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        guard rounded != rounded.rounded() else { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// Holds onto recipe nutrition for the life of the app run and folds duplicate
/// requests for the same dish into a single network call — a menu screen asks
/// for every visible row at once, and rebuilding the list (say, after a filter
/// change) asks for them all again.
actor NutritionCache {
    static let shared = NutritionCache()

    private var cached: [String: NutritionFacts] = [:]
    private var inFlight: [String: Task<NutritionFacts, Error>] = [:]

    func facts(for item: MenuItem) async throws -> NutritionFacts {
        let key = item.nutritionKey
        if let hit = cached[key] { return hit }
        if let running = inFlight[key] { return try await running.value }

        // Unstructured on purpose: a row scrolling away cancels its own
        // `.task`, but the fetch it kicked off should still finish and land
        // in the cache for the next row that needs it.
        let task = Task {
            try await DiningService.fetchNutrition(location: item.location,
                                                   recipeId: item.recipeId,
                                                   menuId: item.menuId)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let facts = try await task.value
        cached[key] = facts
        return facts
    }
}

/// A run of dishes served together at one menu station within a meal, e.g.
/// "Center Plate" or "Griddle/Grill".
struct MenuStation: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let items: [MenuItem]
}

struct MenuPeriod: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let items: [MenuItem]

    var kind: MealKind { MealKind(periodName: name) }

    /// Groups a set of this period's dishes back into their menu stations,
    /// preserving the order Cal Dining served them in. Items sharing a station
    /// name are collected together; items with no station fall under an empty
    /// name (shown without a header). Pass the already-filtered items so the
    /// grouping reflects what's actually on screen.
    static func groupedByStation(_ items: [MenuItem]) -> [MenuStation] {
        var order: [String] = []
        var buckets: [String: [MenuItem]] = [:]
        for item in items {
            if buckets[item.station] == nil { order.append(item.station) }
            buckets[item.station, default: []].append(item)
        }
        return order.map { MenuStation(name: $0, items: buckets[$0] ?? []) }
    }

    /// The period name with a leading semester word stripped, so
    /// "Summer - Brunch" reads as "Brunch" and a bare "Summer" reads as empty.
    var cleanedName: String {
        var text = name
        for semester in ["spring", "summer", "fall", "winter"] {
            text = text.replacingOccurrences(
                of: "(?i)\\b\(semester)\\b\\s*[-–—]?\\s*",
                with: "",
                options: .regularExpression
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DiningLocation: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let periods: [MenuPeriod]

    var itemCount: Int { periods.reduce(0) { $0 + $1.items.count } }

    /// A period paired with the label to actually show for it.
    struct LabeledPeriod: Identifiable, Hashable {
        let id: UUID
        let label: String
        let symbol: String
        let period: MenuPeriod
    }

    /// Periods in serving order, each with a display label.
    ///
    /// Cal Dining labels periods by semester ("Summer", "Spring - Brunch"),
    /// which is useless to a student. When the name carries a real meal word
    /// we use that, and when it doesn't we fall back to labelling by position:
    /// three periods become breakfast, lunch and dinner, and two become
    /// breakfast and lunch/dinner.
    var labeledPeriods: [LabeledPeriod] {
        let ordered = periods.enumerated().sorted { lhs, rhs in
            if lhs.element.kind.sortOrder != rhs.element.kind.sortOrder {
                return lhs.element.kind.sortOrder < rhs.element.kind.sortOrder
            }
            // Ties keep the order Cal Dining rendered them in, which is
            // chronological. Swift's sort isn't stable, so this is explicit.
            return lhs.offset < rhs.offset
        }.map(\.element)

        let fallbacks = DiningLocation.positionalLabels(count: ordered.count)

        return ordered.enumerated().map { index, period in
            let label: String
            if period.kind != .other {
                label = period.kind.rawValue
            } else if !period.cleanedName.isEmpty {
                label = period.cleanedName
            } else {
                label = fallbacks[index]
            }
            return LabeledPeriod(
                id: period.id,
                label: label,
                symbol: DiningLocation.symbol(for: label),
                period: period
            )
        }
    }

    /// The meal labels this location is serving, e.g. "Breakfast, Lunch, Dinner".
    var mealSummary: String {
        labeledPeriods.map(\.label).joined(separator: ", ")
    }

    static func positionalLabels(count: Int) -> [String] {
        switch count {
        case 0: return []
        case 1: return ["All Day"]
        case 2: return ["Breakfast", "Lunch/Dinner"]
        case 3: return ["Breakfast", "Lunch", "Dinner"]
        default:
            var labels = ["Breakfast", "Lunch", "Dinner"]
            while labels.count < count {
                labels.append("Meal \(labels.count + 1)")
            }
            return labels
        }
    }

    static func symbol(for label: String) -> String {
        let lowered = label.lowercased()
        if lowered.contains("breakfast") { return "sunrise" }
        if lowered.contains("brunch") { return "sun.haze" }
        if lowered.contains("lunch") && lowered.contains("dinner") { return "sun.and.horizon" }
        if lowered.contains("lunch") { return "sun.max" }
        if lowered.contains("dinner") { return "moon.stars" }
        if lowered.contains("all day") { return "clock" }
        return "fork.knife"
    }

    /// Residential dining commons, which are the ones most students care about.
    var isDiningCommons: Bool {
        let commons = ["crossroads", "cafe 3", "café 3", "foothill", "clark kerr"]
        let lowered = name.lowercased()
        return commons.contains { lowered.contains($0) }
    }
}

/// Everything needed to work out why a parse came back thin, readable from
/// inside the app so we don't have to go spelunking in a terminal.
struct DiningDiagnostics {
    var requestedURL: String = ""
    var statusCode: Int = 0
    var byteCount: Int = 0
    var locationMarkers: Int = 0
    var periodMarkers: Int = 0
    var recipMarkers: Int = 0
    var parsedLocations: Int = 0
    var parsedItems: Int = 0
    /// Verbatim class attributes from the page, which is the ground truth.
    var sampleClasses: [String] = []

    var summary: String {
        """
        URL: \(requestedURL)
        HTTP status: \(statusCode)
        HTML size: \(byteCount) bytes

        Marker counts in the raw HTML
          location-name: \(locationMarkers)
          preiod-name / period-name: \(periodMarkers)
          recip: \(recipMarkers)

        After parsing
          locations: \(parsedLocations)
          menu items: \(parsedItems)

        Class attributes found on the page
        \(sampleClasses.isEmpty ? "  (none matched)" : sampleClasses.map { "  " + $0 }.joined(separator: "\n"))
        """
    }
}

struct DiningFetchResult {
    let locations: [DiningLocation]
    let diagnostics: DiningDiagnostics
}

enum DiningServiceError: LocalizedError {
    case badResponse(Int)
    case unreadable
    case noMenusFound

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "Cal Dining's site returned status \(code)."
        case .unreadable:
            return "Couldn't read the page Cal Dining sent back."
        case .noMenusFound:
            return "Cal Dining's page loaded but no menus were found in it. They may have changed their layout, or menus may not be posted yet."
        }
    }
}

/// The Cal Dining locations, hardcoded so the picker always lists every hall
/// even when the menus page only renders a few of them.
struct DiningHall: Identifiable, Hashable {
    let id: String
    let name: String
    let isResidential: Bool
    /// A promo photo of the location, pulled from Cal Dining's own site.
    let imageURL: URL?
    /// An asset-catalog image to use instead of `imageURL`, when we've bundled
    /// a specific photo for this hall.
    var assetName: String? = nil

    private static func image(_ path: String) -> URL? {
        URL(string: "https://dining.berkeley.edu/wp-content/uploads/\(path)")
    }

    static let all: [DiningHall] = [
        .init(id: "crossroads", name: "Crossroads", isResidential: true,
              imageURL: nil, assetName: "CrossroadsBanner"),
        .init(id: "cafe3", name: "Café 3", isResidential: true,
              imageURL: image("2024/01/dining-commons-slide-cafe3-1.jpg")),
        .init(id: "clarkkerr", name: "Clark Kerr Campus", isResidential: true,
              imageURL: image("2024/01/dining-commons-slide-ck-1.jpg")),
        .init(id: "foothill", name: "Foothill", isResidential: true,
              imageURL: nil, assetName: "FoothillBanner"),
        .init(id: "goldenbear", name: "The Golden Bear Café", isResidential: false,
              imageURL: image("2025/01/restaurants-slide-gbc-1-scaled-700x400.jpg")),
        .init(id: "studentunion", name: "The Eateries at Student Union", isResidential: false,
              imageURL: image("2024/11/restaurants-slide-eateries-1.jpg")),
        .init(id: "browns", name: "Brown's", isResidential: false,
              imageURL: image("2025/01/restaurants-slide-browns-1-scaled-700x400.jpg")),
        .init(id: "localxdesign", name: "Local x Design", isResidential: false,
              imageURL: image("2024/11/restaurants-slide-local-1.jpg")),
        .init(id: "gateway", name: "Gateway Café", isResidential: false,
              imageURL: image("restaurants-gateway-7.30.26_KL-1038.jpg"))
    ]

    /// Loose comparison so "Clark_Kerr_Campus" from the page matches "Clark Kerr Campus".
    func matches(_ parsedName: String) -> Bool {
        let a = DiningHall.normalize(name)
        let b = DiningHall.normalize(parsedName)
        return a == b || a.contains(b) || b.contains(a)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "é", with: "e")
            .replacingOccurrences(of: "the", with: "")
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
}

struct DiningService {

    /// The public `/menus/` page is rendered server-side for *today only*. Its
    /// date dropdown doesn't reload the page with a query parameter — it POSTs
    /// to WordPress's admin-ajax with `action=cald_filter_xml` and swaps in the
    /// returned menu fragment. So to read any other day we call that endpoint
    /// directly; sending a date in the page URL is silently ignored.
    private static let ajaxPath = "https://dining.berkeley.edu/wp-admin/admin-ajax.php"

    /// Cal Dining's date filter keys the day as a bare `yyyyMMdd` token.
    static func dateToken(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    static func fetchMenus(for date: Date = Date()) async throws -> DiningFetchResult {
        let token = dateToken(for: date)
        let url = URL(string: ajaxPath)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Some WordPress front ends serve a stripped page to unknown clients.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        // Empty location & mealperiod ask for every hall and every meal that day.
        request.httpBody = "action=cald_filter_xml&location=&mealperiod=&date=\(token)"
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if !(200...299).contains(status) {
            throw DiningServiceError.badResponse(status)
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw DiningServiceError.unreadable
        }

        let locations = parse(html: html)

        var diagnostics = DiningDiagnostics()
        diagnostics.requestedURL = "\(url.absoluteString)  (cald_filter_xml, date=\(token))"
        diagnostics.statusCode = status
        diagnostics.byteCount = data.count
        diagnostics.locationMarkers = occurrences(of: "location-name", in: html)
        diagnostics.periodMarkers = occurrences(of: "preiod-name", in: html)
            + occurrences(of: "period-name", in: html)
        diagnostics.recipMarkers = occurrences(of: "recip", in: html)
        diagnostics.parsedLocations = locations.count
        diagnostics.parsedItems = locations.reduce(0) { $0 + $1.itemCount }
        diagnostics.sampleClasses = interestingClassAttributes(in: html)

        return DiningFetchResult(locations: locations, diagnostics: diagnostics)
    }

    // MARK: - Nutrition

    /// Fetches one dish's recipe card. This is the same `get_recipe_details`
    /// call the site makes when a dish is tapped, keyed by the `data-location`,
    /// `data-id` and `data-menuid` attributes we captured while parsing.
    static func fetchNutrition(location: String,
                               recipeId: String,
                               menuId: String) async throws -> NutritionFacts {
        var request = URLRequest(url: URL(string: ajaxPath)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // `location` is a base64 path, so it has to be escaped rather than
        // pasted into the body — its "+" and "/" mean something to a form.
        request.httpBody = formEncoded([
            ("action", "get_recipe_details"),
            ("location", location),
            ("id", recipeId),
            ("menu_id", menuId)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw DiningServiceError.badResponse(status)
        }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw DiningServiceError.unreadable
        }
        return parseNutrition(html: html)
    }

    /// Reads the recipe card's serving size and its `<li><span>Label:</span>
    /// value</li>` nutrition rows.
    static func parseNutrition(html: String) -> NutritionFacts {
        let serving = firstMatch(in: html,
                                 pattern: "class=[\"']serving-size[\"']>\\s*Serving Size:\\s*([^<]*)<")
            .map { collapseWhitespace(decodeEntities($0)) } ?? ""

        var rows: [(label: String, value: Double)] = []
        if let regex = try? NSRegularExpression(
            pattern: "<li>\\s*<span>([^<]*)</span>\\s*([0-9]+(?:\\.[0-9]+)?)",
            options: [.caseInsensitive]
        ) {
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let label = ns.substring(with: match.range(at: 1)).lowercased()
                guard let value = Double(ns.substring(with: match.range(at: 2))) else { continue }
                rows.append((label, value))
            }
        }

        func value(_ keyword: String) -> Double? {
            rows.first { $0.label.contains(keyword) }?.value
        }

        return NutritionFacts(
            servingSize: serving,
            calories: value("calories"),
            protein: value("protein"),
            carbohydrate: value("carbohydrate"),
            // The row reads "Total Lipid/Fat"; keying off "lipid" avoids
            // picking up the saturated and trans fat rows below it.
            fat: value("lipid")
        )
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Diagnostics helpers

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .caseInsensitive, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Pulls distinct class attributes that look menu related, so we can see
    /// the real markup instead of guessing at it.
    private static func interestingClassAttributes(in html: String) -> [String] {
        let pattern = "class\\s*=\\s*[\"']([^\"']{0,120})[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let keywords = ["location", "period", "preiod", "recip", "menu", "meal", "hall", "date", "day"]
        let ns = html as NSString

        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = value.lowercased()
            guard keywords.contains(where: { lowered.contains($0) }) else { continue }
            guard !seen.contains(lowered) else { continue }
            seen.insert(lowered)
            result.append(value)
            if result.count >= 40 { break }
        }
        return result
    }

    // MARK: - Parsing

    static func parse(html: String) -> [DiningLocation] {
        let locationBlocks = blocks(in: html, markerClass: "location-name")

        return locationBlocks.compactMap { block in
            let periodBlocks = blocks(in: block.body, markerClass: "preiod-name")
                + blocks(in: block.body, markerClass: "period-name")

            let periods: [MenuPeriod] = periodBlocks.compactMap { periodBlock in
                // Cal Dining groups a period's dishes into stations (cat-name
                // blocks like "Center Plate"). Parse each station's items with
                // its name attached; if a period has no stations, treat the
                // whole body as one unnamed group. Dedup stays period-wide so a
                // dish listed twice across stations only shows once.
                let stations = stationBlocks(in: periodBlock.body)
                let sources = stations.isEmpty
                    ? [(name: "", body: periodBlock.body)]
                    : stations

                var seen = Set<String>()
                var items: [MenuItem] = []
                for station in sources {
                    for item in recipeItems(in: station.body, station: station.name)
                    where seen.insert(item.name.lowercased()).inserted {
                        items.append(item)
                    }
                }

                guard !items.isEmpty else { return nil }
                return MenuPeriod(name: periodBlock.name, items: items)
            }

            guard !periods.isEmpty else { return nil }
            return DiningLocation(name: block.name, periods: periods)
        }
    }

    private struct Block {
        let name: String
        let body: String
    }

    /// Finds every element carrying `markerClass` and returns its readable name
    /// (the other class token) plus everything up to the next such element.
    private static func blocks(in html: String, markerClass: String) -> [Block] {
        let pattern = "class\\s*=\\s*[\"']([^\"']*\\b\(markerClass)\\b[^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var result: [Block] = []
        for (index, match) in matches.enumerated() {
            let classAttribute = ns.substring(with: match.range(at: 1))
            let name = readableName(from: classAttribute, excluding: markerClass)
            guard !name.isEmpty else { continue }

            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            guard end > start else { continue }

            result.append(Block(name: name, body: ns.substring(with: NSRange(location: start, length: end - start))))
        }
        return result
    }

    private static func readableName(from classAttribute: String, excluding marker: String) -> String {
        let ignored: Set<String> = [
            marker.lowercased(), "location-name", "preiod-name", "period-name",
            "active", "open", "closed", "col", "row", "hidden", "show", "menu", "item"
        ]
        let tokens = classAttribute
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !ignored.contains($0.lowercased()) }

        // Join every remaining token, not just the first. Cal Dining splits
        // names across classes ("preiod-name Summer Brunch"), so taking only
        // the first token loses the part that actually identifies the meal.
        guard !tokens.isEmpty else { return "" }
        let spaced = decodeEntities(tokens.joined(separator: " ").replacingOccurrences(of: "_", with: " "))
        // Collapse any runs of whitespace, e.g. "Spring - Brunch".
        return spaced
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Splits a period's body into its menu stations. Cal Dining wraps each
    /// station in `<div class="cat-name"><span>Station Name</span><ul>…</ul>`,
    /// so we cut the body at each `cat-name` marker and read the station name
    /// from the first `<span>` that follows. Everything up to the next marker
    /// is that station's body, ready for `recipeItems`.
    private static func stationBlocks(in html: String) -> [(name: String, body: String)] {
        let ns = html as NSString
        guard let regex = try? NSRegularExpression(pattern: "class\\s*=\\s*[\"']cat-name[\"']",
                                                    options: [.caseInsensitive]) else {
            return []
        }
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var result: [(name: String, body: String)] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            guard end > start else { continue }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let name = firstMatch(in: body, pattern: "<span[^>]*>([^<]{1,80})</span>")
                .map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            result.append((name: name, body: body))
        }
        return result
    }

    /// Pulls each dish out of `<li class="recip …" data-id=… data-menuid=…>
    /// <span>Name</span> …icons… </li>`, capturing its dietary tags, carbon
    /// rating and the keys needed to look up full nutrition later. `station` is
    /// the menu station these items belong to, stamped onto each dish.
    private static func recipeItems(in html: String, station: String) -> [MenuItem] {
        let pattern = "<li class=\"(recip[^\"]*)\"([^>]*)>\\s*<span[^>]*>([^<]{1,160})</span>(.*?)</li>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var items: [MenuItem] = []
        for match in matches {
            let classList = ns.substring(with: match.range(at: 1))
            let attributes = ns.substring(with: match.range(at: 2))
            let rawName = ns.substring(with: match.range(at: 3))
            let rest = ns.substring(with: match.range(at: 4))

            let name = decodeEntities(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count > 1, !seen.contains(name.lowercased()) else { continue }
            seen.insert(name.lowercased())

            let tags = Set(classList.split(separator: " ").compactMap { DietaryTag(className: String($0)) })
            let carbon = firstMatch(in: rest, pattern: "green_image/(low|med|high)\\.png")
                .flatMap { CarbonRating(rawValue: $0.lowercased()) }

            items.append(MenuItem(
                name: name,
                tags: tags,
                carbon: carbon,
                station: station,
                location: attributeValue("data-location", in: attributes) ?? "",
                recipeId: attributeValue("data-id", in: attributes) ?? "",
                menuId: attributeValue("data-menuid", in: attributes) ?? ""
            ))
        }
        return items
    }

    private static func attributeValue(_ name: String, in attributes: String) -> String? {
        firstMatch(in: attributes, pattern: "\(name)=\"([^\"]*)\"")
    }

    /// First capture group of `pattern` in `text`, or nil.
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        let map: [String: String] = [
            "&amp;": "&", "&#038;": "&", "&quot;": "\"", "&#034;": "\"",
            "&apos;": "'", "&#039;": "'", "&#8217;": "\u{2019}", "&#8216;": "\u{2018}",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8211;": "-", "&#8212;": "\u{2014}",
            "&eacute;": "é", "&#233;": "é"
        ]
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }
}
