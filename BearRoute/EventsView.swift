//
//  EventsView.swift
//  Bear Route
//

import SwiftUI
import Combine
import MapKit

@MainActor
final class EventsViewModel: ObservableObject {
    @Published private(set) var events: [CampusEvent] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    @Published var searchText = ""
    @Published var selectedType: String?
    @Published var range: EventRange = .everything

    enum EventRange: String, CaseIterable, Identifiable {
        case everything = "All Events"
        case today = "Today"
        case all = "Near Future"

        var id: String { rawValue }
    }

    var availableTypes: [String] {
        Array(Set(events.flatMap(\.types))).sorted()
    }

    var filteredEvents: [CampusEvent] {
        var result = events

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let today = calendar.startOfDay(for: Date())

        switch range {
        case .everything:
            // Everything from today onward.
            result = result.filter { $0.day >= today }
        case .today:
            result = result.filter { calendar.isDate($0.day, inSameDayAs: today) }
        case .all:
            // "Near Future" is everything from tomorrow on, so today's events
            // drop out.
            result = result.filter { $0.day > today }
        }

        if let selectedType {
            result = result.filter { $0.types.contains(selectedType) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.title.lowercased().contains(query)
                || ($0.location?.lowercased().contains(query) ?? false)
                || ($0.group?.lowercased().contains(query) ?? false)
            }
        }

        return result
    }

    /// Filtered events bucketed into days, oldest first.
    var groupedByDay: [(day: Date, events: [CampusEvent])] {
        Dictionary(grouping: filteredEvents, by: \.day)
            .map { (day: $0.key, events: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.day < $1.day }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            events = try await EventsService.fetchUpcoming()
            if events.isEmpty {
                errorMessage = "The campus events feed came back empty."
            }
        } catch {
            events = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    static func dayLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }

        let f = DateFormatter()
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }
}

struct EventsView: View {
    @StateObject private var model = EventsViewModel()
    @State private var selected: CampusEvent?

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.events.isEmpty {
                    ProgressView("Loading campus events")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = model.errorMessage {
                    errorState(message)
                } else {
                    eventList
                }
            }
            .navigationTitle("Campus Events")
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
            .sheet(item: $selected) { event in
                EventDetailView(event: event)
            }
            .refreshable { await model.load() }
            .task {
                if model.events.isEmpty { await model.load() }
            }
        }
    }

    // MARK: - Search

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An inline search field sitting above the category chips, matching the
    /// capsule style used on the Dining and Library tabs.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Search events", text: $model.searchText)
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

    // MARK: - Category filter

    // Hosted as the first row of the events List rather than a `.safeAreaInset`:
    // inside a TabView, an inset's content could vanish after switching tabs and
    // coming back. As a List row the bar shares the List's lifecycle, so it stays
    // put and simply scrolls with the content.
    private var typeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: model.selectedType == nil) {
                    model.selectedType = nil
                }
                ForEach(model.availableTypes, id: \.self) { type in
                    chip(title: type, isSelected: model.selectedType == type) {
                        model.selectedType = model.selectedType == type ? nil : type
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected
                        ? Theme.control
                        : Color.primary.opacity(0.14))
                )
                .overlay(
                    // A hairline keeps unselected chips legible in both appearances.
                    Capsule().stroke(isSelected ? Color.clear : Color.primary.opacity(0.22),
                                     lineWidth: 1)
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var eventList: some View {
        List {
            Section {
                searchField
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                typeBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(model.groupedByDay, id: \.day) { group in
                Section {
                    ForEach(group.events) { event in
                        Button {
                            selected = event
                        } label: {
                            EventRow(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(EventsViewModel.dayLabel(group.day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isToday(group.day) ? Theme.readableBlue : Theme.heading)
                        .textCase(nil)
                }
            }

            if model.groupedByDay.isEmpty {
                Text("Nothing matches those filters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        // Trim the List's default top inset so the search bar sits closer to
        // the "Campus Events" title.
        .contentMargins(.top, 6, for: .scrollContent)
        // Tighten the gap between the search/chips section and the first event.
        .listSectionSpacing(8)
    }

    /// Matches `dayLabel`'s Pacific-time calendar, so this agrees with the
    /// "Today" header text.
    private func isToday(_ day: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar.isDateInToday(day)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(Theme.californiaGold)
            Text("Events unavailable")
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

// MARK: - Row

struct EventRow: View {
    let event: CampusEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(event.isCanceled ? .secondary : .primary)
                    .strikethrough(event.isCanceled)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(event.shortDateText)
                    Image(systemName: "clock")
                    Text(event.timeText)
                    if event.isOnline {
                        Text("· Online")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let location = event.location {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(location).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !event.types.isEmpty {
                    Text(event.primaryType)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.californiaGold.opacity(0.28)))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

struct EventDetailView: View {
    let event: CampusEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(event.title)
                        .font(.title3.weight(.bold))

                    if event.isCanceled {
                        Label("This event has been canceled", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        detailRow(icon: "calendar", text: fullDateText)
                        detailRow(icon: "clock", text: event.timeText)
                        if let location = event.location {
                            detailRow(icon: "mappin.and.ellipse", text: location)
                        }
                        if let group = event.group {
                            detailRow(icon: "building.columns", text: group)
                        }
                        if let cost = event.cost {
                            detailRow(icon: "ticket", text: cost)
                        }
                        if event.isOnline {
                            detailRow(icon: "video", text: "Online event")
                        }
                    }

                    if let coordinate = event.coordinate {
                        Map(initialPosition: .region(
                            MKCoordinateRegion(
                                center: coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                            )
                        )) {
                            Marker(event.location ?? event.title, coordinate: coordinate)
                                .tint(Theme.control)
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                    }

                    if !event.summary.isEmpty {
                        Divider()
                        Text(event.summary)
                            .font(.subheadline)
                    }

                    if let url = event.url {
                        Link(destination: url) {
                            Label("Open on events.berkeley.edu", systemImage: "safari")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var fullDateText: String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: event.start)
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.heading)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    EventsView()
}
