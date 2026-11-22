import Foundation

/// This phone's anonymous Find ID: Watches and Find Score both use it.
enum FindDevice {
    static var id: String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "find.deviceId") { return saved }
        let created = UUID().uuidString
        defaults.set(created, forKey: "find.deviceId")
        return created
    }
}

enum FindAPIError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    /// The backend's own reason ("Please pick a different nickname.").
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server response could not be understood."
        case .httpError(let code):
            return "The server returned HTTP \(code)."
        case .server(let message):
            return message
        }
    }
}

// Immutable after init (config, coder instances), so cards can call it from any task.
final class FindAPIClient: @unchecked Sendable {
    private let config: AppConfig
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(config: AppConfig) {
        self.config = config
    }

    func search(
        query: String,
        context: String? = nil,
        maxResults: Int = 10,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async throws -> FindSearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = FindSearchRequest(
            query: trimmedQuery,
            context: context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            maxResults: min(max(maxResults, 1), 10),
            postalCode: Self.extractPostalCode(from: trimmedQuery),
            latitude: latitude,
            longitude: longitude,
            timeZone: TimeZone.current.identifier,
            features: ["instant", "units"]
        )

        return try await post(path: "find/search", payload: payload, responseType: FindSearchResponse.self)
    }

    /// The same search, results first: `onEvent` gets the stage and the
    /// early cards as they arrive; returns the full response (the same one
    /// `search` returns). A backend that doesn't stream just sends that
    /// response, which is read the same way.
    func searchStream(
        query: String,
        context: String? = nil,
        maxResults: Int = 10,
        latitude: Double? = nil,
        longitude: Double? = nil,
        dailyDate: String? = nil,
        onEvent: @escaping @MainActor (FindSearchEvent) -> Void
    ) async throws -> FindSearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = FindSearchRequest(
            query: trimmedQuery,
            context: context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            maxResults: min(max(maxResults, 1), 10),
            postalCode: Self.extractPostalCode(from: trimmedQuery),
            latitude: latitude,
            longitude: longitude,
            timeZone: TimeZone.current.identifier,
            features: ["instant", "units"],
            stream: true,
            deviceId: FindDevice.id,
            dailyDate: dailyDate
        )
        var request = URLRequest(url: config.apiBaseURL.appending(path: "find/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FindAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw FindAPIError.httpError(http.statusCode) }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "stage":
                let stage = object["stage"] as? String ?? "planning"
                let pageCount = object["pageCount"] as? Int ?? 0
                await onEvent(.stage(stage, pageCount: pageCount))
            case "results":
                // Shaped as a response so the result pages can show it as is.
                let preview: [String: Any] = [
                    "success": true,
                    "query": object["query"] as? String ?? trimmedQuery,
                    "normalizedQuery": object["query"] as? String ?? trimmedQuery,
                    "queryType": object["queryType"] as? String ?? "entity",
                    "shoppingIntent": object["shoppingIntent"] as? Bool ?? false,
                    "results": object["results"] as? [Any] ?? [],
                    "selectedIndex": 0,
                ]
                if let previewData = try? JSONSerialization.data(withJSONObject: preview),
                   let decoded = try? decoder.decode(FindSearchResponse.self, from: previewData) {
                    await onEvent(.results(decoded))
                }
            case "final":
                guard let inner = object["response"] else { throw FindAPIError.invalidResponse }
                let finalResponse = try decoder.decode(FindSearchResponse.self, from: try JSONSerialization.data(withJSONObject: inner))
                await onEvent(.final(finalResponse))
                return finalResponse
            case "error":
                throw FindAPIError.invalidResponse
            default:
                // A plain JSON reply from a backend that didn't stream.
                let finalResponse = try decoder.decode(FindSearchResponse.self, from: data)
                await onEvent(.final(finalResponse))
                return finalResponse
            }
        }
        // The connection ended before the full response.
        throw FindAPIError.invalidResponse
    }

    // Mirrors extractPostalCode() in the web app's find-experience.service.ts
    // so a bare ZIP in the query text (e.g. "weather 98106") reaches the
    // backend's weather fast-path the same way regardless of which client
    // sent it.
    private static func extractPostalCode(from query: String) -> String? {
        let pattern = #"(?:^|\s)(\d{5})(?:-\d{4})?(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(query.startIndex..., in: query)
        guard let match = regex.firstMatch(in: query, range: range),
              let zipRange = Range(match.range(at: 1), in: query) else { return nil }
        return String(query[zipRange])
    }

    /// "Watch a find" endpoints (/find/watches…, /find/devices); all POSTs.
    func watch(_ path: String, _ payload: FindWatchRequest) async throws -> FindWatchResponse {
        try await post(path: path, payload: payload, responseType: FindWatchResponse.self)
    }

    /// A short find.16ahead.com/s/<id> link that previews a result.
    func share(_ payload: FindShareRequest) async throws -> FindShareResponse {
        try await post(path: "find/share", payload: payload, responseType: FindShareResponse.self)
    }

    func followup(_ payload: FindFollowupRequest) async throws -> FindFollowupResponse {
        try await post(path: "find/followup", payload: payload, responseType: FindFollowupResponse.self)
    }

    func summarize(query: String, url: String, title: String) async throws -> String {
        let payload = FindSummarizeRequest(query: query, url: url, title: title)
        let response = try await post(path: "find/summarize", payload: payload, responseType: FindSummarizeResponse.self)
        return response.answer
    }

    /// Is this query one thing (a team, a store, a country, a movie...)?
    /// Answers before the search finishes; nil means no card. `score` is
    /// what a new kind of card earned.
    func detectEntity(query: String) async throws -> FindEntityDetectResponse {
        let payload = FindEntityDetectRequest(query: query.trimmingCharacters(in: .whitespacesAndNewlines), cardTypes: EntityCardView.cardTypes)
        return try await post(path: "find/entity", payload: payload, responseType: FindEntityDetectResponse.self)
    }

    /// One section of a single-item card, as the raw JSON of its `data`
    /// (nil when the backend has none). Each section loads on its own so the
    /// card fills in as they arrive; the card decodes the shape it expects.
    func entitySection(_ entity: FindEntity, section: String, latitude: Double? = nil, longitude: Double? = nil) async throws -> Data? {
        let payload = FindEntitySectionRequest(type: entity.type, league: entity.league, id: entity.id, section: section, latitude: latitude, longitude: longitude)
        let data = try await postData(path: "find/entity/section", payload: payload)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = object["data"], !(section is NSNull) else { return nil }
        return try JSONSerialization.data(withJSONObject: section)
    }

    /// "Ask this store": the store's own 16Ahead Store search (nil when it couldn't search).
    func askStore(slug: String, query: String) async throws -> FindAskResult? {
        try await post(path: "find/entity/ask", payload: FindAskRequest(slug: slug, query: query), responseType: FindAskResponse.self).result
    }

    @discardableResult
    func submitFeedback(_ payload: FindFeedbackRequest) async throws -> FindScoreAward? {
        var request = payload
        request.deviceId = FindDevice.id
        request.timeZone = TimeZone.current.identifier
        return try await post(path: "find/feedback", payload: request, responseType: FindFeedbackResponse.self).score
    }

    // MARK: Crews

    func crews() async throws -> [FindCrew] {
        try await post(path: "find/crews", payload: FindCrewRequest(deviceId: FindDevice.id, timeZone: TimeZone.current.identifier), responseType: FindCrewsResponse.self).crews
    }

    func createCrew(name: String) async throws -> FindCrew {
        try await post(path: "find/crews/create", payload: FindCrewRequest(deviceId: FindDevice.id, name: name), responseType: FindCrewResponse.self).crew
    }

    func joinCrew(code: String) async throws -> FindCrew {
        try await post(path: "find/crews/join", payload: FindCrewRequest(deviceId: FindDevice.id, code: code), responseType: FindCrewResponse.self).crew
    }

    func leaveCrew(code: String) async throws {
        _ = try await post(path: "find/crews/leave", payload: FindCrewRequest(deviceId: FindDevice.id, code: code), responseType: FindEmptyResponse.self)
    }

    // MARK: Daily Find

    func dailyFind() async throws -> FindDailyState {
        try await post(path: "find/daily", payload: FindDailyRequest(deviceId: FindDevice.id, timeZone: TimeZone.current.identifier), responseType: FindDailyResponse.self).daily
    }

    func startDailyFind(date: String) async throws -> FindDailyState {
        try await post(path: "find/daily/start", payload: FindDailyRequest(deviceId: FindDevice.id, timeZone: TimeZone.current.identifier, date: date), responseType: FindDailyResponse.self).daily
    }

    func answerDailyFind(date: String, choice: Int) async throws -> FindDailyState {
        try await post(path: "find/daily/answer", payload: FindDailyRequest(deviceId: FindDevice.id, timeZone: TimeZone.current.identifier, date: date, choice: choice), responseType: FindDailyResponse.self).daily
    }

    // MARK: Find Score (all POSTs, so the device ID never lands in a URL)

    func scoreProfile() async throws -> FindScoreProfile {
        try await post(path: "find/score/profile", payload: FindScoreRequest(deviceId: FindDevice.id), responseType: FindScoreProfileResponse.self).profile
    }

    func setNickname(_ nickname: String) async throws -> FindScoreProfile {
        try await post(path: "find/score/nickname", payload: FindScoreRequest(deviceId: FindDevice.id, nickname: nickname), responseType: FindScoreProfileResponse.self).profile
    }

    /// Hands the old on-device search count to the backend, once.
    func importAwards(count: Int, badges: [FindScoreImportBadge]) async throws -> FindScoreProfile {
        try await post(path: "find/score/import", payload: FindScoreRequest(deviceId: FindDevice.id, count: count, badges: badges, timeZone: TimeZone.current.identifier), responseType: FindScoreProfileResponse.self).profile
    }

    func recoveryCode() async throws -> String {
        try await post(path: "find/score/recovery", payload: FindScoreRequest(deviceId: FindDevice.id), responseType: FindScoreRecoveryResponse.self).code
    }

    func recoverScore(code: String) async throws -> FindScoreProfile {
        try await post(path: "find/score/recover", payload: FindScoreRequest(deviceId: FindDevice.id, code: code), responseType: FindScoreProfileResponse.self).profile
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        payload: Request,
        responseType: Response.Type
    ) async throws -> Response {
        try decoder.decode(responseType, from: try await postData(path: path, payload: payload))
    }

    private func postData<Request: Encodable>(path: String, payload: Request) async throws -> Data {
        let url = config.apiBaseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FindAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String, !message.isEmpty {
                throw FindAPIError.server(message)
            }
            throw FindAPIError.httpError(httpResponse.statusCode)
        }

        return data
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
