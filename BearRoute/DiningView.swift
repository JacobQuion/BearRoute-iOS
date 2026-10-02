//
//  DiningView.swift
//  Bear Route
//

import SwiftUI
import Combine

@MainActor
final class DiningViewModel: ObservableObject {
    @Published private(set) var locations: [DiningLocation] = []
    @Published private(set) var diagnostics = DiningDiagnostics()
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var selectedDate: Date
    @Published var selectedHall: DiningHall = DiningHall.all[0]

    /// The day the picker was last moved to on its own. Lets the 9 PM
    /// rollover tell "the user is riding along with the default day" apart
    /// from "the user picked a day", so a deliberate choice is never yanked.
    /// Published so the rollover notice appears the moment the cutoff fires.
    @Published private var autoSelectedDate: Date

    /// True while the picker is showing tomorrow's menu because the 9 PM
    /// cutoff passed, so the screen can explain why it isn't today's.
    /// `autoSelectedDate` is only ever today or tomorrow, so being later than
    /// today means the rollover kicked in.
    var isShowingRolloverMenu: Bool {
        selectedDate == autoSelectedDate
            && autoSelectedDate > Calendar.current.startOfDay(for: Date())
    }

    init() {
        let day = DiningViewModel.defaultDate()
        selectedDate = day
        autoSelectedDate = day
    }

    /// When a dish is tapped from the notable list, the meal label to
    /// auto-expand once its hall menu opens. Consumed (cleared) by
    /// `MenuResultView` after it expands the matching meal.
    @Published var focusedMeal: String? = nil

    /// Diet chips the user requires; a dish must carry every one of them.
    @Published var activeDiets: Set<DietaryTag> = []

    /// Allergens the user wants to steer clear of; any dish carrying one is
    /// hidden.
    @Published var avoidAllergens: Set<DietaryTag> = []

    /// The diet filters offered, shown as fixed buttons.
    static let dietFilters: [DietaryTag] = [.vegan, .vegetarian, .halal, .kosher]

    /// An allergen button, which can stand for more than one underlying tag —
    /// "No Nut" has to cover peanuts and tree nuts alike.
    struct AllergenFilter: Identifiable, Hashable {
        let id: String
        let label: String
        let tags: Set<DietaryTag>
    }

    /// The allergen filters offered ("No …"), shown as fixed buttons.
    static let allergenFilters: [AllergenFilter] = [
        .init(id: "dairy", label: "Dairy", tags: [.dairy]),
        .init(id: "nut", label: "Nut", tags: [.peanut, .treenut])
    ]

    func isAvoiding(_ filter: AllergenFilter) -> Bool {
        filter.tags.isSubset(of: avoidAllergens)
    }

    func toggle(_ filter: AllergenFilter) {
        if isAvoiding(filter) {
            avoidAllergens.subtract(filter.tags)
        } else {
            avoidAllergens.formUnion(filter.tags)
        }
    }

    var hasActiveFilters: Bool { !activeDiets.isEmpty || !avoidAllergens.isEmpty }

    /// Whether a dish satisfies the active diet requirements and carries none
    /// of the avoided allergens.
    func passesFilters(_ item: MenuItem) -> Bool {
        activeDiets.isSubset(of: item.tags) && item.tags.isDisjoint(with: avoidAllergens)
    }

    /// Dish-name fragments hidden from a hall's browsed menu — staples and
    /// sides (bagels, yogurt, plain rice, …) that clutter the list. Matched
    /// as case-insensitive substrings. Only applied to the hall menu browse,
    /// not the cross-hall search, so these can still be searched for by name.
    static let hiddenKeywords: [String] = [
        "bagel", "cream", "capers", "oatmeal", "brown rice", "jasmine rice",
        "sauteed mushroom vegetable blend", "yogurt", "seeds", "dressing",
        "salad", "hummus", "mung bean", "sliced almond", "mini", "base",
        "lettuce", "red beets", "carrots", "cucumbers", "grape tomato",
        "quinoa", "cruton", "crouton", "vinegar", "balsamic", "vegan cheese",
        "green olive", "butter", "granola", "cranberry", "flakes",
        "basmati rice", "basil", "black olive", "olive oil", "pickle",
        "spinach", "sliced cucumber", "cherry tomatoes", "sliced radish",
        "raisins", "vinaigrette", "nutritional yeast", "syrup",
        "sliced tomato", "sliced red onion", "strawberry jelly",
        "gold beets", "steamed beets", "carrot sticks", "red radishes",
        "heirloom tomato", "paprika rosemary tofu", "garbanzo beans"
    ]

