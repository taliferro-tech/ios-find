import EventKit
import EventKitUI
import SwiftUI

/// The game page (design_handoff_find_game_restaurant_retail, part A; web:
/// find-game-card), iPhone layout: one game in three states. Before:
/// kickoff, TV, venue, line, records, preview and "Watch this game". Live: a
/// dark scoreboard that refreshes every 30 s while the app is in front,
/// scoring plays, score by quarter. Final: score, top players, recap. Teams
/// are lettered circles in team colours, never logos; a team taps through to
/// its team card. Teams that meet more than once get a switcher.
struct EntityGameCard: View {
    let entity: FindEntity
    let query: String
    let fetch: @Sendable (String) async -> Data?
    /// Loads a section of another game of the series.
    let fetchEntity: EntityFetch
    let watchStore: FindWatchStore
    let onSearch: (String) -> Void

    private static let refreshSeconds: Double = 30
    private static let lateAfterSeconds: Double = 120

    /// The game on screen: the one found, or another game of the series.
    @State private var eventId = ""
    @State private var game: FindGameSection?
    @State private var gameMissing = false
    @State private var summary: FindEntitySummary?
    @State private var summaryLoading = true
    @State private var summaryPeriod: String?
    @State private var lastUpdated: Date?
    @State private var newPlay: String?
    @State private var expanded = false

    @State private var alerts = FindGameWatch.Alerts.none
    @State private var alertBusy = false
    @State private var alertMessage = ""
    @State private var showingCalendar = false

    @Environment(\.scenePhase) private var scenePhase

