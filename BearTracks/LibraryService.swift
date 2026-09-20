//
//  LibraryService.swift
//  BearTracks
//
//  The UC Berkeley Library publishes today's hours for every branch on one
//  server-rendered page (the ucberk.li/hours shortlink):
//
//      https://www.lib.berkeley.edu/hours
//
//  Each library is a <li class="library-hours-listing" data-nid="...">, and
//  inside it the name, open/closed status, today's hours, address and a Google
//  Maps link all sit in stable, named classes:
//
//      <div class="library-open-status"> ... Open</div>
//      <h3 class="library-name"><a href="/visit/…">Name</a></h3>
//      <p class="library-hours">11 a.m.-5 p.m.</p>
//      <p class="library-hours-listing-address">…<br>510-642-7361</p>
//      <a class="google-maps-link" href="https://…">
//
//  The page only serves today (its date picker is an AJAX form), so this is a
//  "right now" view. Verified against the live page: 29 libraries parse cleanly.
//

import Foundation

// MARK: - Model

struct Library: Identifiable, Hashable {
    /// The page's Drupal node id, stable per branch.
    let id: String
    let name: String
    /// The branch's photo from the hours page, already cropped to a uniform
    /// aspect ratio by the site's "library_hours_image" image style.
    let imageURL: URL?
    /// The branch's page on lib.berkeley.edu, e.g. /visit/doe.
    let pageURL: URL?
    /// Today's hours exactly as the site prints them, e.g. "11 a.m.-5 p.m.".
    /// Empty when the branch is closed or hasn't posted hours.
    let hoursToday: String
    let isOpen: Bool
    let address: String
    let phone: String?
    let mapsURL: URL?

    /// What to show on the hours line, never blank.
    var hoursDisplay: String {
        if !hoursToday.isEmpty { return hoursToday }
        return isOpen ? "Open" : "Closed today"
    }

    var statusText: String { isOpen ? "Open" : "Closed" }

    /// The name shown in the UI. A couple of branches get a friendlier label
    /// than the site's official name.
    var displayName: String {
        switch name {
        case "Engineering & Mathematical Sciences Library":
            return "Grimes (Engineering & Mathematical Sciences Library)"
        default:
            return name
        }
    }
}

// MARK: - Errors

enum LibraryServiceError: LocalizedError {
    case badResponse(Int)
    case unreadable
    case noneFound

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "The Library site returned status \(code)."
        case .unreadable:
            return "Couldn't read the page the Library sent back."
        case .noneFound:
            return "The Library's hours page loaded but no branches were found in it. They may have changed their layout."
        }
    }
}

struct LibraryFetchResult {
    let libraries: [Library]
    /// When the fetch completed, for the "updated …" line.
    let fetchedAt: Date
}

// MARK: - Service

struct LibraryService {

    private static let base = "https://www.lib.berkeley.edu"
    private static let hoursPath = "https://www.lib.berkeley.edu/hours"

    static let hoursPageURL = URL(string: hoursPath)!

    /// The URL for a given day. The hours page is a Drupal view whose exposed
    /// date filter also accepts a `hours_date_select=YYYY-MM-DD` query
    /// parameter, so any day can be fetched with a plain GET.
    private static func hoursURL(for date: Date) -> URL {
        var components = URLComponents(string: hoursPath)!
        components.queryItems = [
            URLQueryItem(name: "hours_date_select", value: dateFormatter.string(from: date))
        ]
        return components.url ?? hoursPageURL
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func fetchHours(for date: Date = Date()) async throws -> LibraryFetchResult {
        var request = URLRequest(url: hoursURL(for: date))
        request.timeoutInterval = 30
        // The site is a Drupal front end; a real UA keeps it from serving a
        // stripped page to an unknown client.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if !(200...299).contains(status) {
            throw LibraryServiceError.badResponse(status)
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw LibraryServiceError.unreadable
        }

        let libraries = parse(html: html)
        guard !libraries.isEmpty else { throw LibraryServiceError.noneFound }

        return LibraryFetchResult(libraries: libraries, fetchedAt: Date())
    }

    // MARK: - Parsing

