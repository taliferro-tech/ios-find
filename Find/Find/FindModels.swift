import Foundation

// An unrecognized queryType decodes to `.unknown` rather than throwing, so a
// future backend addition can't fail decoding of the whole response the way
// `local`/`conversion` did before this enum knew about them (see
// FindSourceType.unknown below for the same reasoning).
enum FindQueryType: Codable, Hashable {
    case entity
    case question
    case person
    case weather
    case conversion
    case instant
    case local
    case movie
    case sports
    case news
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "entity": self = .entity
        case "question": self = .question
        case "person": self = .person
        case "weather": self = .weather
        case "conversion": self = .conversion
        case "instant": self = .instant
        case "local": self = .local
        case "movie": self = .movie
        case "sports": self = .sports
        case "news": self = .news
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .entity: try container.encode("entity")
        case .question: try container.encode("question")
        case .person: try container.encode("person")
        case .weather: try container.encode("weather")
        case .conversion: try container.encode("conversion")
        case .instant: try container.encode("instant")
        case .local: try container.encode("local")
        case .movie: try container.encode("movie")
        case .sports: try container.encode("sports")
        case .news: try container.encode("news")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

struct FindWeatherForecastDay: Codable, Hashable {
    let date: String
    let label: String
    let condition: String
    let description: String?
    let iconUrl: String?
    let highF: Double?
    let lowF: Double?
}

struct FindWeatherInfo: Codable, Hashable {
    let location: String
    let latitude: Double?
    let longitude: Double?
    let postalCode: String?
    let timezone: String?
    let tempF: Double
    let feelsLikeF: Double
    let condition: String
    let description: String
    let iconUrl: String
    let humidity: Double
    let windMph: Double
    let highF: Double?
    let lowF: Double?
    let updatedAt: String?
    let forecast: [FindWeatherForecastDay]?
}

enum FindConversionCategory: String, Codable {
    case currency
    case temperature
    case distance
    case weight
    case length
    case volume
    case speed
    case area
    case data
}

struct FindConversionResult: Codable, Hashable {
    let category: FindConversionCategory
    let inputAmount: Double
    let inputUnit: String
    let inputUnitLabel: String?
    let outputAmount: Double
    let outputUnit: String
    let outputUnitLabel: String?
    let rate: Double?
    let rateUpdatedAt: String?
    let source: String?
    /// Every supported currency against inputUnit (backend conversions only).
    var rates: [String: Double]? = nil
    /// Every unit in the category with its factor to the base unit (backend unit conversions).
    var unitOptions: [FindUnitOption]? = nil
}

struct FindUnitOption: Codable, Hashable {
    let value: String
    let label: String
    let factor: Double?
}

/// An exact answer Find works out itself: date math, tips, percentages,
/// sunrise/sunset (FindInstantAnswer in find-experience.service.ts).
struct FindInstantAnswer: Codable, Hashable {
    let kind: String
    let label: String
    let value: String
    let title: String
    let detail: String?
}

// OMDb details the backend attaches to a `movie` answer (results is empty).
struct FindMovieRatings: Codable, Hashable {
    let title: String
    let year: String?
    let rated: String?
    let runtime: String?
    let genre: String?
    let director: String?
    let actors: String?
    let plot: String?
    let posterUrl: String?
    let imdbRating: String?
    let imdbVotes: String?
    let imdbId: String?
    let metascore: String?
    let rottenTomatoesScore: String?
}

struct FindBusinessHoursPeriod: Codable, Hashable {
    let open: String
    let close: String
}

struct FindBusinessHoursDay: Codable, Hashable {
    let day: String
    let periods: [FindBusinessHoursPeriod]
    let isClosed: Bool?
    let isTwentyFourHours: Bool?
}

struct FindBusinessHours: Codable, Hashable {
    let timezone: String?
    let isOpenNow: Bool?
    let statusText: String?
    let days: [FindBusinessHoursDay]
    let holidayNotes: [String]?
    let sourceUrl: String?
}

// New source types (like `crowdsourced`) will keep arriving from the
// backend as it grows — decoding an unrecognized raw value to `.unknown`
// instead of throwing keeps a single unfamiliar result from failing
// decoding for the entire response.
enum FindSourceType: Codable, Hashable {
    case official
    case publisher
    case government
    case academic
    case medical
    case encyclopedia
    case crowdsourced
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "official": self = .official
        case "publisher": self = .publisher
        case "government": self = .government
        case "academic": self = .academic
        case "medical": self = .medical
        case "encyclopedia": self = .encyclopedia
        case "crowdsourced": self = .crowdsourced
        default: self = .unknown(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .official: try container.encode("official")
        case .publisher: try container.encode("publisher")
        case .government: try container.encode("government")
        case .academic: try container.encode("academic")
        case .medical: try container.encode("medical")
        case .encyclopedia: try container.encode("encyclopedia")
        case .crowdsourced: try container.encode("crowdsourced")
        case .unknown(let raw): try container.encode(raw)
        }
    }
}