    private var currentId: String { eventId.isEmpty ? entity.id : eventId }
    private var isLive: Bool { game?.status == "live" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            titleBlock

            if let game {
                scoreboard(game)
                if let series = game.series { seriesSwitcher(series) }
                if game.status == "live" { liveRow }

                switch game.status {
                case "live": liveSections(game)
                case "final": finalSections(game)
                case "postponed": summaryBlock(game)
                default: preSections(game)
                }

                VStack(alignment: .leading, spacing: 14) {
                    EntityPillActions(actions: actions(game))
                    if game.status == "final" && !(game.plays ?? []).isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(expanded ? "Show less" : "Show more").font(Theme.font(14, weight: .bold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if expanded && game.status == "final", let plays = game.plays, !plays.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        EntitySectionLabel(text: "Scoring plays").padding(.bottom, 4)
                        playRows(plays, animated: false)
                    }
                }
            } else if gameMissing {
                Text("Find couldn’t load this game from ESPN right now.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
            } else {
                EntitySkeleton(height: 240, radius: 30)
            }
        }
        .task(id: currentId) { await open(currentId) }
        // Scores refresh every 30 s while the game is on and the app is in
        // front; coming back to the app refreshes right away.
        .task(id: "\(currentId)|\(isLive)|\(scenePhase == .active)") {
            guard isLive, scenePhase == .active else { return }
            if let lastUpdated, Date().timeIntervalSince(lastUpdated) >= Self.refreshSeconds {
                await loadGame(refresh: true)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshSeconds))
                guard !Task.isCancelled else { return }
                await loadGame(refresh: true)
            }
        }
        .sheet(isPresented: $showingCalendar) {
            if let game { GameCalendarSheet(game: game, title: plainTitle(game), location: venueText(game)).ignoresSafeArea() }
        }
    }

    // MARK: Loading

    private func open(_ id: String) async {
        game = nil
        gameMissing = false
        summary = nil
        summaryLoading = true
        summaryPeriod = nil
        lastUpdated = nil
        newPlay = nil
        expanded = false
        alertMessage = ""
        alerts = watchStore.gameWatch(eventId: id)?.game?.alerts ?? .none
        await loadGame(refresh: false)
    }

    private func section(_ name: String) async -> Data? {
        let id = currentId
        if id == entity.id { return await fetch(name) }
        let other = FindEntity(type: entity.type, label: entity.label, id: id, name: entity.name, logoUrl: nil, league: entity.league,
                               abbr: nil, shortName: nil, links: nil, website: nil, tint: nil, tintFg: nil, tintDark: nil, tintFgDark: nil)
        return await fetchEntity(other, name)
    }

    private func loadGame(refresh: Bool) async {
        let id = currentId
        let data = await section("game")
        guard id == currentId else { return }
        guard let data, let loaded = try? JSONDecoder().decode(FindGameSection.self, from: data) else {
            // A failed refresh keeps the last score; "Waiting for the next update" shows after two minutes.
            if !refresh { gameMissing = true }
            return
        }
        let previous = game
        if refresh, let first = loaded.plays?.first?.title, previous?.plays?.first?.title != first { newPlay = first }
        withAnimation(refresh ? .easeOut(duration: 0.45) : nil) { game = loaded }
        lastUpdated = Date()
        await syncSummary(loaded, first: previous == nil)
    }

    /// The summary is written once per state, and once per quarter while live.
    private func syncSummary(_ game: FindGameSection, first: Bool) async {
        let period = "\(game.status):\(game.status == "live" ? game.live?.period.map(String.init) ?? "" : "")"
        guard period != summaryPeriod else { return }
        summaryPeriod = period
        if first { summaryLoading = true }
        let id = currentId
        let data = await section("summary")
        guard id == currentId else { return }
        if let data, let loaded = try? JSONDecoder().decode(FindEntitySummary.self, from: data), !loaded.text.isEmpty {
            summary = loaded
        }
        summaryLoading = false
    }

    // MARK: Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            EntityFlow(spacing: 8) {
                EntityChip(text: entity.label ?? "Game", tone: "cyan")
                if let round = game?.round, !round.isEmpty { EntityChip(text: round, tone: "plain") }
                if let chip = stateChip { EntityChip(text: chip.text, tone: chip.tone) }
                if let series = game?.series { EntityChip(text: series.label, tone: "violet") }
            }
            Text(game.map(title) ?? entity.name)
                .font(Theme.font(32, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let game {
                let meta = metaItems(game)
                if !meta.isEmpty {
                    Text(meta.joined(separator: "  "))
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func title(_ game: FindGameSection) -> String {
        if game.status == "final", let score = game.score {
            let away = (game.away.short, Double(score.away) ?? 0, score.away)
            let home = (game.home.short, Double(score.home) ?? 0, score.home)
            let (first, second) = away.1 > home.1 ? (away, home) : (home, away)
            return "\(first.0) \(first.2), \(second.0) \(second.2)"
        }
        return plainTitle(game)
    }

    private func plainTitle(_ game: FindGameSection) -> String { "\(game.away.short) at \(game.home.short)" }

    private func metaItems(_ game: FindGameSection) -> [String] {
        if game.status == "final" { return [dayOf(game.start), venueText(game)].filter { !$0.isEmpty } }
        return [venueText(game), game.tv ?? ""].filter { !$0.isEmpty }
    }

    private var stateChip: (text: String, tone: String)? {
        guard let game else { return nil }
        switch game.status {
        case "live": return ("● Live · \(periodName(game))", "red")
        case "final": return ("Final", "plain")
        case "postponed":
            let detail = game.statusDetail ?? ""
            return (detail.isEmpty || detail.lowercased() == "postponed" ? "Postponed" : "Postponed · \(detail)", "plain")
        default:
            guard let start = FindEntityFormat.date(game.start) else { return nil }
            let soon = start.timeIntervalSinceNow < 6 * 24 * 3600
            return (soon ? "\(FindEntityFormat.format(start, "EEE")) \(timeOf(game.start))" : FindEntityFormat.format(start, "EEEMMMd"), "yellow")
        }
    }

    /// "Memorial Stadium (Lincoln, NE)" already names its city.
    private func venueText(_ game: FindGameSection) -> String {
        let name = game.venue?.name ?? ""
        let city = (game.venue?.city ?? "").components(separatedBy: ",").first ?? ""
        if name.isEmpty { return game.venue?.city ?? "" }
        return !city.isEmpty && !name.contains(city) ? "\(name), \(city)" : name
    }

    // MARK: Scoreboard

    private func scoreboard(_ game: FindGameSection) -> some View {
        let live = game.status == "live"
        let ink: Color = live ? .white : Theme.text
        let soft: Color = live ? .white.opacity(0.72) : Theme.muted
        return VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 4) {
                if let score = game.score {
                    HStack(spacing: 14) {
                        Text(score.away).opacity(isBehind(score.away, score.home) ? 0.45 : 1)
                        Text("–").font(Theme.font(34, weight: .heavy)).opacity(0.45).accessibilityHidden(true)
                        Text(score.home).opacity(isBehind(score.home, score.away) ? 0.45 : 1)
                    }
                    .font(Theme.font(64, weight: .heavy).monospacedDigit())
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(game.away.abbr) \(score.away), \(game.home.abbr) \(score.home)")

                    if live {
                        Text(clockLine(game)).font(Theme.font(18, weight: .bold))
                        situation(game).foregroundStyle(soft)
                    } else {
                        Text(game.status == "postponed" ? "POSTPONED" : "FINAL").font(Theme.font(15, weight: .heavy)).tracking(1.8)
                        Text([dayOf(game.start), game.venue?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Theme.font(15)).foregroundStyle(soft).multilineTextAlignment(.center)
                    }
                } else {
                    Text(timeOf(game.start)).font(Theme.font(44, weight: .heavy)).tracking(-1.3).lineLimit(1).minimumScaleFactor(0.6)
                    Text([dayOf(game.start), game.tv ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.font(15)).foregroundStyle(soft)
                }
            }
            .frame(maxWidth: .infinity)

            teamRow(game.away, ink: ink, soft: soft, link: live ? Color(hex: 0xb3a8ff) : Theme.indigo)
            teamRow(game.home, ink: ink, soft: soft, link: live ? Color(hex: 0xb3a8ff) : Theme.indigo)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(live ? Color(hex: 0x0f1115) : Theme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scoreboard")
    }

    @ViewBuilder
    private func situation(_ game: FindGameSection) -> some View {
        let possession = game.live?.possession.map { game.team($0) }
        let downDistance = game.live?.downDistance ?? ""
        if possession != nil || !downDistance.isEmpty {
            HStack(spacing: 8) {
                if let possession {
                    Text("\(possession.short) ball")
                    if game.league == "nfl" || game.league == "college-football" {
                        Ellipse().fill(Color(hex: 0xc9772d)).frame(width: 16, height: 10).accessibilityHidden(true)
                    }
                }
                if !downDistance.isEmpty { Text(downDistance) }
            }
            .font(Theme.font(15))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func teamRow(_ team: FindGameTeam, ink: Color, soft: Color, link: Color) -> some View {
        Button {
            onSearch(team.name)
        } label: {
            HStack(spacing: 16) {
                GameCrest(abbr: team.abbr, color: team.color, size: 60)
                VStack(alignment: .leading, spacing: 3) {
                    (team.rank.map { Text("#\($0) ").font(Theme.font(16, weight: .bold)).foregroundColor(soft) } ?? Text(""))
                        + Text(team.name).font(Theme.font(22, weight: .bold)).foregroundColor(ink)
                    if let record = team.record, !record.isEmpty {
                        Text(record).font(Theme.font(14)).foregroundStyle(soft)
                    }
                    Text("Team card ›").font(Theme.font(12, weight: .bold)).foregroundStyle(link)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name) team card")
    }

    private func isBehind(_ mine: String, _ theirs: String) -> Bool {
        guard let mine = Double(mine), let theirs = Double(theirs) else { return false }
        return mine < theirs
    }

    // MARK: Series switcher

    private func seriesSwitcher(_ series: FindGameSection.Series) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 4) {
                ForEach(series.games, id: \.id) { item in
                    let on = item.id == currentId
                    Button {
                        if item.id != currentId { eventId = item.id }
                    } label: {
                        Text(seriesTabLabel(item, in: series))
                            .font(Theme.font(14, weight: .bold))
                            .foregroundStyle(on ? Theme.text : Theme.muted)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Theme.bg)
                                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("These teams play \(series.games.count == 2 ? "twice" : "\(series.games.count) times") this season. Find opens the game that’s on, else the next one, else the most recent.")
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seriesTabLabel(_ item: FindGameSection.Series.Game, in series: FindGameSection.Series) -> String {
        let next = series.games.first { $0.status == "pre" }?.id == item.id
        let status = item.status == "final" ? "Final, \(item.result ?? "")" : item.status == "live" ? "Live" : next ? "Next" : "Later"
        let date = FindEntityFormat.date(item.date).map { FindEntityFormat.format($0, "MMMd") }
        return ["Game \(item.number)", date, status].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Live

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(.white.opacity(0.35)).frame(width: 18, height: 18))
                Text("LIVE").font(Theme.font(14, weight: .heavy)).tracking(1.1)
            }
            .foregroundStyle(.white)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Color(hex: 0xe5243b), in: Capsule())

            // "Updated 12 seconds ago" keeps counting without a refresh.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(updatedText(at: context.date))
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func updatedText(at now: Date) -> String {
        guard let lastUpdated else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated).rounded()))
        if Double(seconds) > Self.lateAfterSeconds { return "Waiting for the next update" }
        return "Updated \(seconds < 5 ? "just now" : "\(seconds) seconds ago") · refreshes every 30 seconds"
    }

    private func liveSections(_ game: FindGameSection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                EntitySectionLabel(text: "Scoring plays · latest first").padding(.bottom, 6)
                if let plays = game.plays, !plays.isEmpty {
                    playRows(plays, animated: true)
                } else {
                    Text("No scoring yet.").font(Theme.font(15)).foregroundStyle(Theme.muted).padding(.vertical, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))

            scoreTable(game)
            summaryBlock(game)
            alertsOn
        }
    }

    private func playRows(_ plays: [FindGameSection.Play], animated: Bool) -> some View {
        ForEach(Array(plays.enumerated()), id: \.element) { index, play in
            HStack(spacing: 14) {
                GameCrest(abbr: play.teamAbbr, color: play.teamColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(play.title).font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text)
                    if let detail = play.detail, !detail.isEmpty {
                        Text(detail).font(Theme.font(13)).foregroundStyle(Theme.muted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(play.scoreAfter).font(Theme.font(17, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                if index > 0 { Rectangle().fill(Theme.surface).frame(height: 1) }
            }
            // A new play slides in at the top.
            .transition(animated ? .move(edge: .top).combined(with: .opacity) : .identity)
        }
    }

    private var alertsOn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alerts on").font(Theme.font(20, weight: .bold)).foregroundStyle(Theme.tVioletFg)
            EntityFlow(spacing: 10) {
                alertOption("Final score", on: alerts.final) { saveAlerts(.init(start: false, scores: alerts.scores, final: !alerts.final)) }
                alertOption("Every score", on: alerts.scores) { saveAlerts(.init(start: false, scores: !alerts.scores, final: alerts.final)) }
            }
            .padding(.top, 14)
            alertNote
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tViolet, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: Before

    private func preSections(_ game: FindGameSection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            watchCard
            tiles(game)
            summaryBlock(game)

            let records = recordRows(game)
            if game.series == nil && !records.isEmpty {
                card("Records") {
                    ForEach(Array(records.enumerated()), id: \.offset) { index, team in
                        inlineRow(strong: team.short, soft: team.standing ?? "", divider: index > 0) {
                            Text(team.record ?? "").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            seasonSeries(game)
            if let past = game.past, !past.isEmpty { pastMatchups(past, boxed: false) }
        }
    }

    private var startWord: String {
        switch game?.league {
        case "nba", "mens-college-basketball": return "tip-off"
        case "mlb": return "first pitch"
        default: return "kickoff"
        }
    }

    private var alertChoice: String? {
        if alerts.start && alerts.final { return "both" }
        if alerts.start { return "start" }
        if alerts.final { return "final" }
        return nil
    }

    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Watch this game").font(Theme.font(20, weight: .bold)).foregroundStyle(Theme.tVioletFg)
            Text("We’ll tell you when it starts, or just send the final.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            EntityFlow(spacing: 10) {
                alertOption("Alert at \(startWord)", on: alertChoice == "start") { chooseAlert("start") }
                alertOption("Final score only", on: alertChoice == "final") { chooseAlert("final") }
                alertOption("Both", on: alertChoice == "both") { chooseAlert("both") }
            }
            .padding(.top, 14)
            alertNote
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tViolet, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var alertNote: some View {
        Text(alertMessage.isEmpty ? "Find sends these as notifications; History shows them too." : alertMessage)
            .font(Theme.font(12))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
    }

    private func alertOption(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                Text(label).font(Theme.font(15, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(on ? .white : Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(on ? Theme.indigoFill : Theme.bg, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(alertBusy)
        .opacity(alertBusy ? 0.7 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func tiles(_ game: FindGameSection) -> some View {
        let startLabel = startWord == "kickoff" ? "Kickoff" : startWord == "tip-off" ? "Tip-off" : "First pitch"
        let items: [(String, String)] = [
            game.start.map { _ in (startLabel, "\(dayOf(game.start)) · \(timeOf(game.start))") },
            (game.tv ?? "").isEmpty ? nil : ("TV", game.tv ?? ""),
            venueText(game).isEmpty ? nil : ("Venue", venueText(game)),
            game.line.map { ("Line", $0.spread + (($0.overUnder ?? "").isEmpty ? "" : " · O/U \($0.overUnder ?? "")")) },
        ].compactMap { $0 }
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.0) { tile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tile.0).font(Theme.font(13)).foregroundStyle(Theme.muted)
                            Text(tile.1).font(Theme.font(17, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    /// The better record first.
    private func recordRows(_ game: FindGameSection) -> [FindGameTeam] {
        [game.home, game.away].filter { !($0.record ?? "").isEmpty }.sorted { winPct($0.record) > winPct($1.record) }
    }

    private func winPct(_ record: String?) -> Double {
        let parts = (record ?? "").split(separator: "-").map { Double($0) ?? 0 }
        let wins = parts.first ?? 0
        let ties = parts.count > 2 ? parts[2] : 0
        let games = parts.reduce(0, +)
        return games > 0 ? (wins + ties / 2) / games : 0
    }

    @ViewBuilder
    private func seasonSeries(_ game: FindGameSection) -> some View {
        if let series = game.series, let record = series.record, !record.isEmpty {
            card("Season series") {
                inlineRow(strong: record, soft: "this season", divider: false) {
                    let finals = series.games.filter { $0.status == "final" && $0.current != true }
                    if let last = finals.last, let url = URL(string: "https://www.espn.com/\(game.league)/recap?gameId=\(last.id)") {
                        Link(destination: url) {
                            Text("Game \(last.number) recap ›").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.indigo)
                        }
                    }
                }
            }
        }
    }

    // MARK: Final

    private func finalSections(_ game: FindGameSection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            scoreTable(game)
            if let leaders = game.leaders, !leaders.isEmpty {
                card("Top players") {
                    ForEach(Array(leaders.enumerated()), id: \.offset) { _, row in
                        EntityRow(name: row.name, value: row.line, sub: [row.teamAbbr, row.pos, row.category].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
            }
            summaryBlock(game)
            seasonSeries(game)
            if let past = game.past, !past.isEmpty { pastMatchups(past, boxed: true) }
        }
    }

    // MARK: Shared pieces

    private func summaryBlock(_ game: FindGameSection) -> some View {
        let kind = summary?.kind ?? (game.status == "pre" ? "preview" : game.status == "final" ? "recap" : "summary")
        return EntitySummaryBlock(summary: summary, isLoading: summaryLoading, title: "16Ahead \(kind)")
    }

    @ViewBuilder
    private func scoreTable(_ game: FindGameSection) -> some View {
        if let table = game.byPeriod, table.count > 0 {
            let word = (table.word ?? "").ifEmpty("quarter")
            let periods = Array(0..<table.count)
            card("Score by \(word)") {
                let grid = Grid(horizontalSpacing: 6, verticalSpacing: 0) {
                    GridRow {
                        Text("Team").gridColumnAlignment(.leading)
                        ForEach(periods, id: \.self) { index in Text(periodLabel(index, word: word)) }
                        Text("T")
                    }
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
                    Rectangle().fill(Theme.bg).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    scoreLine(game.away.abbr, table.away, total: game.score?.away, periods: periods)
                    Rectangle().fill(Theme.bg).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    scoreLine(game.home.abbr, table.home, total: game.score?.home, periods: periods)
                }
                .monospacedDigit()
                if table.count > 6 {
                    ScrollView(.horizontal, showsIndicators: false) { grid }
                } else {
                    grid
                }
            }
        }
    }

    private func scoreLine(_ abbr: String, _ values: [String?], total: String?, periods: [Int]) -> some View {
        GridRow {
            Text(abbr).font(Theme.font(15, weight: .bold)).frame(minWidth: 44, alignment: .leading)
            ForEach(periods, id: \.self) { index in
                Text((values.indices.contains(index) ? values[index] : nil) ?? "–")
                    .font(Theme.font(15))
                    .frame(minWidth: 26, maxWidth: .infinity)
            }
            Text(total ?? "").font(Theme.font(15, weight: .heavy)).frame(minWidth: 30, maxWidth: .infinity)
        }
        .foregroundStyle(Theme.text)
        .padding(.vertical, 10)
    }

    private func periodLabel(_ index: Int, word: String) -> String {
        let regulation = word == "half" ? 2 : word == "inning" ? 9 : 4
        if index < regulation || word == "inning" { return String(index + 1) }
        return index == regulation ? "OT" : "\(index - regulation + 1)OT"
    }

    private func pastMatchups(_ past: [FindGameSection.Past], boxed: Bool) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            EntitySectionLabel(text: "Past matchups").padding(.bottom, 6)
            ForEach(Array(past.enumerated()), id: \.offset) { index, item in
                inlineRow(strong: item.result, soft: [pastDate(item.date), item.venue ?? ""].filter { !$0.isEmpty }.joined(separator: " · "), divider: index > 0) {
                    if let link = item.recapUrl, let url = URL(string: link) {
                        Link(destination: url) {
                            Text("Recap ›").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.indigo)
                        }
                    }
                }
            }
        }
        return Group {
            if boxed {
                rows
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))
            } else {
                rows
            }
        }
    }

    /// A surface card with an uppercase label.
    private func card<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EntitySectionLabel(text: label).padding(.bottom, 6)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// "Bears · 3rd in NFC North ........ 7-2".
    private func inlineRow<Trailing: View>(strong: String, soft: String, divider: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            (Text(strong).font(Theme.font(16, weight: .bold)).foregroundColor(Theme.text)
                + Text(soft.isEmpty ? "" : " · \(soft)").font(Theme.font(14)).foregroundColor(Theme.muted))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Theme.surface2).frame(height: 1) }
        }
    }

    // MARK: Alerts ("Watch this game")

    private func chooseAlert(_ choice: String) {
        let next = choice == alertChoice ? FindGameWatch.Alerts.none
            : FindGameWatch.Alerts(start: choice != "final", scores: false, final: choice != "start")
        saveAlerts(next)
    }

    private func saveAlerts(_ next: FindGameWatch.Alerts) {
        guard let game, !alertBusy else { return }
        let previous = alerts
        alerts = next
        alertMessage = ""
        alertBusy = true
        let watch = FindGameWatch(league: game.league, eventId: game.id, alerts: next)
        let url = (game.links?.gamecast ?? "").ifEmpty("https://www.espn.com/\(game.league)/game/_/gameId/\(game.id)")
        Task {
            let failure = await watchStore.setGameAlerts(query: query.ifEmpty(plainTitle(game)), url: url, title: plainTitle(game), game: watch)
            alertBusy = false
            if let failure {
                alerts = previous
                alertMessage = failure
            }
        }
    }

    // MARK: Actions

    private func actions(_ game: FindGameSection) -> [EntityAction] {
        let links = game.links
        let espn = links?.gamecast
        switch game.status {
        case "live":
            let tv = game.tv ?? ""
            return [
                tv.isEmpty ? nil : EntityAction("Watch on \(tv)", systemImage: "tv", url: tvUrl(tv, fallback: espn)),
                EntityAction("Live stats on ESPN", systemImage: "chart.bar", url: espn),
            ].compactMap { $0 }
        case "final":
            return [
                EntityAction("Full box score on ESPN", systemImage: "list.number", url: (links?.boxscore ?? "").ifEmpty(espn ?? "")),
                EntityAction("Recap", systemImage: "doc.text", url: links?.recap),
                EntityAction("\(game.home.short) team card", systemImage: "person.3") { onSearch(game.home.name) },
                EntityAction("\(game.away.short) team card", systemImage: "person.3") { onSearch(game.away.name) },
            ].compactMap { $0 }
        default:
            return [
                EntityAction("Preview on ESPN", systemImage: "doc.text", url: (links?.preview ?? "").ifEmpty(espn ?? "")),
                EntityAction("Tickets", systemImage: "ticket", url: links?.tickets),
                FindEntityFormat.date(game.start) == nil ? nil : EntityAction("Add to calendar", systemImage: "calendar.badge.plus") { showingCalendar = true },
            ].compactMap { $0 }
        }
    }

    private func tvUrl(_ network: String, fallback: String?) -> String? {
        let known = [
            "Fox": "https://www.foxsports.com/live", "CBS": "https://www.cbs.com/live-tv/", "NBC": "https://www.peacocktv.com/sports",
            "ESPN": "https://www.espn.com/watch/", "ESPN2": "https://www.espn.com/watch/", "ABC": "https://abc.com/watch-live",
            "Prime Video": "https://www.amazon.com/primevideo", "Netflix": "https://www.netflix.com",
            "NFLN": "https://www.nfl.com/network/watch/nfl-network-live", "TNT": "https://www.tntdrama.com/watchtnt",
            "Big Ten Network": "https://www.foxsports.com/live/btn", "BTN": "https://www.foxsports.com/live/btn",
        ]
        return known[network] ?? fallback
    }

    // MARK: Formatting

    /// "3rd quarter", "2nd half", "Top 5th", "Overtime".
    private func periodName(_ game: FindGameSection) -> String {
        guard let live = game.live else { return "" }
        if game.league == "mlb" { return live.detail ?? "" }
        let word = (game.byPeriod?.word ?? "").ifEmpty("quarter")
        let regulation = word == "half" ? 2 : 4
        guard let period = live.period, period > 0 else { return live.detail ?? "" }
        if period > regulation { return "Overtime" }
        return "\(ordinal(period)) \(word)"
    }

    /// "3rd · 8:42".
    private func clockLine(_ game: FindGameSection) -> String {
        guard let live = game.live else { return "" }
        guard game.league != "mlb", let period = live.period, period > 0 else { return live.detail ?? "" }
        let regulation = game.byPeriod?.word == "half" ? 2 : 4
        return [period > regulation ? "OT" : ordinal(period), live.clock ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func ordinal(_ n: Int) -> String {
        ["", "1st", "2nd", "3rd"].indices.contains(n) && n > 0 ? ["", "1st", "2nd", "3rd"][n] : "\(n)th"
    }

    /// "10:00 AM".
    private func timeOf(_ iso: String?) -> String {
        FindEntityFormat.date(iso).map { FindEntityFormat.format($0, "jmm") } ?? ""
    }

    /// "Sun, Nov 22".
    private func dayOf(_ iso: String?) -> String {
        FindEntityFormat.date(iso).map { FindEntityFormat.format($0, "EEEMMMd") } ?? ""
    }

    /// "Oct 4" this season, "Oct 2025" before.
    private func pastDate(_ iso: String?) -> String {
        guard let date = FindEntityFormat.date(iso) else { return "" }
        return -date.timeIntervalSinceNow < 200 * 24 * 3600 ? FindEntityFormat.format(date, "MMMd") : FindEntityFormat.format(date, "MMMyyyy")
    }
}

// MARK: Crest

/// A lettered circle in the team's colour (never a logo); white or near-black
/// letters, whichever reads on it. Four-letter abbreviations get smaller text.
struct GameCrest: View {
    let abbr: String
    let color: String?
    let size: CGFloat

    var body: some View {
        let rgb = Self.rgb(color) ?? (0x5a / 255, 0x61 / 255, 0x70 / 255)
        let long = abbr.count > 3
        let fontSize: CGFloat = size >= 50 ? (long ? 15 : 20) : (long ? 10 : 13)
        Text(abbr)
            .font(Theme.font(fontSize, weight: .heavy))
            .tracking(long ? -0.6 : -0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(Self.readsDark(rgb) ? Color(hex: 0x0f1115) : .white)
            .padding(.horizontal, 4)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: size >= 50 ? 3 : 2))
            .accessibilityHidden(true)
    }

    private static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// Relative luminance above 0.45 takes dark letters.
    private static func readsDark(_ rgb: (Double, Double, Double)) -> Bool {
        let linear = [rgb.0, rgb.1, rgb.2].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2] > 0.45
    }
}

// MARK: Add to calendar

/// The system's new-event sheet, filled in. On iOS 17 it runs out of process,
/// so Find needs no calendar permission: the person saves or cancels it.
struct GameCalendarSheet: UIViewControllerRepresentable {
    let game: FindGameSection
    let title: String
    let location: String
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = context.coordinator.store
        let event = EKEvent(eventStore: store)
        event.title = title
        if let start = FindEntityFormat.date(game.start) {
            event.startDate = start
            event.endDate = start.addingTimeInterval(3.5 * 3600)
        }
        event.location = location
        let notes = [(game.tv ?? "").isEmpty ? nil : "On \(game.tv ?? "")", game.links?.gamecast].compactMap { $0 }.filter { !$0.isEmpty }
        event.notes = notes.joined(separator: " · ")
        if let link = game.links?.gamecast, let url = URL(string: link) { event.url = url }
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
