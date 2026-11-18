import Foundation
import Combine

// Mirrors the web app's src/app/services/find-awards.service.ts. Find Score
// (2026-11-17): the backend awards every point and badge; this keeps the
// latest profile (cached in UserDefaults so the rank shows right away) and
// turns what a search, rating or card earned into the unlock overlay.
//
// The old on-device ladder (10 awards by search count) is still counted
// until the backend has taken it over (imported), and shown when the
// backend can't be reached, so nobody sees their awards vanish.
enum FindAwardIcon: String, Codable {
    case rebel, curious, nightOwl, earlyBird, connector, sharpEye, explorer, specialist, relentless, tastemaker, legend
    case streak, collector, allCards, rank, daily

    /// The backend's icon names ("night-owl", "all-cards").
    init(backend name: String) {
        switch name {
        case "rebel": self = .rebel
        case "curious": self = .curious
        case "night-owl": self = .nightOwl
        case "early-bird": self = .earlyBird
        case "connector": self = .connector
        case "sharp-eye": self = .sharpEye
        case "explorer": self = .explorer
        case "specialist": self = .specialist
        case "relentless": self = .relentless
        case "tastemaker": self = .tastemaker
        case "legend": self = .legend
        case "streak": self = .streak
        case "all-cards": self = .allCards
        case "rank": self = .rank
        case "daily": self = .daily
        default: self = .collector
        }
    }

    var backendName: String {
        switch self {
        case .nightOwl: return "night-owl"
        case .earlyBird: return "early-bird"
        case .sharpEye: return "sharp-eye"
        case .allCards: return "all-cards"
        default: return rawValue
        }
    }
}

enum FindAwardState {
    case unlocked, locked, mystery
}

struct FindAward: Identifiable, Codable {
    let id: String
    var title: String
    let threshold: Int
    var copy: String
    var icon: FindAwardIcon
    var hidden: Bool = false
    /// Above the title in the unlock overlay ("NEW RANK"); nil = "AWARD UNLOCKED".
    var eyebrow: String? = nil
}

struct FindAwardListItem: Identifiable {
    let id: String
    let title: String
    let icon: FindAwardIcon
    let state: FindAwardState
    var group: String = "searches"
    var goal: String? = nil
    var copy: String = ""
}

struct FindAwardGroup: Identifiable {
    let id: String
    let title: String
    let awards: [FindAwardListItem]
}

private struct FindAwardUnlockRecord: Codable {
    let title: String
    let copy: String
    let icon: FindAwardIcon
    let unlockedAt: Date
}

@MainActor
final class FindAwardsService: ObservableObject {
    @Published private(set) var count: Int = 0
    @Published private var unlocked: [String: FindAwardUnlockRecord] = [:]
    /// The Find Score profile as last seen; nil before the first one.
    @Published private(set) var profile: FindScoreProfile?
    /// What the shown result's search earned ("+12 points").
    @Published private(set) var lastAward: FindScoreAward?

    /// Set by the app once the API client exists.
    var apiClient: FindAPIClient?
    private var importChecked = false

