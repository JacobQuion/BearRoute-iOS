//
//  EventsService.swift
//  Bear Route
//
//  UC Berkeley's events calendar runs on LiveWhale, which exposes a public
//  JSON feed. Arguments are path segments, not query strings:
//
//      /live/json/events/max/100/response_fields/location,summary,...
//
//  Verified against the live feed, including field names and value shapes.
//

import Foundation
import CoreLocation

// MARK: - Model

struct CampusEvent: Identifiable, Hashable {
    /// A recurring event reuses its numeric id on every occurrence, so the
    /// start timestamp is folded in to keep each row uniquely identifiable.
    let id: String
    let title: String
    let url: URL?
    let start: Date
    let end: Date?
    let isAllDay: Bool
    let isCanceled: Bool
    let isOnline: Bool
    let location: String?
    let group: String?
    let summary: String
    let types: [String]
    let thumbnailURL: URL?
    let latitude: Double?
    let longitude: Double?
    let cost: String?

    var primaryType: String { types.first ?? "Event" }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var timeText: String {
        if isAllDay { return "All day" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "h:mm a"

        let startText = f.string(from: start)
        if let end, end > start {
            return "\(startText) - \(f.string(from: end))"
        }
        return startText
    }

    /// Short month and day, e.g. "Jul 31", in Berkeley's timezone.
    var shortDateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "MMM d"
        return f.string(from: start)
    }

    /// Midnight in Berkeley's timezone, used to group events into days.
    var day: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar.startOfDay(for: start)
    }
}

// MARK: - Raw decoding

private struct EventsEnvelope: Decodable {
    let data: [RawEvent]
}

/// LiveWhale is loose about types: a flag can be `1`, `"1"` or `true`, and a
/// number can arrive quoted. These wrappers accept whatever shows up so one
/// odd row can't take down the whole decode.
private struct LooseBool: Decodable {
    let value: Bool
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int != 0 }
        else if let text = try? container.decode(String.self) {
            value = text == "1" || text.lowercased() == "true"
        } else { value = false }
    }
}

private struct LooseInt: Decodable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = Int(double) }
        else if let text = try? container.decode(String.self) { value = Int(text) }
        else { value = nil }
    }
}

private struct LooseDouble: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) { value = double }
        else if let text = try? container.decode(String.self) { value = Double(text) }
        else { value = nil }
    }
}

private struct LooseString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let int = try? container.decode(Int.self) { value = String(int) }
        else if let double = try? container.decode(Double.self) { value = String(double) }
        else { value = nil }
    }
}

private struct RawEvent: Decodable {
    let id: LooseInt?
    let title: String?
    let url: String?
    let date_ts: LooseInt?
    let date2_ts: LooseInt?
    let is_all_day: LooseBool?
    let is_canceled: LooseBool?
    let is_online: LooseBool?
    let location: LooseString?
    let location_title: LooseString?
    let location_latitude: LooseDouble?
    let location_longitude: LooseDouble?
    let group_title: LooseString?
    let summary: String?
    let event_types: [String]?
    let thumbnail: String?
    let cost: LooseString?
}

// MARK: - Errors

enum EventsServiceError: LocalizedError {
    case badResponse(code: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code, let body):
            let detail = body.isEmpty ? "" : "\n\nServer said: \(body)"
            return "The campus events feed returned status \(code).\(detail)"
        case .decoding(let detail):
            return "Couldn't read the events feed: \(detail)"
        }
    }
}

// MARK: - Service

struct EventsService {

    private static let base = "https://events.berkeley.edu/live/json/events"
    private static let fields = "location,summary,event_types,group_title,image"

    nonisolated(unsafe) static var lastRequestedURL = ""

    static func fetchUpcoming(max: Int = 150) async throws -> [CampusEvent] {
        let urlText = "\(base)/max/\(max)/response_fields/\(fields)"
        guard let url = URL(string: urlText) else {
            throw EventsServiceError.decoding("Bad URL")
        }
        lastRequestedURL = urlText

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw EventsServiceError.badResponse(code: http.statusCode, body: body)
        }

        let envelope: EventsEnvelope
        do {
            envelope = try JSONDecoder().decode(EventsEnvelope.self, from: data)
        } catch {
            throw EventsServiceError.decoding(error.localizedDescription)
        }

        let events: [CampusEvent] = envelope.data.enumerated().compactMap { index, raw in
            guard let timestamp = raw.date_ts?.value else { return nil }
            let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }

            let endDate: Date? = raw.date2_ts?.value.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }

            return CampusEvent(
                id: "\(raw.id?.value ?? index)-\(timestamp)",
                title: decodeHTML(title),
                url: raw.url.flatMap { URL(string: $0) },
                start: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                end: endDate,
                isAllDay: raw.is_all_day?.value ?? false,
                isCanceled: raw.is_canceled?.value ?? false,
                isOnline: raw.is_online?.value ?? false,
                location: nonEmpty(raw.location?.value) ?? nonEmpty(raw.location_title?.value),
                group: nonEmpty(raw.group_title?.value),
                summary: strippingHTML(raw.summary ?? ""),
                types: raw.event_types ?? [],
                thumbnailURL: raw.thumbnail.flatMap { URL(string: $0) },
                latitude: raw.location_latitude?.value,
                longitude: raw.location_longitude?.value,
                cost: nonEmpty(raw.cost?.value)
            )
        }

        return events.sorted { $0.start < $1.start }
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Summaries arrive as HTML fragments, so flatten them to readable text.
    static func strippingHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeHTML(text)
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeHTML(_ text: String) -> String {
        var out = text
        let map: [String: String] = [
            "&amp;": "&", "&#038;": "&", "&quot;": "\"", "&#034;": "\"",
            "&apos;": "'", "&#039;": "'", "&#8217;": "\u{2019}", "&#8216;": "\u{2018}",
            "&#8220;": "\u{201C}", "&#8221;": "\u{201D}", "&lt;": "<", "&gt;": ">",
            "&nbsp;": " ", "&#8211;": "-", "&#8212;": "\u{2014}", "&hellip;": "…"
        ]
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }
}