    static func isHidden(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return hiddenKeywords.contains { lowered.contains($0) }
    }

    /// Items to show when browsing a hall's menu: the period's dishes with
    /// staple sides hidden to cut clutter and the active diet/allergen filters
    /// applied.
    func displayItems(in period: MenuPeriod) -> [MenuItem] {
        period.items.filter { !Self.isHidden($0.name) && passesFilters($0) }
    }

    /// Every dish across every hall whose name matches `query`, grouped by hall
    /// (dining commons first), with the same staple-hiding truncation as the
    /// browsed hall menu.
    func dishSections(matching query: String) -> [(hall: DiningHall, hits: [DishHit])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        var sections: [(DiningHall, [DishHit])] = []
        for hall in DiningHall.all {
            guard let location = location(for: hall) else { continue }
            var hits: [DishHit] = []
            for period in location.labeledPeriods {
                for item in displayItems(in: period.period) where item.name.lowercased().contains(q) {
                    hits.append(DishHit(item: item, hall: hall, meal: period.label))
                }
            }
            if !hits.isEmpty { sections.append((hall, hits)) }
        }
        return sections
    }

    // MARK: Notable items

    /// Standout dishes worth surfacing at the top of the tab. Each entry is
    /// matched loosely: a multi-word keyword only needs every word to appear
    /// somewhere in the dish name, so "pesto pasta" catches "Penne Pasta with
    /// Pesto" and "tri tip" catches both "Tri-Tip" and "TriTip".
    static let notableKeywords: [String] = [
        "baked pork bacon", "tri tip", "salmon", "lobster", "pesto", "alfredo", "fettucini", "marinara"
    ]

    /// Words that disqualify a dish even if it matches a notable keyword, so a
    /// "salmon sandwich" or "pesto sauce" doesn't get surfaced as a standout.
    static let notableExclusions: [String] = ["sandwich", "sauce", "bisque", "meatball"]

    /// Dishes that are always notable, even if they contain an excluded word
    /// (e.g. "Chicken Alfredo Sauce" carries "sauce" but is a real entrée).
    static let notableAllowlist: [String] = ["chicken alfredo sauce", "pesto alfredo sauce", "alfredo sauce"]

    static func isNotable(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if notableAllowlist.contains(where: { lowered.contains($0) }) { return true }
        guard !notableExclusions.contains(where: { lowered.contains($0) }) else { return false }
        return notableKeywords.contains { keyword in
            keyword.split(separator: " ").allSatisfy { lowered.contains($0) }
        }
    }

    /// The notable dishes one hall is serving on the selected day, sorted by
    /// when they're served — breakfast first, then lunch, then dinner.
    /// Duplicates of the same dish within a meal are collapsed.
    func notableDishes(at hall: DiningHall) -> [DishHit] {
        guard let location = location(for: hall) else { return [] }
        var hits: [DishHit] = []
        var seen = Set<String>()
        for period in location.labeledPeriods {
            for item in period.period.items where Self.isNotable(item.name) {
                let key = "\(item.name.lowercased())|\(period.label)"
                guard seen.insert(key).inserted else { continue }
                hits.append(DishHit(item: item, hall: hall, meal: period.label))
            }
        }
        return hits.sorted {
            MealKind(periodName: $0.meal).sortOrder < MealKind(periodName: $1.meal).sortOrder
        }
    }

    // MARK: Lookups

    func location(for hall: DiningHall) -> DiningLocation? {
        locations.first { hall.matches($0.name) }
    }

    var menuForSelection: DiningLocation? { location(for: selectedHall) }

    /// Every meal the selected hall is serving that day, in serving order and
    /// already labelled breakfast / lunch / dinner.
    var labeledPeriods: [DiningLocation.LabeledPeriod] {
        menuForSelection?.labeledPeriods ?? []
    }

    /// Halls the page actually returned a menu for.
    var hallsWithMenus: [DiningHall] {
        DiningHall.all.filter { hall in locations.contains { hall.matches($0.name) } }
    }

    /// The residential dining commons, shown as their own cards.
    var diningCommons: [DiningHall] { DiningHall.all.filter(\.isResidential) }

    /// Everything else — the retail cafés and markets — grouped under a single
    /// "Campus Eateries" entry.
    var campusEateries: [DiningHall] { DiningHall.all.filter { !$0.isResidential } }

    // MARK: Dates

    /// Berkeley's time zone. The 9 PM cutoff below is campus time, so the day
    /// flips at the same moment for everyone regardless of device settings.
    static let campusTimeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

