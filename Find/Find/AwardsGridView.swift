import SwiftUI

// Mirrors the web app's Awards screen (find-home.component.html, Find Score
// 2026-11-17): the score card (nickname, rank, points, progress to the next
// rank, streak, this week, Share my score), the badges by kind, and the
// six-word recovery code for moving to a new phone. Without a profile yet
// (offline, first launch) it shows the old progress bar and ladder.
struct AwardsGridView: View {
    @ObservedObject var awardsService: FindAwardsService

    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var nameError = ""
    @State private var recoveryCode = ""
    @State private var recoveryInput = ""
    @State private var recoveryMessage = ""
    @State private var showRecoverField = false
    @State private var shareImage: Image?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let profile = awardsService.profile {
                scoreCard(profile)
            } else {
                progressBar
            }

            ForEach(awardsService.groups) { group in
                VStack(alignment: .leading, spacing: 16) {
                    if awardsService.groups.count > 1 {
                        Text(group.title.uppercased())
                            .font(Theme.font(12, weight: .bold))
                            .tracking(1.4)
                            .foregroundStyle(Theme.subtext)
                    }
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(group.awards) { award in
                            badgeCell(award)
                        }
                    }
                }
            }

            if awardsService.profile != nil {
                recoverySection
            }
        }
        .task { await awardsService.refresh() }
        .task(id: awardsService.profile) { renderShareImage() }
        .alert("Your nickname", isPresented: $editingName) {
            TextField("3 to 20 characters", text: $nameDraft)
                .textInputAutocapitalization(.words)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on your score and to friends.")
        }
    }

    // MARK: Score card

    private func scoreCard(_ profile: FindScoreProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(profile.nickname)
                    .font(Theme.font(20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Button(profile.hasNickname ? "Change name" : "Pick a nickname") {
                    nameDraft = profile.hasNickname ? profile.nickname : ""
                    nameError = ""
                    editingName = true
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
            if !nameError.isEmpty {
                Text(nameError)
                    .font(Theme.font(13))
                    .foregroundStyle(.red)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(profile.rank.name)
                    .font(Theme.font(28, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                Spacer()
                (Text(profile.score.formatted()).font(Theme.font(24, weight: .heavy)).foregroundStyle(Theme.text)
                    + Text(" points").font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.subtext))
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                bar(awardsService.rankProgress)
                Text(profile.rank.next.map { "\($0.toGo.formatted()) to \($0.name)" } ?? "Top rank")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { stats(profile) }
                VStack(alignment: .leading, spacing: 6) { stats(profile) }
            }

            if let shareImage {
                ShareLink(
                    item: shareImage,
                    subject: Text("My Find Score"),
                    message: Text("\(shareText(profile))\n\(profile.shareUrl)"),
                    preview: SharePreview("My Find Score", image: shareImage)
                ) {
                    Label("Share my score", systemImage: "square.and.arrow.up")
                        .font(Theme.font(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func stats(_ profile: FindScoreProfile) -> some View {
        Label("\(profile.streak.count)-day streak", systemImage: "flame.fill")
            .labelStyle(StreakLabelStyle())
        Text("\(profile.weekScore.formatted()) this week")
        Text("\(awardsService.unlockedCount) of \(awardsService.totalCount) badges")
    }

    private func shareText(_ profile: FindScoreProfile) -> String {
        var text = "\(profile.nickname) · \(profile.rank.name) · \(profile.score.formatted()) on Find"
        if profile.streak.count > 1 { text += " · \(profile.streak.count)-day streak" }
        return text
    }

    private func saveName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                try await awardsService.setNickname(name)
                nameError = ""
            } catch {
                nameError = error.localizedDescription
            }
        }
    }

    /// The square card "Share my score" sends, drawn on the phone.
    @MainActor
    private func renderShareImage() {
        guard let profile = awardsService.profile else { return }
        let topBadge = profile.badges.last(where: { $0.state == "earned" })?.title
        let renderer = ImageRenderer(content: ScoreShareCard(profile: profile, topBadge: topBadge))
        renderer.scale = 1
        if let image = renderer.uiImage {
            shareImage = Image(uiImage: image)
        }
    }

    // MARK: Badges

    private func badgeCell(_ award: FindAwardListItem) -> some View {
        VStack(spacing: 10) {
            AwardBadgeView(icon: award.icon, state: award.state)
            Text(award.state == .mystery ? "\u{2014} \u{2014} \u{2014}" : award.title)
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(titleColor(for: award.state))
                .tracking(award.state == .mystery ? 1 : 0)
                .multilineTextAlignment(.center)
            if award.state == .locked, let goal = award.goal {
                Text(goal)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.subtext)
                    .multilineTextAlignment(.center)
                    .padding(.top, -6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(award.state == .unlocked ? award.copy : (award.goal ?? ""))
    }

    private var progressBar: some View {
        HStack(spacing: 12) {
            bar(awardsService.progressPercent)
            Text("\(awardsService.unlockedCount) of \(awardsService.totalCount) unlocked")
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(Theme.subtext)
                .fixedSize()
        }
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.6), Theme.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    private func titleColor(for state: FindAwardState) -> Color {
        switch state {
        case .unlocked: return Theme.text
        case .locked: return Theme.subtext
        case .mystery: return Theme.subtext.opacity(0.5)
        }
    }

    // MARK: Recovery code

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.bottom, 12)
            Text("Moving to a new phone?")
                .font(Theme.font(16, weight: .bold))
                .foregroundStyle(Theme.text)
            if recoveryCode.isEmpty {
                Text("Your score lives on this phone. Save your recovery code to take it with you.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.subtext)
                Button("Show my recovery code") {
                    Task {
                        do {
                            recoveryCode = try await awardsService.recoveryCode()
                        } catch {
                            recoveryMessage = "Couldn\u{2019}t load your code. Try again."
                        }
                    }
                }
                .font(Theme.font(14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            } else {
                Text(recoveryCode)
                    .font(Theme.font(16, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Write it down. Typing it on another phone moves your score there.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.subtext)
            }
            if showRecoverField {
                HStack(spacing: 8) {
                    TextField("six words", text: $recoveryInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("Move score here") { recover() }
                        .font(Theme.font(14, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .disabled(recoveryInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("I have a code") { showRecoverField = true }
                    .font(Theme.font(14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            if !recoveryMessage.isEmpty {
                Text(recoveryMessage)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.subtext)
            }
        }
        .padding(.top, 14)
    }

    private func recover() {
        let code = recoveryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let moved = try await awardsService.recover(code: code)
                recoveryInput = ""
                showRecoverField = false
                recoveryMessage = "Welcome back, \(moved.nickname)."
            } catch {
                recoveryMessage = error.localizedDescription
            }
        }
    }
}

private struct StreakLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title
        }
    }
}

/// The square image "Share my score" sends (web: scoreCardFile in find-home).
private struct ScoreShareCard: View {
    let profile: FindScoreProfile
    let topBadge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Find")
                .font(.custom("Helvetica Neue", fixedSize: 44).weight(.bold))
                .foregroundStyle(Color(red: 0.5, green: 0.7, blue: 0.85))
            Spacer()
            Text(profile.nickname)
                .font(.custom("Helvetica Neue", fixedSize: 96).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("\(profile.rank.name) · \(profile.score.formatted())")
                .font(.custom("Helvetica Neue", fixedSize: 64).weight(.bold))
                .foregroundStyle(Color(red: 0.66, green: 0.88, blue: 1))
                .padding(.top, 16)
            if !details.isEmpty {
                Text(details)
                    .font(.custom("Helvetica Neue", fixedSize: 44))
                    .foregroundStyle(Color(white: 0.8))
                    .padding(.top, 16)
            }
            Spacer()
            Text("See how you\u{2019}d score · find.16ahead.com")
                .font(.custom("Helvetica Neue", fixedSize: 38))
                .foregroundStyle(Color(white: 0.5))
        }
        .padding(96)
        .frame(width: 1080, height: 1080, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.08), Color(red: 0.08, green: 0.15, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var details: String {
        [profile.streak.count > 1 ? "\(profile.streak.count)-day streak" : nil, topBadge].compactMap { $0 }.joined(separator: " · ")
    }
}