struct FindAnswerReference: Codable, Identifiable, Hashable {
    var id: String { url }
    let title: String
    let url: String
    let displayUrl: String
    let sourceType: FindSourceType
}

struct FindAnswerBlock: Codable, Hashable {
    let text: String
    let imageUrl: String?
    let references: [FindAnswerReference]
}

struct FindRankedResult: Codable, Identifiable, Hashable {
    var id: String { url }
    var rank: Int
    let title: String
    let summary: String
    let answer: String?
    let url: String
    let displayUrl: String
    let imageUrl: String
    let sourceType: FindSourceType
    let confidence: Double
    let pills: [String]
    let isFirstParty: Bool
    let hours: FindBusinessHours?
    // Set on local-business (Places) results.
    let address: String?
    let phone: String?
    // Every verified location of a business that has more than one.
    let locations: [FindBusinessLocation]?
    // "Why this result": short reasons the page doesn't already show.
    let reasons: [String]?
    // Set on News/Sports headlines served from the hourly RSS snapshot.
    let rssSource: String?
    let publishedAt: String?

    // isFirstParty is absent on RSS-backed results (e.g. queryType "news") -
    // the web app's FindRankedResult interface already marks it `?:
    // boolean` for exactly this reason. A synthesized Decodable would throw
    // keyNotFound and fail the entire search for those query types.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try container.decode(Int.self, forKey: .rank)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
        url = try container.decode(String.self, forKey: .url)
        displayUrl = try container.decode(String.self, forKey: .displayUrl)
        imageUrl = try container.decode(String.self, forKey: .imageUrl)
        sourceType = try container.decode(FindSourceType.self, forKey: .sourceType)
        confidence = try container.decode(Double.self, forKey: .confidence)
        pills = try container.decode([String].self, forKey: .pills)
        isFirstParty = try container.decodeIfPresent(Bool.self, forKey: .isFirstParty) ?? false
        hours = try container.decodeIfPresent(FindBusinessHours.self, forKey: .hours)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        locations = try container.decodeIfPresent([FindBusinessLocation].self, forKey: .locations)
        reasons = try container.decodeIfPresent([String].self, forKey: .reasons)
        rssSource = try container.decodeIfPresent(String.self, forKey: .rssSource)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
    }
}

extension FindRankedResult {
    /// A News/Sports headline the app fetched itself (HeadlineFeeds), shaped
    /// like the backend's RSS results.
    init(headlineTitle: String, summary: String, url: String, imageUrl: String, source: String, publishedAt: String, rank: Int = 0) {
        self.rank = rank
        self.title = headlineTitle
        self.summary = summary
        self.answer = nil
        self.url = url
        self.displayUrl = source
        self.imageUrl = imageUrl
        self.sourceType = .publisher
        self.confidence = 0.95
        self.pills = []
        self.isFirstParty = false
        self.hours = nil
        self.address = nil
        self.phone = nil
        self.locations = nil
        self.reasons = nil
        self.rssSource = source
        self.publishedAt = publishedAt
    }

