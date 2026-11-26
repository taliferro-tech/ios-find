import Foundation
import Combine
import CoreLocation
import UIKit
import UserNotifications

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var isLoading = false
    /// Results first: cards are showing and Find is still checking their pages.
    @Published private(set) var isRefining = false
    @Published private(set) var searchStage = "planning"
    @Published private(set) var checkingPageCount = 0
    @Published private(set) var searchStartedAt = Date()
    /// "Let me know when it's ready": offered once a search has run 8 seconds.
    @Published private(set) var notifyOffer = false
    @Published private(set) var notifyWhenReady = false
    private var notifyOfferTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @Published var errorMessage = ""
    @Published var searchResponse: FindSearchResponse?
    @Published var selectedResult: FindRankedResult?
    @Published var summaryText = ""
    @Published var isSummarizing = false
    @Published var searchHistory: [String] = []
    @Published var pendingAwardUnlock: FindAward?
    // True while the swipe carousel is showing the backend's own generated
    // answer.text as a slide *before* the ranked results, rather than
    // treating it as a replacement for the top-ranked source card.
    @Published var viewingGroundedAnswer = false
    // "Use my location" on the Info tab (useLocationEverywhere in
    // find-home.component.ts): off by default. When on, every search sends
    // the position; when off, only "near me" and bare weather searches do.
    @Published private(set) var useLocationEverywhere = UserDefaults.standard.bool(forKey: "find.useLocation")
    // Single-item results (web: find-home's `entity`): a query that names one
    // thing gets one card, shown while the normal search is still running.
    // "More results" dismisses it for the usual pages.
    @Published private(set) var entity: FindEntity?
    @Published var entityDismissed = false
    /// The phone's position for a store/restaurant/service card (nearest location).
    private var entityCoordinate: CLLocationCoordinate2D?
    private var entityTask: Task<Void, Never>?
    private var searchID = UUID()

    let feedbackStore: FindFeedbackStore
    /// Daily Find: today's question (searches while playing count toward it).
    let dailyStore: FindDailyStore
    let apiClient: FindAPIClient
    private let awardsService: FindAwardsService
    private let locationService: FindLocationService
    private let historyKey = "find-history"

    // Mirrors the web app's NEAR_ME_PATTERN (find-home.component.ts): any of
    // these phrasings trigger a location request for a "near me"-shaped
    // local-business query.
    private static let nearMePattern = try! NSRegularExpression(
        pattern: #"\b(?:near me|nearby|near here|close(?:st)? to me|close by|around here|by me|in my area|in my neighborhood|in my zip\s*code|in my zipcode|in my zip)\b"#,
        options: [.caseInsensitive]
    )

    // Mirrors LOCATIONLESS_WEATHER_PATTERN: a bare "weather"/"forecast"/
    // "temperature" query with no named place (like the Weather quick
    // action's "weather") needs the device's own location, unlike "weather
    // in Chicago" which the backend geocodes from the text itself.
    private static let locationlessWeatherPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:what'?s|what is|how'?s|how is|the)\s+)?(?:weather|forecast|temperature)(?:\s+(?:like|today|tomorrow|tonight|right now|currently|this week|this weekend|now))?[?.!]*$"#,
        options: [.caseInsensitive]
    )

    private static let openNowPattern = try! NSRegularExpression(
        pattern: #"\b(?:open\s+(?:right\s+)?now|currently\s+open)\b"#,
        options: [.caseInsensitive]
    )

    /// Turning it on asks for permission right away; returns false when the
    /// system won't give a position (denied or unavailable).
    @discardableResult
    func setUseLocationEverywhere(_ enabled: Bool) async -> Bool {
        guard enabled else {
            useLocationEverywhere = false
            UserDefaults.standard.set(false, forKey: "find.useLocation")
            return true
        }
        let granted = await locationService.currentCoordinate() != nil
        useLocationEverywhere = granted
        UserDefaults.standard.set(granted, forKey: "find.useLocation")
        return granted
    }

    /// A short share link for the current result; falls back to a plain
    /// find.16ahead.com/?query= link if the backend can't make one.
    func shareLink(title: String, summary: String, result: FindRankedResult?) async -> URL? {
        let current = (searchResponse?.query ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }
        var fallback = URLComponents(string: "https://find.16ahead.com/")!
        fallback.queryItems = [URLQueryItem(name: "query", value: current)]
        let request = FindShareRequest(
            query: current, title: title, summary: String(summary.prefix(300)),
            url: result?.url ?? "", displayUrl: result?.displayUrl ?? "", imageUrl: result?.imageUrl ?? ""
        )
        if let link = try? await apiClient.share(request).url, let url = URL(string: link) {
            return url
        }
        return fallback.url
    }

    /// "Ask about this result". Never throws: a failure comes back as an
    /// unanswered response that still offers the search.
    func askFollowup(_ request: FindFollowupRequest) async -> FindFollowupResponse {
        do {
            return try await apiClient.followup(request)
        } catch {
            return FindFollowupResponse(success: false, mode: "answer", answered: false, answer: "", sources: [],
                                        searchQuery: "\(request.query) \(request.followup)".trimmingCharacters(in: .whitespaces))
        }
    }

    func runFollowupSearch(_ searchQuery: String) async {
        query = searchQuery
        await runSearch()
    }

    /// Nearby results: re-run the search for places open right now, or back.
    var isOpenNowSearch: Bool {
        let current = searchResponse?.query ?? ""
        return Self.openNowPattern.firstMatch(in: current, range: NSRange(current.startIndex..., in: current)) != nil
    }

    func toggleOpenNow() async {
        let current = (searchResponse?.query ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        if isOpenNowSearch {
            let range = NSRange(current.startIndex..., in: current)
            query = Self.openNowPattern.stringByReplacingMatches(in: current, range: range, withTemplate: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        } else {
            query = "\(current) open now"
        }
        await runSearch()
    }

    private static func isLocationShapedQuery(_ query: String) -> Bool {
        let range = NSRange(query.startIndex..., in: query)
        return nearMePattern.firstMatch(in: query, range: range) != nil
            || locationlessWeatherPattern.firstMatch(in: query, range: range) != nil
    }

    init(apiClient: FindAPIClient, awardsService: FindAwardsService, locationService: FindLocationService) {
        self.apiClient = apiClient
        self.feedbackStore = FindFeedbackStore(apiClient: apiClient)
        self.dailyStore = FindDailyStore(apiClient: apiClient)
        self.awardsService = awardsService
        self.locationService = locationService
        // A rating's points (Find Score) can unlock a rank or badge too.
        feedbackStore.onScore = { [weak self] score in
            guard let self, let unlocked = self.awardsService.applyAward(score), self.pendingAwardUnlock == nil else { return }
            self.pendingAwardUnlock = unlocked
        }
        loadHistory()
    }

    func dismissAwardUnlock() {
        pendingAwardUnlock = nil
    }

    // MARK: "Let me know when it's ready"

    private func startNotifyOffer() {
        notifyOfferTask?.cancel()
        notifyOffer = false
        notifyWhenReady = false
        notifyOfferTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.isLoading || self.isRefining else { return }
            self.notifyOffer = true
        }
    }

    /// The person can leave Find; a notification says when the search is done.
    /// iOS gives the app about 30 seconds in the background, plenty for a
    /// slow search.
    func requestReadyNotice() {
        notifyWhenReady = true
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FindSearch") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    private func finishReadyNotice(query: String, succeeded: Bool) {
        notifyOfferTask?.cancel()
        notifyOffer = false
        defer { endBackgroundTask() }
        guard notifyWhenReady else { return }
        notifyWhenReady = false
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Your Find is ready" : "Find couldn\u{2019}t finish that search"
        content.body = query
        content.sound = .default
        // Not "query": a tap just opens Find, where the result already is
        // (a Watch notification's "query" would run the search again).
        content.userInfo = ["readyQuery": query]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "find-ready", content: content, trigger: nil))
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Daily Find answered: its points and badges go through the unlock overlay.
    func applyDailyScore(_ score: FindScoreAward?) {
        if let unlocked = awardsService.applyAward(score), pendingAwardUnlock == nil {
            pendingAwardUnlock = unlocked
        }
    }

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        isRefining = false
        searchStage = "planning"
        checkingPageCount = 0
        searchStartedAt = Date()
        startNotifyOffer()
        errorMessage = ""
        summaryText = ""
        detectEntity(trimmed)
        let thisSearch = searchID

        // Headlines from feeds the backend can't reach (ESPN, NPR) load on
        // the phone alongside the search, and are merged into an RSS response.
        async let extraHeadlines = HeadlineFeeds.shared.extraHeadlines(for: HeadlineFeeds.section(for: trimmed))

        // Only requested for a location-shaped query (never on launch) -
        // resolves to nil on denial/timeout rather than throwing, so the
        // search still runs without coordinates instead of blocking.
        let coordinate = useLocationEverywhere || Self.isLocationShapedQuery(trimmed)
            ? await locationService.currentCoordinate()
            : nil

        do {
            var response = try await apiClient.searchStream(
                query: trimmed,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                dailyDate: dailyStore.playingDate
            ) { [weak self] event in
                guard let self, self.searchID == thisSearch else { return }
                switch event {
                case .stage(let stage, let pageCount):
                    self.searchStage = stage
                    if stage == "checking" { self.checkingPageCount = pageCount }
                case .results(let preview):
                    self.applyResultsPreview(preview)
                case .final:
                    break
                }
            }
            // A newer search started while this one ran.
            guard searchID == thisSearch else { return }
            // The card being read stays in front when the details arrive.
            let readingURL = isRefining ? selectedResult?.url : nil
            if response.rssBacked == true {
                response = HeadlineFeeds.merge(response, extra: await extraHeadlines)
            }
            let resolvedResponse = response.applyingLocalConversionFallback(to: trimmed)
            searchResponse = resolvedResponse
            isRefining = false
            if let readingURL, let reading = resolvedResponse.results.first(where: { $0.url == readingURL }) {
                selectedResult = reading
            } else {
                selectedResult = resolvedResponse.results.indices.contains(resolvedResponse.selectedIndex)
                    ? resolvedResponse.results[resolvedResponse.selectedIndex]
                    : resolvedResponse.results.first
            }
            let answerText = resolvedResponse.answer?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            viewingGroundedAnswer = resolvedResponse.queryType == .question
                && !answerText.isEmpty
                && !resolvedResponse.results.isEmpty
            addToHistory(trimmed)
            FindSpotlight.indexSearch(trimmed, response: resolvedResponse)
            if FindActivityMonitor.shared.mode == .driving, let answer = FindSiriAnswer(response: resolvedResponse) {
                FindSpeaker.shared.speak(answer.spoken)
            }
            dailyStore.noteSearch(resolvedResponse.daily)
            finishReadyNotice(query: trimmed, succeeded: true)
            // Find Score: the backend's points when it scored the search,
            // else the old on-device count.
            if let score = resolvedResponse.score {
                if let unlocked = awardsService.applyAward(score) { pendingAwardUnlock = unlocked }
            } else {
                awardsService.clearLastAward()
                if let unlocked = awardsService.recordSearch() { pendingAwardUnlock = unlocked }
            }
            // The 5th search with something to show, over at least 2 days. Not
            // on top of an award, and not while driving.
            if !resolvedResponse.results.isEmpty || !answerText.isEmpty {
                AppReview.recordSuccess(
                    threshold: 5,
                    minDays: 2,
                    canAsk: pendingAwardUnlock == nil && FindActivityMonitor.shared.mode != .driving
                )
            }
        } catch {
            guard searchID == thisSearch else { return }
            finishReadyNotice(query: trimmed, succeeded: false)
            if isRefining {
                // The cards stay; only the details didn't arrive.
                isRefining = false
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// Results first: the web search's cards show while Find checks the
    /// pages. Questions wait for their answer. Nothing is saved, rated or
    /// awarded until the full response arrives (web: applyResultsPreview).
    private func applyResultsPreview(_ preview: FindSearchResponse) {
        guard isLoading, preview.queryType != .question, !preview.results.isEmpty else { return }
        isLoading = false
        isRefining = true
        searchResponse = preview
        selectedResult = preview.results.first
        viewingGroundedAnswer = false
    }

    /// What a running search is doing, from the backend's own progress messages.
    var searchStageText: String {
        if searchStage == "checking" {
            return checkingPageCount > 0
                ? "Checking \(checkingPageCount) \(checkingPageCount == 1 ? "page" : "pages")…"
                : "Checking the results…"
        }
        return "Understanding your search…"
    }

    // MARK: Single-item results

    /// Asks whether the query is one thing while the search runs. A store,
    /// restaurant or local service card is about the nearest location, so
    /// that's when the phone's position is asked for (web: the same).
    private func detectEntity(_ query: String) {
        clearEntity()
        let id = UUID()
        searchID = id
        entityTask = Task { [weak self, apiClient, locationService] in
            guard let detected = try? await apiClient.detectEntity(query: query), !Task.isCancelled else { return }
            // A kind of card this player hadn't seen before earns a badge.
            if let self, let unlocked = self.awardsService.applyAward(detected.score), self.pendingAwardUnlock == nil {
                self.pendingAwardUnlock = unlocked
            }
            guard let found = detected.entity else { return }
            let coordinate = found.isBusiness ? await locationService.currentCoordinate() : nil
            guard let self, !Task.isCancelled, self.searchID == id else { return }
            self.entityCoordinate = coordinate
            self.entity = found
        }
    }

    private func clearEntity() {
        entityTask?.cancel()
        entityTask = nil
        entity = nil
        entityDismissed = false
        entityCoordinate = nil
    }

    var showsEntityCard: Bool { entity != nil && !entityDismissed }

    /// Loads one section of the current card; nil when it has none or fails.
    func entitySectionFetcher(for entity: FindEntity) -> @Sendable (String) async -> Data? {
        let client = apiClient
        let latitude = entityCoordinate?.latitude
        let longitude = entityCoordinate?.longitude
        return { section in
            try? await client.entitySection(entity, section: section, latitude: latitude, longitude: longitude)
        }
    }

    /// The same, for another game of a series (the game page's switcher).
    func entityFetcher() -> @Sendable (FindEntity, String) async -> Data? {
        let client = apiClient
        let latitude = entityCoordinate?.latitude
        let longitude = entityCoordinate?.longitude
        return { entity, section in
            try? await client.entitySection(entity, section: section, latitude: latitude, longitude: longitude)
        }
    }

    /// "Ask this store" on a store page; nil when the store couldn't search.
    func storeAsker() -> @Sendable (String, String) async -> FindAskResult? {
        let client = apiClient
        return { slug, query in
            try? await client.askStore(slug: slug, query: query)
        }
    }

    func select(_ result: FindRankedResult) {
        selectedResult = result
        viewingGroundedAnswer = false
        summaryText = ""
    }

    func summarizeSelected() async {
        guard let selectedResult else { return }

        isSummarizing = true
        errorMessage = ""

        do {
            summaryText = try await apiClient.summarize(
                query: searchResponse?.query ?? query,
                url: selectedResult.url,
                title: selectedResult.title
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isSummarizing = false
    }

    func runHistorySearch(_ term: String) async {
        query = term
        await runSearch()
    }

    func runDrillDown(from baseQuery: String, pill: String) async {
        let base = baseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPill = pill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !normalizedPill.isEmpty else { return }

        let loweredWords = base
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let nextQuery = loweredWords.last == normalizedPill.lowercased()
            ? base
            : "\(base) \(normalizedPill)"

        query = nextQuery
        await runSearch()
    }

    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: historyKey)
        FindSpotlight.removeAllSearches()
    }

    func resetSearch() {
        clearEntity()
        query = ""
        isLoading = false
        isRefining = false
        errorMessage = ""
        searchResponse = nil
        selectedResult = nil
        viewingGroundedAnswer = false
        summaryText = ""
        isSummarizing = false
    }

    private func loadHistory() {
        let values = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        searchHistory = values
    }

    private func addToHistory(_ term: String) {
        var next = searchHistory.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        next.insert(term, at: 0)
        FindSpotlight.removeSearches(Array(next.dropFirst(20)))
        searchHistory = Array(next.prefix(20))
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
    }
}

private extension FindSearchResponse {
    func applyingLocalConversionFallback(to query: String) -> FindSearchResponse {
        guard queryType != .conversion, conversion == nil,
              let localConversion = LocalConversionParser.parse(query, answerText: answer?.text ?? "") else {
            return self
        }

        var converted = FindSearchResponse(
            success: success,
            query: query,
            normalizedQuery: query,
            queryType: .conversion,
            handoff: handoff,
            answer: answer,
            weather: weather,
            conversion: localConversion,
            movieRatings: movieRatings,
            results: [],
            selectedIndex: 0,
            timings: timings,
            rssBacked: nil
        )
        // What the search earned (Find Score) still counts.
        converted.score = score
        converted.daily = daily
        return converted
    }
}

private enum LocalConversionParser {
    private struct Unit {
        let category: FindConversionCategory
        let unit: String
        let label: String
        let factor: Double?
    }

    static func parse(_ query: String, answerText: String) -> FindConversionResult? {
        let parts = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)

        guard let connectorIndex = parts.firstIndex(where: { $0 == "to" || $0 == "in" || $0 == "into" }),
              connectorIndex > 0,
              connectorIndex + 1 < parts.count,
              connectorIndex + 2 == parts.count else { return nil }

        let left = Array(parts[..<connectorIndex])
        guard left.count <= 2 else { return nil }

        let amount: Double
        let inputToken: String
        if left.count == 2 {
            guard let parsedAmount = Double(left[0]) else { return nil }
            amount = parsedAmount
            inputToken = left[1]
        } else {
            amount = 1
            inputToken = left[0]
        }

        guard let input = unit(for: inputToken),
              let output = unit(for: parts[connectorIndex + 1]),
              input.category == output.category,
              amount.isFinite else { return nil }

        let outputAmount: Double
        let rate: Double?
        if input.category == .temperature {
            outputAmount = input.unit == output.unit
                ? amount
                : input.unit == "fahrenheit"
                    ? (amount - 32) * 5 / 9
                    : amount * 9 / 5 + 32
            rate = nil
        } else if input.category == .currency {
            guard let answerAmount = currencyAnswerAmount(in: answerText, excluding: amount, targetUnit: output.unit) else { return nil }
            outputAmount = answerAmount
            rate = amount == 0 ? nil : answerAmount / amount
        } else {
            outputAmount = amount * (input.factor ?? 1) / (output.factor ?? 1)
            rate = nil
        }

        return FindConversionResult(
            category: input.category,
            inputAmount: amount,
            inputUnit: input.unit,
            inputUnitLabel: input.label,
            outputAmount: outputAmount,
            outputUnit: output.unit,
            outputUnitLabel: output.label,
            rate: rate,
            rateUpdatedAt: nil,
            source: input.category == .currency ? "Find results" : "Find local conversion"
        )
    }

    private static func currencyAnswerAmount(in answer: String, excluding inputAmount: Double, targetUnit: String) -> Double? {
        let targetTerms: [String: String] = [
            "USD": #"(?:us\s*)?dollars?|usd"#, "CAD": #"canadian\s*dollars?|cad"#,
            "EUR": #"euros?|eur"#, "GBP": #"pounds?|gbp"#, "JPY": #"(?:japanese\s*)?yen|jpy"#,
            "AUD": #"australian\s*dollars?|aud"#, "CNY": #"(?:chinese\s*)?(?:yuan|renminbi)|cny"#,
            "CHF": #"swiss\s*francs?|chf"#, "MXN": #"mexican\s*pesos?|mxn"#
        ]
        if let target = targetTerms[targetUnit],
           let expression = try? NSRegularExpression(pattern: #"([-+]?\d[\d,]*(?:\.\d+)?)\s*(?:"# + target + #")"#, options: [.caseInsensitive]) {
            let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            if let match = expression.firstMatch(in: answer, range: range),
               let matchRange = Range(match.range(at: 1), in: answer),
               let targeted = Double(answer[matchRange].replacingOccurrences(of: ",", with: "")),
               abs(targeted - inputAmount) > Double.ulpOfOne {
                return targeted
            }
        }

        let pattern = #"[-+]?\d[\d,]*(?:\.\d+)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        let values = expression.matches(in: answer, range: range).compactMap { match -> Double? in
            guard let matchRange = Range(match.range, in: answer) else { return nil }
            return Double(answer[matchRange].replacingOccurrences(of: ",", with: ""))
        }
        return values.reversed().first { abs($0 - inputAmount) > Double.ulpOfOne }
    }

    private static func unit(for value: String) -> Unit? {
        switch value {
        case "f", "fahrenheit": return Unit(category: .temperature, unit: "fahrenheit", label: "Fahrenheit", factor: nil)
        case "c", "celsius": return Unit(category: .temperature, unit: "celsius", label: "Celsius", factor: nil)
        case "usd", "dollar", "dollars": return Unit(category: .currency, unit: "USD", label: "US Dollar (USD)", factor: nil)
        case "cad": return Unit(category: .currency, unit: "CAD", label: "Canadian Dollar (CAD)", factor: nil)
        case "eur", "euro", "euros": return Unit(category: .currency, unit: "EUR", label: "Euro (EUR)", factor: nil)
        case "gbp": return Unit(category: .currency, unit: "GBP", label: "British Pound (GBP)", factor: nil)
        case "jpy", "yen": return Unit(category: .currency, unit: "JPY", label: "Japanese Yen (JPY)", factor: nil)
        case "aud": return Unit(category: .currency, unit: "AUD", label: "Australian Dollar (AUD)", factor: nil)
        case "cny", "yuan": return Unit(category: .currency, unit: "CNY", label: "Chinese Yuan (CNY)", factor: nil)
        case "chf": return Unit(category: .currency, unit: "CHF", label: "Swiss Franc (CHF)", factor: nil)
        case "mxn": return Unit(category: .currency, unit: "MXN", label: "Mexican Peso (MXN)", factor: nil)
        case "mi", "mile", "miles": return Unit(category: .distance, unit: "miles", label: "Miles", factor: 1.609344)
        case "km", "kilometer", "kilometers": return Unit(category: .distance, unit: "kilometers", label: "Kilometers", factor: 1)
        case "lb", "lbs", "pound", "pounds": return Unit(category: .weight, unit: "pounds", label: "Pounds", factor: 0.45359237)
        case "kg", "kilogram", "kilograms": return Unit(category: .weight, unit: "kilograms", label: "Kilograms", factor: 1)
        case "in", "inch", "inches": return Unit(category: .length, unit: "inches", label: "Inches", factor: 0.0254)
        case "ft", "foot", "feet": return Unit(category: .length, unit: "feet", label: "Feet", factor: 0.3048)
        case "m", "meter", "meters": return Unit(category: .length, unit: "meters", label: "Meters", factor: 1)
        case "l", "liter", "liters": return Unit(category: .volume, unit: "liters", label: "Liters", factor: 1)
        case "gal", "gallon", "gallons": return Unit(category: .volume, unit: "gallons", label: "Gallons", factor: 3.785411784)
        default: return nil
        }
    }
}