    static let ladder: [FindAward] = [
        FindAward(id: "rebel", title: "The Rebel", threshold: 1,
                  copy: "You don\u{2019}t wait for permission \u{2014} you go find it yourself.", icon: .rebel),
        FindAward(id: "curious-one", title: "The Curious One", threshold: 3,
                  copy: "You can\u{2019}t leave a question alone. Never could.", icon: .curious),
        FindAward(id: "night-owl", title: "The Night Owl / Early Bird", threshold: 6,
                  copy: "3am and your mind\u{2019}s still going. That\u{2019}s not insomnia \u{2014} that\u{2019}s you.", icon: .nightOwl),
        FindAward(id: "connector", title: "The Connector", threshold: 10,
                  copy: "You saw the thread before anyone said it out loud.", icon: .connector),
        FindAward(id: "sharp-eye", title: "The Sharp Eye", threshold: 15,
                  copy: "Something felt off and you were right.", icon: .sharpEye),
        FindAward(id: "explorer", title: "The Explorer", threshold: 20,
                  copy: "One result was never going to be enough for you.", icon: .explorer),
        FindAward(id: "specialist", title: "The Specialist", threshold: 30,
                  copy: "You stopped skimming. You went all the way down.", icon: .specialist),
        FindAward(id: "relentless", title: "The Relentless", threshold: 40,
                  copy: "Something in you refused to close the tab.", icon: .relentless),
        FindAward(id: "tastemaker", title: "The Tastemaker", threshold: 60,
                  copy: "People catch up to what you already knew.", icon: .tastemaker),
        FindAward(id: "legend", title: "The Legend", threshold: 100, copy: "You stopped counting a while ago. So did we.",
                  icon: .legend, hidden: true),
    ]

    private static let groupTitles = ["searches": "Searches", "streaks": "Streaks", "cards": "Cards", "daily": "Daily Find"]

    private let countKey = "find-awards-count"
    private let unlockedKey = "find-awards-unlocked"
    private let profileKey = "find-score-profile"

    init() {
        load()
    }

    var awards: [FindAwardListItem] {
        if let profile, !profile.badges.isEmpty {
            return profile.badges.map(Self.listItem)
        }
        return Self.ladder.map { award in
            if let record = unlocked[award.id] {
                return FindAwardListItem(id: award.id, title: record.title, icon: record.icon, state: .unlocked, copy: record.copy)
            }
            return FindAwardListItem(id: award.id, title: award.title, icon: award.icon, state: award.hidden ? .mystery : .locked, copy: award.copy)
        }
    }

    var groups: [FindAwardGroup] {
        var order: [String] = []
        var byGroup: [String: [FindAwardListItem]] = [:]
        for award in awards {
            if byGroup[award.group] == nil { order.append(award.group) }
            byGroup[award.group, default: []].append(award)
        }
        return order.map { FindAwardGroup(id: $0, title: Self.groupTitles[$0] ?? $0.capitalized, awards: byGroup[$0] ?? []) }
    }

    var totalCount: Int { awards.count }

    var unlockedCount: Int {
        awards.filter { $0.state == .unlocked }.count
    }

    var progressPercent: Double {
        let trackable = awards.filter { $0.state != .mystery }.count
        return trackable == 0 ? 0 : Double(unlockedCount) / Double(trackable)
    }

    /// How far into the current rank, 0...1.
    var rankProgress: Double {
        guard let profile, let next = profile.rank.next else { return 1 }
        let span = next.min - profile.rank.min
        return span > 0 ? min(1, max(0, Double(profile.score - profile.rank.min) / Double(span))) : 1
    }

    /// The old on-device count, for a search the backend didn't score.
    /// Returns the award that was just unlocked, if any.
    @discardableResult
    func recordSearch() -> FindAward? {
        guard profile?.imported != true else { return nil }
        count += 1
        save()

        var justUnlocked: FindAward?
        for award in Self.ladder {
            guard unlocked[award.id] == nil, count >= award.threshold else { continue }
            let resolved = resolveAward(award)
            unlocked[award.id] = FindAwardUnlockRecord(title: resolved.title, copy: resolved.copy, icon: resolved.icon, unlockedAt: Date())
            justUnlocked = resolved
        }
        if justUnlocked != nil { save() }
        return justUnlocked
    }