    /// The same result at a new position (after merging headlines).
    func withRank(_ rank: Int) -> FindRankedResult {
        var copy = self
        copy.rank = rank
        return copy
    }
}

struct FindBusinessLocation: Codable, Hashable {
    let name: String
    let address: String
    let phone: String?
    let mapsUrl: String?
    var distance: String?
    /// The location's own (public) position, for "How far?" on the device.
    let latitude: Double?
    let longitude: Double?
}

struct FindSearchHandoff: Codable, Hashable {
    let route: String
    let query: String
}

struct FindSearchTimings: Codable, Hashable {
    let totalMs: Int
    let planMs: Int
    let enrichMs: Int
    let summarizeMs: Int
    let candidateCount: Int
    let enrichedCount: Int
}

struct FindSearchResponse: Codable, Hashable {
    let success: Bool
    let query: String
    let normalizedQuery: String
    let queryType: FindQueryType
    let handoff: FindSearchHandoff?
    let answer: FindAnswerBlock?
    let weather: FindWeatherInfo?
    let conversion: FindConversionResult?
    let movieRatings: FindMovieRatings?
    let results: [FindRankedResult]
    let selectedIndex: Int
    let timings: FindSearchTimings?
    // True when the results are News/Sports headlines from the RSS snapshot.
    let rssBacked: Bool?
    // True for shopping searches; shows the 16Ahead Store strip under the result.
    var shoppingIntent: Bool? = nil
    var instant: FindInstantAnswer? = nil
    /// What this search earned (Find Score), when the backend recorded it.
    var score: FindScoreAward? = nil
    /// Daily Find: this search counted toward today's question.
    var daily: FindDailySearch? = nil
}

// MARK: - Daily Find (backend findDaily.service.js; web find-daily.service.ts)

struct FindDailySearch: Codable, Hashable {
    let date: String
    let searches: Int
}

struct FindDailyResult: Codable, Hashable {
    let choice: Int
    let correct: Bool
    let answerIndex: Int
    let points: Int
    let beat: Int?
    let explanation: String
    let sourceUrl: String
    let sourceTitle: String
}

struct FindDailyState: Codable, Hashable {
    let available: Bool
    let date: String
    var question: String? = nil
    /// "new", "playing" or "answered".
    var status: String? = nil
    var searches: Int? = nil
    /// Only after the first search.
    var choices: [String]? = nil
    var result: FindDailyResult? = nil
    /// What answering earned (Find Score), on the answer reply only.
    var score: FindScoreAward? = nil
}

struct FindDailyRequest: Encodable {
    let deviceId: String
    let timeZone: String
    var date: String? = nil
    var choice: Int? = nil
}

struct FindDailyResponse: Decodable {
    let daily: FindDailyState
}

struct FindSearchRequest: Encodable {
    let query: String
    let context: String?
    let maxResults: Int
    let postalCode: String?
    let latitude: Double?
    let longitude: Double?
    // The user's time zone, and the answer types this app can show; the
    // backend leaves newer types out for app versions that can't.
    let timeZone: String
    let features: [String]
    /// Results first: ask the backend for one message per line while it works.
    var stream: Bool? = nil
    /// Find Score: the backend adds this phone's points for the search.
    var deviceId: String? = nil
    /// Daily Find: a search made while playing today's question.
    var dailyDate: String? = nil
}

/// What a streamed search sends while it works (results first): the stage
/// it's on, the web search's cards before any page is checked, then the full
/// response (web: FindSearchEvent in find-experience.service.ts).
enum FindSearchEvent {
    case stage(String, pageCount: Int)
    case results(FindSearchResponse)
    case final(FindSearchResponse)
}

enum FindFeedbackRating: String, Encodable, CaseIterable {
    case excellent, good, fair, poor

    var label: String { rawValue.capitalized }
}

struct FindFeedbackRequest: Encodable {
    let rating: FindFeedbackRating
    let comment: String?
    let query: String?
    let queryType: String?
    var deviceId: String? = nil
    var timeZone: String? = nil
}

struct FindFeedbackResponse: Decodable {
    let success: Bool?
    var score: FindScoreAward? = nil
}

