import Foundation

// The game page (design_handoff_find_game_restaurant_retail, part A; web:
// FindGameSection in find-experience.service.ts). One game from ESPN in one
// of three states: before ("pre"), "live" and "final" (or "postponed").
// Fields the backend may leave out are optional, so a missing one hides its
// piece of the page rather than the page.

struct FindGameTeam: Decodable, Hashable {
    let id: String?
    let abbr: String
    let name: String
    let shortName: String?
    let record: String?
    /// "#0b162a"; nil draws the crest grey.
    let color: String?
    let rank: Int?
    /// "3rd in NFC North" (before the game only).
    let standing: String?

    var short: String {
        if let shortName, !shortName.isEmpty { return shortName }
        return name
    }
}

struct FindGameSection: Decodable {
    struct Venue: Decodable { let name: String?; let city: String? }
    struct Line: Decodable { let spread: String; let overUnder: String? }
    struct Score: Decodable { let away: String; let home: String }
    struct ByPeriod: Decodable {
        /// "quarter", "half" or "inning".
        let word: String?
        let count: Int
        let away: [String?]
        let home: [String?]
    }
    struct Live: Decodable {
        let period: Int?
        let clock: String?
        let detail: String?
        /// "home" or "away".
        let possession: String?
        let downDistance: String?
        let outs: Int?
    }
    struct Play: Decodable, Hashable {
        let teamAbbr: String
        let teamColor: String?
        let title: String
        let detail: String?
        let scoreAfter: String
    }
    struct Leader: Decodable, Hashable {
        let name: String
        let teamAbbr: String?
        let pos: String?
        let category: String?
        let line: String
    }
    struct Links: Decodable {
        let gamecast: String?
        let recap: String?
        let boxscore: String?
        let preview: String?
        let tickets: String?
    }
    struct Series: Decodable {
        struct Game: Decodable, Hashable {
            let id: String
            let number: Int
            let date: String?
            let status: String
            let result: String?
            let current: Bool?
        }
        let label: String
        let record: String?
        let games: [Game]
    }
    struct Past: Decodable, Hashable {
        let id: String
        let date: String?
        let venue: String?
        let result: String
        let recapUrl: String?
    }

    let id: String
    let league: String
    let leagueName: String?
    let round: String?
    let status: String
    let statusDetail: String?
    let start: String?
    let tv: String?
    let venue: Venue?
    let line: Line?
    let away: FindGameTeam
    let home: FindGameTeam
    let score: Score?
    let byPeriod: ByPeriod?
    let live: Live?
    let plays: [Play]?
    let leaders: [Leader]?
    let links: Links?
    let series: Series?
    let past: [Past]?
    let updatedAt: String?

    func team(_ side: String) -> FindGameTeam { side == "home" ? home : away }
}

/// A game watch: which game and which alerts (FindGameWatch on the web).
struct FindGameWatch: Codable, Hashable {
    struct Alerts: Codable, Hashable {
        var start: Bool
        var scores: Bool
        var final: Bool

        static let none = Alerts(start: false, scores: false, final: false)
        var isEmpty: Bool { !start && !scores && !final }
    }

    let league: String
    let eventId: String
    let alerts: Alerts
}