    static func parse(html: String) -> [Library] {
        // Everything after the marker up to the next listing is one branch.
        let blocks = splitListings(in: html)

        return blocks.compactMap { block -> Library? in
            guard let name = firstGroup(
                in: block,
                pattern: "library-name\"><a[^>]*>(.*?)</a>"
            ).map(cleanText), !name.isEmpty else { return nil }

            let href = firstGroup(in: block, pattern: "library-name\"><a[^>]*href=\"([^\"]+)\"")
            let hours = firstGroup(in: block, pattern: "library-hours\">(.*?)</p>").map(hoursText) ?? ""
            let statusText = firstGroup(in: block, pattern: "library-open-status\">(.*?)</div>").map(cleanText) ?? ""
            let addressRaw = firstGroup(in: block, pattern: "library-hours-listing-address\">(.*?)</p>") ?? ""
            let mapsHref = firstGroup(in: block, pattern: "google-maps-link[^>]*href=\"([^\"]+)\"")
            let imageHref = firstGroup(in: block, pattern: "library-hours-listing-image\">\\s*<img[^>]*\\ssrc=\"([^\"]+)\"")
            let nid = firstGroup(in: block, pattern: "^\\s*data-nid=\"(\\d+)\"")

            return Library(
                id: nid ?? name,
                name: name,
                imageURL: absoluteURL(from: imageHref),
                pageURL: absoluteURL(from: href),
                hoursToday: hours,
                isOpen: statusText.lowercased().contains("open"),
                address: readableAddress(addressRaw, dropping: name),
                phone: phone(in: addressRaw),
                mapsURL: mapsHref.flatMap { URL(string: $0) }
            )
        }
    }

    /// Splits the page on the listing marker; each piece is one library's markup.
    private static func splitListings(in html: String) -> [String] {
        let marker = "<li class=\"library-hours-listing\""
        var pieces = html.components(separatedBy: marker)
        guard pieces.count > 1 else { return [] }
        pieces.removeFirst() // text before the first listing
        return pieces
    }

    // MARK: - Field helpers

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func absoluteURL(from href: String?) -> URL? {
        guard let href, !href.isEmpty else { return nil }
        if href.hasPrefix("http") { return URL(string: href) }
        return URL(string: base + href)
    }

    private static func phone(in addressHTML: String) -> String? {
        firstGroup(in: addressHTML, pattern: "(\\d{3}-\\d{3}-\\d{4})")
    }

    /// Turns the address fragment into readable multi-line text, dropping a
    /// leading line that just repeats the branch name and the trailing phone
    /// (shown on its own row instead).
    private static func readableAddress(_ html: String, dropping name: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)

        var lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.first == name { lines.removeFirst() }
        lines.removeAll { $0.range(of: "\\d{3}-\\d{3}-\\d{4}", options: .regularExpression) != nil }
        return lines.joined(separator: "\n")
    }

    /// The hours line, cleaned for display. The site puts a second part after a
    /// `<br>` (e.g. "24 hours<br>Starts at 1pm. Cal ID required"), which would
    /// otherwise run straight into the times once the tags come out, so the
    /// break becomes a visible separator. The Cal ID access note is dropped.
    nonisolated private static func hoursText(_ html: String) -> String {
        let separated = html.replacingOccurrences(of: "<br\\s*/?>", with: " · ",
                                                  options: [.regularExpression, .caseInsensitive])
        return removingCalIDNote(cleanText(separated))
    }

    /// Strips the "Cal ID required" building-access note from an hours line,
    /// along with the separator or sentence punctuation it leaves behind. The
    /// note appears on many branches in several wordings ("Cal ID required
    /// after 7pm", "Graduate Student Cal ID required for access").
    nonisolated private static func removingCalIDNote(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "[^·.]*\\bcal id\\b[^·.]*", with: "",
                                            options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "·\\s*·", with: "·", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s*·\\s*$", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a now-dangling sentence period, but never the one in "a.m."/"p.m.".
        out = out.replacingOccurrences(of: "(?<![ap]\\.m)\\.$", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Pure string helpers: `nonisolated` so they can be passed to `.map` and
    // called from any context (the type builds under MainActor default isolation).
    nonisolated private static func cleanText(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = decodeEntities(out)
        // Some lines glue a following word onto a closing time
        // (e.g. "5 p.m.Doe only"); restore the missing space.
        out = out.replacingOccurrences(of: "([ap]\\.m\\.)([A-Za-z])", with: "$1 $2",
                                       options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "[ \t\n]+", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeEntities(_ text: String) -> String {
        var out = text
        let map: [String: String] = [
            "&amp;": "&", "&#038;": "&", "&quot;": "\"", "&#034;": "\"",
            "&apos;": "'", "&#039;": "'", "&#8217;": "\u{2019}", "&#8216;": "\u{2018}",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8211;": "-", "&ndash;": "-",
            "&#8212;": "\u{2014}", "&mdash;": "\u{2014}", "&eacute;": "é", "&#233;": "é"
        ]
        for (entity, replacement) in map {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }
}