// MARK: - Find Score (web: find-experience.service.ts; backend findScore.service.js)

struct FindScoreBadge: Codable, Hashable, Identifiable {
    let id: String
    let group: String
    var title: String
    var copy: String
    var icon: String
    var hidden: Bool? = nil
    var goal: String? = nil
    var state: String? = nil
    var earnedAt: Double? = nil
}

struct FindRankNext: Codable, Hashable {
    let name: String
    let min: Int
    let toGo: Int
}

struct FindRank: Codable, Hashable {
    let name: String
    let min: Int
    let level: Int
    let next: FindRankNext?
}

/// What one search, rating or card earned.
struct FindScoreAward: Codable, Hashable {
    let points: Int
    let total: Int
    let weekScore: Int
    let rank: FindRank
    let rankUp: String?
    let streak: Int
    var usedFreeMiss: Bool? = nil
    let newBadges: [FindScoreBadge]
}

struct FindScoreStreak: Codable, Hashable {
    var count: Int
    var best: Int
    var lastDay: String
}

struct FindScoreProfile: Codable, Hashable {
    var nickname: String
    var hasNickname: Bool
    let publicCode: String
    var score: Int
    var weekScore: Int
    var rank: FindRank
    var streak: FindScoreStreak
    var searchCount: Int
    var imported: Bool
    var hasRecoveryCode: Bool
    let shareUrl: String
    var badges: [FindScoreBadge]
}

struct FindScoreRequest: Encodable {
    let deviceId: String
    var nickname: String? = nil
    var code: String? = nil
    var count: Int? = nil
    var badges: [FindScoreImportBadge]? = nil
    var timeZone: String? = nil
    var ref: String? = nil
}

struct FindScoreImportBadge: Encodable {
    let id: String
    let title: String
    let icon: String
}

struct FindScoreProfileResponse: Decodable {
    let profile: FindScoreProfile
}

struct FindScoreRecoveryResponse: Decodable {
    let code: String
}

/// A watched result (FindWatch in find-experience.service.ts).
struct FindWatch: Decodable, Identifiable, Hashable {
    let id: String
    let query: String
    let url: String
    let title: String
    let kind: String
    let createdAt: Double
    let expiresAt: Double
    let expired: Bool
    let lastCheckedAt: Double?
    let lastChange: FindWatchChange?
    let changed: Bool
    let current: String
}

struct FindWatchChange: Decodable, Hashable {
    let at: Double
    let summary: String
}

struct FindWatchRequest: Encodable {
    let deviceId: String
    var id: String? = nil
    var query: String? = nil
    var url: String? = nil
    var title: String? = nil
    var queryType: String? = nil
    var address: String? = nil
    var phone: String? = nil
    var apnsToken: String? = nil
    var environment: String? = nil
}

struct FindWatchResponse: Decodable {
    let success: Bool
    let watch: FindWatch?
    let watches: [FindWatch]?
    let message: String?
}

struct FindShareRequest: Encodable {
    let query: String
    let title: String
    let summary: String
    let url: String
    let displayUrl: String
    let imageUrl: String
    /// Find Score: opens of the link earn this phone's player points.
    var deviceId: String? = FindDevice.id
}

struct FindShareResponse: Decodable {
    let success: Bool
    let url: String?
}

struct FindFollowupRequest: Encodable {
    let query: String
    let followup: String
    let url: String
    let title: String
    let sourceUrls: [String]
}

/// A follow-up question about one result (FindFollowupResponse in
/// find-experience.service.ts). mode "search" means run searchQuery instead.
struct FindFollowupResponse: Decodable, Hashable {
    let success: Bool
    let mode: String
    let answered: Bool
    let answer: String
    let sources: [FindFollowupSource]
    let searchQuery: String
}

struct FindFollowupSource: Decodable, Hashable {
    let title: String
    let url: String
    let displayUrl: String
}

struct FindSummarizeRequest: Encodable {
    let query: String
    let url: String
    let title: String
}

struct FindSummarizeResponse: Decodable {
    let answer: String
}
