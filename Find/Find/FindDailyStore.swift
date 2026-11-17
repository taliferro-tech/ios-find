import Foundation
import Combine

/// Daily Find on iPhone (web: find-daily.service.ts): today's question,
/// whether it's being played, and its result. While playing, searches carry
/// `playingDate` so the backend counts them.
@MainActor
final class FindDailyStore: ObservableObject {
    @Published private(set) var state: FindDailyState?
    @Published private(set) var isLoading = false
    @Published var message = ""

    private let apiClient: FindAPIClient

    init(apiClient: FindAPIClient) {
        self.apiClient = apiClient
    }

    /// The date to send with a search, while today's question is being played.
    var playingDate: String? {
        state?.status == "playing" ? state?.date : nil
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        if let loaded = try? await apiClient.dailyFind() {
            state = loaded
        }
    }

    func start() async {
        guard let date = state?.date else { return }
        message = ""
        do {
            state = try await apiClient.startDailyFind(date: date)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Returns what answering earned (Find Score), for the unlock overlay.
    func answer(_ choice: Int) async -> FindScoreAward? {
        guard let date = state?.date else { return nil }
        message = ""
        do {
            let answered = try await apiClient.answerDailyFind(date: date, choice: choice)
            state = answered
            return answered.score
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// A search counted for today's question: the choices unlock after the first.
    func noteSearch(_ daily: FindDailySearch?) {
        guard let daily, let current = state, daily.date == current.date else { return }
        let firstSearch = (current.searches ?? 0) == 0 && daily.searches > 0
        state?.searches = daily.searches
        if firstSearch { Task { await load() } }
    }
}