    /// Takes what a search, rating or card earned and returns what to show:
    /// a new rank first, then a new badge, else nil. The first one each
    /// launch also loads the whole profile (and hands over the old count).
    func applyAward(_ award: FindScoreAward?) -> FindAward? {
        guard let award else { return nil }
        lastAward = award
        if var current = profile {
            let earned = Dictionary(award.newBadges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            current.score = award.total
            current.weekScore = award.weekScore
            current.rank = award.rank
            current.streak.count = award.streak
            current.streak.best = max(current.streak.best, award.streak)
            current.badges = current.badges.map { badge in
                guard var newer = earned[badge.id] else { return badge }
                newer.state = "earned"
                return newer
            }
            setProfile(current)
        }
        if !importChecked { Task { await refresh() } }
        if let rankUp = award.rankUp {
            let total = award.total.formatted()
            let copy = award.rank.next.map { "\(total) points. \($0.toGo.formatted()) more to \($0.name)." } ?? "\(total) points. The top rank."
            return FindAward(id: "rank-\(rankUp)", title: rankUp, threshold: 0, copy: copy, icon: .rank, eyebrow: "NEW RANK")
        }
        guard let badge = award.newBadges.first else { return nil }
        return FindAward(id: badge.id, title: badge.title, threshold: 0, copy: badge.copy, icon: FindAwardIcon(backend: badge.icon))
    }

    func clearLastAward() {
        lastAward = nil
    }

    /// Loads the profile from the backend; the first time, hands over the old count.
    func refresh() async {
        guard let apiClient else { return }
        do {
            var loaded = try await apiClient.scoreProfile()
            importChecked = true
            if !loaded.imported, count > 0 {
                let badges = unlocked.map { FindScoreImportBadge(id: $0.key, title: $0.value.title, icon: $0.value.icon.backendName) }
                if let imported = try? await apiClient.importAwards(count: count, badges: badges) {
                    loaded = imported
                }
            }
            setProfile(loaded)
        } catch {
            // Offline: keep showing the cached profile.
        }
    }

    func setNickname(_ nickname: String) async throws {
        guard let apiClient else { return }
        setProfile(try await apiClient.setNickname(nickname))
    }

    func recoveryCode() async throws -> String {
        guard let apiClient else { throw FindAPIError.invalidResponse }
        return try await apiClient.recoveryCode()
    }

    func recover(code: String) async throws -> FindScoreProfile {
        guard let apiClient else { throw FindAPIError.invalidResponse }
        let moved = try await apiClient.recoverScore(code: code)
        setProfile(moved)
        return moved
    }

    private static func listItem(_ badge: FindScoreBadge) -> FindAwardListItem {
        let state: FindAwardState = switch badge.state {
        case "earned", nil: .unlocked
        case "mystery": .mystery
        default: .locked
        }
        return FindAwardListItem(id: badge.id, title: badge.title, icon: FindAwardIcon(backend: badge.icon), state: state, group: badge.group, goal: badge.goal, copy: badge.copy)
    }

    private func setProfile(_ profile: FindScoreProfile) {
        self.profile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    private func resolveAward(_ award: FindAward) -> FindAward {
        guard award.id == "night-owl" else { return award }
        let hour = Calendar.current.component(.hour, from: Date())
        let isEarly = hour >= 4 && hour < 12
        var resolved = award
        if isEarly {
            resolved.title = "The Early Bird"
            resolved.icon = .earlyBird
            resolved.copy = "You were thinking before the world woke up."
        } else {
            resolved.title = "The Night Owl"
            resolved.icon = .nightOwl
            resolved.copy = "3am and your mind\u{2019}s still going. That\u{2019}s not insomnia \u{2014} that\u{2019}s you."
        }
        return resolved
    }

    private func load() {
        count = UserDefaults.standard.integer(forKey: countKey)
        if let data = UserDefaults.standard.data(forKey: unlockedKey),
           let decoded = try? JSONDecoder().decode([String: FindAwardUnlockRecord].self, from: data) {
            unlocked = decoded
        }
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(FindScoreProfile.self, from: data) {
            profile = decoded
        }
    }

    private func save() {
        UserDefaults.standard.set(count, forKey: countKey)
        if let data = try? JSONEncoder().encode(unlocked) {
            UserDefaults.standard.set(data, forKey: unlockedKey)
        }
    }
}
