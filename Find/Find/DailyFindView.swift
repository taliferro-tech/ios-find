import SwiftUI

/// Daily Find (web: find-home/daily/find-daily.component): today's question,
/// the same for everyone. Start it, search with Find as usual (the search
/// counts toward it), then pick one of four answers.
struct DailyFindView: View {
    @ObservedObject var store: FindDailyStore
    /// Runs this search in Find, counted for today's question.
    let onSearch: (String) -> Void
    /// What answering earned (Find Score), for the unlock overlay.
    let onScore: (FindScoreAward?) -> Void

    @State private var query = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("DAILY FIND")
                        .font(Theme.font(12, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Theme.accent)

                    if let state = store.state {
                        if state.available {
                            content(state)
                        } else {
                            muted("No Daily Find today. Check back tomorrow.")
                        }
                    } else if store.isLoading {
                        ProgressView("Loading today\u{2019}s question\u{2026}")
                    }

                    if !store.message.isEmpty {
                        Text(store.message)
                            .font(Theme.font(14))
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private func content(_ state: FindDailyState) -> some View {
        Text(state.question ?? "")
            .font(Theme.font(22, weight: .bold))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)

        switch state.status {
        case "new":
            muted("The same question for everyone today. Find the answer with Find, then pick it from four choices. Right on your first search, inside a minute, scores 100.")
            primaryButton("Start") {
                busy = true
                await store.start()
                busy = false
            }
        case "playing":
            HStack(spacing: 8) {
                TextField("Search for the answer\u{2026}", text: $query)
                    .submitLabel(.search)
                    .onSubmit(runSearch)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                Button("Find", action: runSearch)
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let searches = state.searches ?? 0
            if let choices = state.choices, !choices.isEmpty {
                muted("\(searches) \(searches == 1 ? "search" : "searches") so far. Found it? Pick the answer.")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Button {
                            Task {
                                busy = true
                                let score = await store.answer(index)
                                busy = false
                                onScore(score)
                            }
                        } label: {
                            choiceLabel(choice, style: .open)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            } else {
                muted("Search first; the answers show up after your first search.")
            }
        case "answered":
            if let result = state.result {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.correct ? "Right!" : "Not this time.")
                        .font(Theme.font(20, weight: .bold))
                    Spacer()
                    (Text("\(result.points)").font(Theme.font(26, weight: .heavy)) + Text(" points").font(Theme.font(13, weight: .semibold)))
                }
                .foregroundStyle(Theme.text)
                .padding(16)
                .background((result.correct ? Color.green : Color.red).opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if result.correct, let beat = result.beat {
                    Text("You beat \(beat)% of Finders today.")
                        .font(Theme.font(15, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                if let choices = state.choices {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                            choiceLabel(choice, style: index == result.answerIndex ? .right : (index == result.choice ? .wrong : .faded))
                        }
                    }
                }
                if !result.explanation.isEmpty {
                    muted(result.explanation)
                }
                if let url = URL(string: result.sourceUrl), !result.sourceUrl.isEmpty {
                    Link(result.sourceTitle.isEmpty ? "Source" : result.sourceTitle, destination: url)
                        .font(Theme.font(14, weight: .semibold))
                }
                ShareLink(item: URL(string: "https://find.16ahead.com/?daily=1")!, message: Text(shareText(result))) {
                    Label("Share my result", systemImage: "square.and.arrow.up")
                        .font(Theme.font(15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
                muted("A new question tomorrow.")
            }
        default:
            EmptyView()
        }
    }

    private enum ChoiceStyle { case open, right, wrong, faded }

    private func choiceLabel(_ text: String, style: ChoiceStyle) -> some View {
        let border: Color = switch style {
        case .right: .green
        case .wrong: .red
        default: Theme.border
        }
        return Text(text)
            .font(Theme.font(16, weight: .semibold))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 10)
            .background(style == .right ? Color.green.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(border, lineWidth: style == .open || style == .faded ? 1 : 2))
            .opacity(style == .faded ? 0.6 : 1)
    }

    private func muted(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(15))
            .foregroundStyle(Theme.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(Theme.font(16, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSearch(trimmed)
        dismiss()
    }

    private func shareText(_ result: FindDailyResult) -> String {
        guard result.correct else { return "Today\u{2019}s Daily Find got me. Can you get it?" }
        if let beat = result.beat { return "I scored \(result.points) on today\u{2019}s Daily Find and beat \(beat)% of Finders. Can you beat it?" }
        return "I scored \(result.points) on today\u{2019}s Daily Find. Can you beat it?"
    }
}
