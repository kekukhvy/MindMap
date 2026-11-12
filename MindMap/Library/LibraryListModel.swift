import Foundation

/// Sorting / search of the library list (pure; the browser and WP13's
/// Welcome screen use it).
enum LibrarySort: String, CaseIterable, Identifiable {
    case modified
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modified: return "Date Modified"
        case .title: return "Name"
        }
    }
}

enum LibraryListModel {
    /// Maps matching `search` (every word must occur in the title; case
    /// and diacritics ignored), sorted: modified = newest first, title =
    /// Finder order ("Map 2" before "Map 10"); ties by title then ID.
    static func items(_ maps: [MapSummary], search: String, sort: LibrarySort) -> [MapSummary] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = words.isEmpty ? maps : maps.filter { map in
            words.allSatisfy { map.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return matching.sorted { a, b in
            switch sort {
            case .modified:
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                if da != db { return da > db }
            case .title:
                break
            }
            let order = a.title.localizedStandardCompare(b.title)
            if order != .orderedSame { return order == .orderedAscending }
            return a.idString < b.idString
        }
    }
}

extension MapSummary {
    /// Stable tie-breaker.
    var idString: String {
        switch location {
        case let .library(id): return id.uuidString
        case let .file(url): return url.path
        }
    }

    var libraryID: UUID? {
        if case let .library(id) = location { return id }
        return nil
    }
}
