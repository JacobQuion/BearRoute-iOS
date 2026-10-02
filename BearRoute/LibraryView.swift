//
//  LibraryView.swift
//  Bear Route
//

import SwiftUI
import Combine

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var libraries: [Library] = []
    @Published private(set) var fetchedAt: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var searchText = ""
    @Published var openNowOnly = false

    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    /// Whether the selected day is today, which is when "open now" and live
    /// status still make sense.
    var isViewingToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    /// A week-long window around today, matching the Dining tab's day picker.
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
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    /// The marquee branches, pinned to the top of the list in this order
    /// regardless of the usual open-first sort.
    static let pinnedNames = [
        "Doe Library",
        "Main (Gardner) Stacks",
        "Moffitt Library",
        "Engineering & Mathematical Sciences Library",  // shown as "Grimes (…)"
        "East Asian Library",
        "Business Library"
    ]

    /// A library's position among the pinned branches, or a value past the end
    /// for everything else — so pinned ones sort first, in listed order.
    private func pinnedRank(_ library: Library) -> Int {
        Self.pinnedNames.firstIndex(of: library.name) ?? Self.pinnedNames.count
    }

    /// Branches matching the search box and the "open now" toggle. Doe, Main
    /// Stacks and Moffitt are pinned to the top; the rest follow with open ones
    /// first and then alphabetically.
    var filtered: [Library] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return libraries
            .filter { library in
                if openNowOnly && !library.isOpen { return false }
                guard !query.isEmpty else { return true }
                return library.name.lowercased().contains(query)
                    || library.displayName.lowercased().contains(query)
                    || library.address.lowercased().contains(query)
            }
            .sorted { lhs, rhs in
                let lhsRank = pinnedRank(lhs), rhsRank = pinnedRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.isOpen != rhs.isOpen { return lhs.isOpen && !rhs.isOpen }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var openCount: Int { libraries.filter(\.isOpen).count }

    var updatedText: String? {
        guard let fetchedAt else { return nil }
        let day = isViewingToday ? "today's hours" : "hours for \(dateLabel.lowercased())"
        return "Updated \(fetchedAt.formatted(date: .omitted, time: .shortened)) · \(day)"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await LibraryService.fetchHours(for: selectedDate)
            libraries = result.libraries
            fetchedAt = result.fetchedAt
        } catch {
            libraries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Screen

struct LibraryView: View {
    /// Supplied by `ContentView`, which starts loading it during the splash.
    @ObservedObject var model: LibraryViewModel
    @State private var selected: Library?

    /// True while re-fetching hours for a freshly picked day, which drives the
    /// animated skeleton so the switch reads as "loading" rather than stale.
    @State private var isSwitchingDay = false

    var body: some View {
        NavigationStack {
            Group {
                if (model.libraries.isEmpty && model.isLoading) || isSwitchingDay {
                    LibraryLoadingView(dayLabel: model.dateLabel)
                        .transition(.opacity)
                } else if let errorMessage = model.errorMessage, model.libraries.isEmpty {
                    errorState(errorMessage)
                } else {
                    list
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isSwitchingDay)
            .navigationTitle("Libraries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(item: $selected) { library in
                LibraryDetailView(library: library)
            }
            .refreshable { await model.load() }
            .onChange(of: model.selectedDate) { _, _ in
                isSwitchingDay = true
                Task {
                    await model.load()
                    isSwitchingDay = false
                }
            }
            .task {
                // The prefetch in ContentView usually covers this; only load here
                // if it hasn't run (and isn't already in flight).
                if model.libraries.isEmpty && !model.isLoading { await model.load() }
            }
        }
    }

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A single top row mirroring the Dining tab: a compact day selector on the
    /// left and an inline library search field on the right.
    private var searchDayBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Day", selection: $model.selectedDate) {
                    ForEach(model.selectableDates, id: \.self) { date in
                        Text(LibraryViewModel.label(for: date)).tag(date)
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
                TextField("Search libraries", text: $model.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isSearching {
                    Button {
                        model.searchText = ""
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
    }

    private var list: some View {
        List {
            Section {
                searchDayBar
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Picker("Show", selection: $model.openNowOnly) {
                    Text("All (\(model.libraries.count))").tag(false)
                    Text("\(model.isViewingToday ? "Open now" : "Open") (\(model.openCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 2, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(model.filtered) { library in
                    Button {
                        selected = library
                    } label: {
                        row(for: library)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(CardList.rowInsets)
                }
            } footer: {
                if let updated = model.updatedText {
                    Text(updated)
                }
            }
        }
        // Tighten the gap between the filter section and the first library card.
        .listSectionSpacing(8)
        // Trim the List's default top inset so the day/search bar sits closer
        // to the "Libraries" title, matching the Dining tab.
        .contentMargins(.top, 6, for: .scrollContent)
    }

    private func row(for library: Library) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryImage(url: library.imageURL, height: 130)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    HStack(spacing: 5) {
                        Text(library.statusText)
                            .foregroundStyle(library.isOpen ? Color.green : Color.secondary)
                        if !library.hoursToday.isEmpty {
                            Text("· \(library.hoursToday)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(Theme.californiaGold)
            Text("Couldn't reach the Library")
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

// MARK: - Loading

/// An animated skeleton shown while hours load — either on first launch or when
/// the user picks a different day. Placeholder cards mirror the real row layout
/// and a light sweep glides across them so the wait reads as lively, not frozen.
struct LibraryLoadingView: View {
    let dayLabel: String

    /// Drives the sweeping highlight; animates continuously while visible.
    @State private var sweep = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading hours for \(dayLabel.lowercased())")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                ForEach(0..<4, id: \.self) { _ in
                    card
                }
            }
            .padding(16)
        }
        .disabled(true)
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            block(height: 130)
            block(height: 14).frame(width: 170)
            block(height: 12).frame(width: 110)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.10))
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Image

/// A small in-memory cache of decoded branch photos, keyed by URL. Backed by
/// `NSCache`, so it evicts itself under memory pressure. Lets an already-seen
/// photo render immediately when its row is rebuilt (scrolling, day changes)
/// instead of dropping back to a placeholder while it re-decodes.
@MainActor
enum ImageMemoryCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// Loads and displays a remote image, serving already-decoded ones from
/// `ImageMemoryCache` synchronously so there's no placeholder flash on reuse.
/// Falls back to the `placeholder` while a first-time image downloads.
struct CachedImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
        // Seed synchronously from the cache so a known image shows on first frame.
        _image = State(initialValue: url.flatMap { ImageMemoryCache.image(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, image == nil else { return }
        if let cached = ImageMemoryCache.image(for: url) {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return }
        ImageMemoryCache.store(decoded, for: url)
        image = decoded
    }
}

/// A branch photo cropped to a uniform size, so every row and header lines up
/// regardless of the source image's dimensions. Shows a themed placeholder
/// while loading or if the image is missing.
struct LibraryImage: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Theme.card)
            .frame(height: height)
            .overlay {
                CachedImage(url: url) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.californiaGold.opacity(0.6))
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

// MARK: - Detail

struct LibraryDetailView: View {
    let library: Library

    var body: some View {
        List {
            Section {
                LibraryImage(url: library.imageURL, height: 180)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: library.isOpen ? "circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(library.isOpen ? Color.green : Color.secondary)
                    Text(library.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(library.isOpen ? Color.green : Color.secondary)
                    Spacer()
                    Text(library.hoursDisplay)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Today")
                    .foregroundStyle(Theme.heading)
                    .textCase(nil)
            }

            if !library.address.isEmpty {
                Section {
                    Text(library.address)
                        .font(.subheadline)
                        .textSelection(.enabled)
                } header: {
                    Text("Address")
                        .foregroundStyle(Theme.heading)
                        .textCase(nil)
                }
            }

            Section {
                if let appleMapsURL {
                    linkRow(icon: "map.fill", title: "Directions in Apple Maps", url: appleMapsURL)
                }
                if let phone = library.phone, let telURL = URL(string: "tel:\(phone.filter { $0.isNumber })") {
                    linkRow(icon: "phone", title: phone, url: telURL)
                }
                if let pageURL = library.pageURL {
                    linkRow(icon: "safari", title: "Library page", url: pageURL)
                }
            }
        }
        .navigationTitle(library.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A native Apple Maps directions link to the branch, built from its name and
    /// address so users aren't forced into a third-party maps app.
    private var appleMapsURL: URL? {
        let cleanedAddress = library.address.replacingOccurrences(of: "\n", with: ", ")
        let destination = cleanedAddress.isEmpty ? library.name : "\(library.name), \(cleanedAddress)"
        var components = URLComponents(string: "http://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "daddr", value: destination)]
        return components?.url
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.californiaGold)
                    .frame(width: 22)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    LibraryView(model: LibraryViewModel())
}