    /// Dinner service is done by 9 PM, so from then on the menu worth showing
    /// is tomorrow's.
    static let rolloverHour = 21

    /// The day the tab opens to: today, or tomorrow once the 9 PM campus-time
    /// cutoff has passed.
    static func defaultDate(now: Date = Date()) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        guard hasPassedRollover(now) else { return today }
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Whether it's 9 PM or later in Berkeley right now.
    static func hasPassedRollover(_ now: Date = Date()) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = campusTimeZone
        return calendar.component(.hour, from: now) >= rolloverHour
    }

    /// The next moment the cutoff fires. Always strictly in the future, so
    /// the watch loop below can't spin.
    static func nextRollover(after now: Date = Date()) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = campusTimeZone
        let cutoff = DateComponents(hour: rolloverHour, minute: 0, second: 0)
        return calendar.nextDate(after: now, matching: cutoff, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }

    /// Advances to tomorrow's menu if the cutoff has passed since the last
    /// check. A hand-picked day is left where the user put it.
    func refreshDefaultDate() {
        let target = Self.defaultDate()
        guard target != autoSelectedDate else { return }
        let wasFollowingDefault = selectedDate == autoSelectedDate
        autoSelectedDate = target
        if wasFollowingDefault { selectedDate = target }
    }

    /// Sleeps until the next 9 PM cutoff, rolls the day forward, then waits
    /// for the one after — so a session left open past 9 doesn't sit on a
    /// stale menu. Backgrounded time is covered by the scene-phase check in
    /// `DiningView`, since sleeping tasks don't run while suspended.
    func watchForRollover() async {
        while !Task.isCancelled {
            let delay = Self.nextRollover().timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(delay, 1)))
            guard !Task.isCancelled else { return }
            refreshDefaultDate()
        }
    }

    var selectableDates: [Date] {
        (-1...6).compactMap {
            Calendar.current.date(byAdding: .day, value: $0,
                                  to: Calendar.current.startOfDay(for: Date()))
        }
    }

    var dateLabel: String { Self.label(for: selectedDate) }

    static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await DiningService.fetchMenus(for: selectedDate)
            locations = result.locations
            diagnostics = result.diagnostics
        } catch {
            locations = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// A single matching dish from a cross-hall search: the dish, which hall it's
/// at, and which meal it's served in.
struct DishHit: Identifiable, Hashable {
    let id = UUID()
    let item: MenuItem
    let hall: DiningHall
    let meal: String
}

// MARK: - Picker screen

struct DiningView: View {
    /// Supplied by `ContentView`, whose top-bar gear offers Diagnostics for it.
    @ObservedObject var model: DiningViewModel
    /// Bumped by the top bar's refresh button.
    @Environment(\.refreshToken) private var refreshToken
    @State private var showingMenu = false
    @State private var showingEateries = false
    @State private var searchText = ""

    @Environment(\.scenePhase) private var scenePhase

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                searchDayBar

                if model.isShowingRolloverMenu {
                    RolloverNotice()
                }

                if isSearching {
                    searchResults
                } else {
                    hallBrowser
                }
            }
            .navigationTitle("Dining")
            .navigationBarTitleDisplayMode(.inline)
            // The app's top bar already names the section and carries refresh
            // and settings, so the root screen drops its own bar. Pushed
            // screens (hall menus) still show theirs, with the back button.
            .toolbar(.hidden, for: .navigationBar)
            // Each hall card is its own section, so section spacing is what
            // separates the thumbnails — tighten it from the default gap.
            .listSectionSpacing(8)
            // A set top inset so the day/search bar sits a short, even gap
            // below the app's blue top bar.
            .contentMargins(.top, 18, for: .scrollContent)
            .navigationDestination(isPresented: $showingMenu) {
                MenuResultView(model: model)
            }
            .navigationDestination(isPresented: $showingEateries) {
                CampusEateriesView(model: model, showMenu: $showingMenu)
            }
            .refreshable { await model.load() }
            .onChange(of: model.selectedDate) { _, _ in
                Task { await model.load() }
            }
            .onChange(of: refreshToken) { _, _ in
                Task { await model.load() }
            }
            .task {
                if model.locations.isEmpty { await model.load() }
            }
            .task { await model.watchForRollover() }
            // Catches a cutoff that passed while the app was backgrounded,
            // when the sleeping watch task wasn't running.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshDefaultDate() }
            }
        }
    }

    // MARK: Search + day bar

    /// A single top row: a compact day selector on the left and a dish search
    /// field on the right. Persists across both the hall browser and search
    /// results so the search field never disappears mid-query.
    private var searchDayBar: some View {
        Section {
            HStack(spacing: 10) {
                Menu {
                    Picker("Day", selection: $model.selectedDate) {
                        ForEach(model.selectableDates, id: \.self) { date in
                            Text(DiningViewModel.label(for: date)).tag(date)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.footnote)
                        Text(model.dateLabel)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.primary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Search dishes", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isSearching {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Hall browser

    /// Every hall card — the dining commons, then the campus-eateries entry —
    /// in a single section, so they stack flush against one another as one
    /// connected list instead of separate floating cards.
    private var hallBrowser: some View {
        Section {
            ForEach(model.diningCommons) { hall in
                Button {
                    model.selectedHall = hall
                    showingMenu = true
                } label: {
                    hallCard(for: hall)
                }
                .buttonStyle(.plain)
                .listRowInsets(CardList.rowInsets)
            }

            Button {
                showingEateries = true
            } label: {
                eateriesCard
            }
            .buttonStyle(.plain)
            .listRowInsets(CardList.rowInsets)
        } footer: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text("Cal Dining: \"menus are subject to change.\"")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: Campus eateries card

    /// A single entry standing in for every retail café and market, tapped to
    /// open the full list.
    private var eateriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiningImage(url: nil, assetName: "CampusEateriesBanner", height: 130)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Campus Restaurants")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(eateriesSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A short teaser of the eateries, e.g. "Golden Bear Café, Brown's & 5 more".
    private var eateriesSubtitle: String {
        let names = model.campusEateries.map(\.name)
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) & \(names.count - 2) more"
    }

    // MARK: Cross-hall search

    @ViewBuilder
    private var searchResults: some View {
        let sections = model.dishSections(matching: searchText)

        TruncationNotice()

        if model.locations.isEmpty && model.isLoading {
            Section { ProgressView("Loading menus") }
        } else if sections.isEmpty {
            Section {
                Text("No dishes match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))” on \(model.dateLabel.lowercased()).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(sections, id: \.hall.id) { section in
                Section {
                    ForEach(section.hits) { hit in
                        Button {
                            model.selectedHall = hit.hall
                            showingMenu = true
                        } label: {
                            dishHitRow(hit)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(section.hall.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.readableBlue)
                        .textCase(nil)
                }
            }
        }
    }

    private func dishHitRow(_ hit: DishHit) -> some View {
        HStack {
            Text(hit.item.name)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(hit.meal)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.californiaGold)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: Hall card

    private func hallCard(for hall: DiningHall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DiningImage(url: hall.imageURL, assetName: hall.assetName, height: 130)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hall.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: hall))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What to show under the hall name: the meals it's serving today, or a
    /// gentle note when nothing's posted.
    private func subtitle(for hall: DiningHall) -> String {
        if model.isLoading && model.locations.isEmpty { return "Loading menu…" }
        if let summary = model.location(for: hall)?.mealSummary, !summary.isEmpty {
            return summary
        }
        return "No menu posted"
    }
}

// MARK: - Campus eateries

/// The full list of retail cafés and markets, reached from the single
/// "Campus Eateries" card on the Dining screen. Tapping one opens its menu.
struct CampusEateriesView: View {
    @ObservedObject var model: DiningViewModel
    @Binding var showMenu: Bool

    var body: some View {
        List {
            Section {
                ForEach(model.campusEateries) { hall in
                    Button {
                        model.selectedHall = hall
                        showMenu = true
                    } label: {
                        card(for: hall)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Campus Restaurants")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(for hall: DiningHall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DiningImage(url: hall.imageURL, assetName: hall.assetName, height: 130)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hall.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: hall))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(for hall: DiningHall) -> String {
        if model.isLoading && model.locations.isEmpty { return "Loading menu…" }
        if let summary = model.location(for: hall)?.mealSummary, !summary.isEmpty {
            return summary
        }
        return "No menu posted"
    }
}

// MARK: - Image

/// A hall photo cropped to a uniform size, mirroring the Library tab's cards.
struct DiningImage: View {
    let url: URL?
    var assetName: String? = nil
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Theme.card)
            .frame(height: height)
            .overlay {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .empty:
                            ProgressView()
                        default:
                            Image(systemName: "fork.knife")
                                .font(.system(size: 30))
                                .foregroundStyle(Theme.californiaGold.opacity(0.6))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1.5)
            )
    }
}

// MARK: - Menu result

struct MenuResultView: View {
    @ObservedObject var model: DiningViewModel

    /// Meal sections the user has expanded. Empty means everything starts
    /// collapsed; tapping a meal header toggles its id in here.
    @State private var expandedMeals: Set<UUID> = []

    private var periods: [DiningLocation.LabeledPeriod] { model.labeledPeriods }

    /// The meals that actually have something to show once staples are hidden
    /// and diet filters applied, each paired with its visible items. Filtering
    /// here — rather than inside the `ForEach` — keeps SwiftUI from leaving a
    /// blank ghost section behind when a meal's items are all filtered out.
    private var visiblePeriods: [(entry: DiningLocation.LabeledPeriod, items: [MenuItem])] {
        periods.compactMap { entry in
            let items = model.displayItems(in: entry.period)
            return items.isEmpty ? nil : (entry, items)
        }
    }

    /// A fingerprint of exactly what the menu list is showing. Applied as the
    /// List's `.id`, it forces a clean rebuild whenever the hall, date, or the
    /// filtered item set changes — so SwiftUI never diffs a shrinking `ForEach`
    /// and leaves phantom blank rows where hidden items used to be.
    private var menuSignature: String {
        let shape = visiblePeriods
            .map { "\($0.entry.id):\($0.items.count)" }
            .joined(separator: ",")
        let filters = model.activeDiets.map(\.rawValue).sorted().joined(separator: "+")
            + "/" + model.avoidAllergens.map(\.rawValue).sorted().joined(separator: "+")
        return "\(model.selectedHall.id)|\(model.selectedDate.timeIntervalSince1970)|\(filters)|\(shape)"
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Loading menu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage {
                errorState(errorMessage)
            } else if periods.isEmpty {
                emptyState
            } else {
                menuList
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.selectedHall.name)
                        .font(.headline)
                    Text(model.dateLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { expandFocusedMeal() }
    }

    /// If the menu was opened by tapping a notable dish, expand the meal that
    /// dish is served in so the user lands right on it. Clears the request so
    /// it doesn't re-fire on a later, unrelated visit.
    private func expandFocusedMeal() {
        guard let focus = model.focusedMeal else { return }
        if let match = periods.first(where: { $0.label == focus }) {
            expandedMeals.insert(match.id)
        }
        model.focusedMeal = nil
    }

    // MARK: Menu

    private var menuList: some View {
        List {
            Section {
                DiningImage(url: model.selectedHall.imageURL,
                            assetName: model.selectedHall.assetName,
                            height: 170)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if model.isShowingRolloverMenu {
                RolloverNotice()
            }

            Section {
                filterBar
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                TruncationNoticeRow()
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filters")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.readableBlue)
                .textCase(nil)
            }

            notableSection

            ForEach(visiblePeriods, id: \.entry.id) { entry, items in
                let isExpanded = expandedMeals.contains(entry.id)
                Section {
                    if isExpanded {
                        ForEach(MenuPeriod.groupedByStation(items)) { station in
                            if !station.name.isEmpty {
                                StationHeaderRow(name: station.name)
                            }
                            ForEach(station.items) { item in
                                MenuItemRow(item: item)
                            }
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            if isExpanded { expandedMeals.remove(entry.id) }
                            else { expandedMeals.insert(entry.id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.symbol)
                            Text(entry.label)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.readableBlue)
                        .textCase(nil)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.hasActiveFilters && visiblePeriods.isEmpty {
                Text("Nothing here matches those filters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .id(menuSignature)
    }

    // MARK: Notable items

    /// This hall's standout dishes (steak, salmon, lobster, …) for the day,
    /// sitting above the meal drop-downs so they're the first thing seen on
    /// opening a hall. Tapping one expands the meal it's served in.
    @ViewBuilder
    private var notableSection: some View {
        let dishes = model.notableDishes(at: model.selectedHall)

        Section {
            if dishes.isEmpty {
                Text("Nothing much. It's a Flex/Flex+ day!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dishes) { hit in
                    Button {
                        expand(meal: hit.meal)
                    } label: {
                        notableRow(hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Label("Notable Dishes", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.notableGold)
                .textCase(nil)
        }
    }

    private func notableRow(_ hit: DishHit) -> some View {
        HStack(spacing: 10) {
            Text(hit.item.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(hit.meal)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.californiaGold)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Opens the drop-down for `label`, so a tapped notable dish leads
    /// straight to the meal serving it.
    private func expand(meal label: String) {
        guard let match = periods.first(where: { $0.label == label }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            expandedMeals.insert(match.id)
        }
    }

    // MARK: Filters

    private static let filterColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8), count: 3
    )

    private static let avoidRed = Color(red: 0.78, green: 0.22, blue: 0.22)

    /// A fixed grid of six always-visible filter buttons: diet buttons narrow
    /// the menu to dishes that carry the tag; "No …" allergen buttons hide any
    /// dish that carries the tag.
    private var filterBar: some View {
        LazyVGrid(columns: Self.filterColumns, spacing: 8) {
            ForEach(DiningViewModel.dietFilters) { diet in
                filterButton(diet.label, symbol: diet.symbol,
                             isOn: model.activeDiets.contains(diet),
                             onColor: .green) {
                    toggle(diet, in: \.activeDiets)
                }
            }
            ForEach(DiningViewModel.allergenFilters) { allergen in
                filterButton("No \(allergen.label)", symbol: "nosign",
                             isOn: model.isAvoiding(allergen),
                             onColor: Self.avoidRed) {
                    model.toggle(allergen)
                }
            }
        }
    }

    private func toggle(_ tag: DietaryTag,
                        in keyPath: ReferenceWritableKeyPath<DiningViewModel, Set<DietaryTag>>) {
        if model[keyPath: keyPath].contains(tag) {
            model[keyPath: keyPath].remove(tag)
        } else {
            model[keyPath: keyPath].insert(tag)
        }
    }

    private func filterButton(_ text: String, symbol: String, isOn: Bool,
                              onColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(isOn ? onColor : Color.primary.opacity(0.10)))
            .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty

    /// Never a dead end. If the exact pick has nothing, show what Cal Dining
    /// is actually serving so there's always a way forward.
    private var emptyState: some View {
        List {
            if model.isShowingRolloverMenu {
                RolloverNotice()
            }

            Section {
                VStack(spacing: 10) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.californiaGold)
                    Text("Nothing posted for \(model.selectedHall.name)")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Cal Dining hasn't published a menu here for \(model.dateLabel.lowercased()).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            if !model.hallsWithMenus.isEmpty {
                Section {
                    ForEach(model.hallsWithMenus) { hall in
                        Button {
                            model.selectedHall = hall
                        } label: {
                            HStack {
                                Text(hall.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Open elsewhere")
                } footer: {
                    Text("Tap a location to jump to its menu.")
                }
            }

            Section {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Link(destination: URL(string: "https://dining.berkeley.edu/menus/")!) {
                    Label("Open Cal Dining site", systemImage: "safari")
                }
            }
        }
    }

    // MARK: Error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(Theme.californiaGold)
            Text("Couldn't reach Cal Dining")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.control)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Truncation notice

/// A short note explaining the menu is trimmed to standout dishes. Pinned at
/// the top of both the cross-hall search and each hall's menu.
struct TruncationNotice: View {
    var body: some View {
        Section {
            TruncationNoticeRow()
        }
        .listRowBackground(Color.clear)
    }
}

/// The bare notice row, so it can also sit inside another section (e.g. right
/// under the filter buttons) without the extra inter-section spacing.
struct TruncationNoticeRow: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.californiaGold)
            Text("Staples like yogurt and salads are hidden for brevity.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Rollover notice

/// Shown after the 9 PM cutoff, when the tab has swapped in tomorrow's menus,
/// so nobody mistakes them for what's being served tonight.
struct RolloverNotice: View {
    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.notableGold)
                Text("Dining halls are closed for the day, so tomorrow's menus have been slotted in.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Station header row

/// A small station label (e.g. "Center Plate", "Griddle/Grill") that sits above
/// the dishes served at it, mirroring the way Cal Dining groups a meal's menu.
struct StationHeaderRow: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.californiaGold)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .listRowSeparator(.hidden)
    }
}

// MARK: - Menu item row

/// A dish with its serving size and macros. The numbers come from a per-dish
/// recipe lookup, so each row fetches its own once it scrolls into view and
/// shows just the name until they land.
struct MenuItemRow: View {
    let item: MenuItem

    @State private var facts: NutritionFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name)
                    .font(.subheadline)
                if let serving = facts?.servingSize, !serving.isEmpty {
                    Text(serving)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = facts?.macroSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 2)
        .task { await loadFacts() }
    }

    private func loadFacts() async {
        guard facts == nil, item.hasNutritionLookup else { return }
        facts = try? await NutritionCache.shared.facts(for: item)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = text }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    DiningView(model: DiningViewModel())
}
