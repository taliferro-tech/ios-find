import SwiftUI

/// How-to answers with one video (design_handoff_find_howto_video, iPhone
/// artboard d; web: find-howto-card). The answer comes first (summary, steps,
/// facts, ingredients or what you need), then one YouTube video that loads
/// only when tapped. Chapter chips and the steps' timestamp pills jump the
/// video there and play it. No good video: no video, just a note and a
/// YouTube search link.
struct EntityHowToCard: View {
    let entity: FindEntity
    let fetch: @Sendable (String) async -> Data?
    @StateObject private var sections = EntitySections()

    /// The player is in (it only loads after a tap).
    @State private var isPlaying = false
    /// Where the player starts; a jump loads the embed again from there.
    @State private var start = 0
    @State private var reload = 0
    /// The chapter (or step) second last jumped to, for the active chip.
    @State private var activeSec: Int?
    @State private var openSteps: Set<Int> = []

    private var answer: FindHowToAnswer? { sections.value("answer", as: FindHowToAnswer.self) }
    private var videoSection: FindHowToVideoSection? { sections.value("video", as: FindHowToVideoSection.self) }
    private var video: FindHowToVideoSection.Video? { videoSection?.video }
    private var answerLoading: Bool { sections.isLoading("answer") }
    private var videoLoading: Bool { sections.isLoading("video") }
    /// The video lookup finished with nothing good enough.
    private var noVideo: Bool { !videoLoading && video == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EntityTagChips(tags: pills)

            titleBlock

            if !answerLoading && answer == nil {
                Text("Find couldn't put this answer together. More results has other guides.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EntitySummaryBlock(summary: summary, isLoading: answerLoading)

            videoBlock

            steps

            things

            if noVideo, answer != nil { noVideoCard }

            if let url = moreURL {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 15, weight: .semibold))
                        Text("\(moreLabel) ↗").font(Theme.font(15, weight: .bold)).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(Theme.blueInk)
                }
            }
        }
        .task { await sections.load(["answer", "video"], fetch: fetch) }
        // Leaving the card removes the player, which stops it.
        .onDisappear { stop() }
    }

    // MARK: Top

    private var pills: [FindEntityTag] {
        var tags = [FindEntityTag(text: "How-to", tone: "green")]
        if let category = categoryLabel { tags.append(FindEntityTag(text: category, tone: "yellow")) }
        if video != nil { tags.append(FindEntityTag(text: "\u{25B6}\u{FE0E} Video", tone: "pink")) }
        return tags
    }

    private var categoryLabel: String? {
        switch answer?.category {
        case "recipe": return "Recipe"
        case "diy": return "DIY"
        case "tech": return "Tech"
        default: return nil
        }
    }

    private var title: String {
        (answer?.title ?? "").ifEmpty(entity.name)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.font(30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = answer?.meta, !meta.isEmpty {
                    Text(meta)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if answerLoading {
                    EntitySkeleton(height: 16, radius: 8).frame(maxWidth: 220)
                }
            }
            EntityKeyFacts(facts: answer?.facts ?? [])
        }
    }

    /// The 16Ahead box, with ", video" on its sources when there's a video.
    private var summary: FindEntitySummary? {
        guard let summary = answer?.summary, !summary.text.isEmpty else { return nil }
        var names = (summary.sources ?? []).map(\.name)
        if video != nil { names.append("video") }
        return FindEntitySummary(text: summary.text, sources: names)
    }

    // MARK: Video

    @ViewBuilder
    private var videoBlock: some View {
        if videoLoading {
            VStack(alignment: .leading, spacing: 8) {
                EntitySkeleton(radius: 22).aspectRatio(16 / 9, contentMode: .fit)
                EntitySkeleton(height: 16, radius: 8).frame(maxWidth: 240)
            }
            .accessibilityHidden(true)
        } else if let video {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Color(red: 0.047, green: 0.055, blue: 0.075)
                    if isPlaying {
                        YouTubeEmbedView(videoID: video.id, noCookie: true, start: start, reload: reload)
                    } else {
                        poster(video)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityIdentifier("find-howto-video")

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(Theme.font(16, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((["YouTube", video.channel, video.duration] as [String?]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }

                if let chapters = video.chapters, !chapters.isEmpty { chapterChips(chapters) }
            }
        }
    }

    private func poster(_ video: FindHowToVideoSection.Video) -> some View {
        Button {
            play(at: 0)
            activeSec = nil
        } label: {
            ZStack {
                if let url = FindWebURL.resolve(video.thumbUrl) ?? URL(string: "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg") {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)
            }
            .overlay(alignment: .topTrailing) {
                if let duration = video.duration, !duration.isEmpty {
                    Text(duration)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(14)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.07, blue: 0.08))
                    .frame(width: 60, height: 60)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 15, y: 10)
                    .padding(16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(video.title) on YouTube")
    }

    private func chapterChips(_ chapters: [FindHowToVideoSection.Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Jump to")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                        let sec = Int(chapter.sec)
                        let isOn = isPlaying && activeSec == sec
                        Button {
                            play(at: sec)
                        } label: {
                            (Text(chapter.title).font(Theme.font(15, weight: .bold)) + Text("  \(Self.clock(sec))").font(Theme.font(15)))
                                .lineLimit(1)
                                .foregroundStyle(isOn ? Theme.bg : Theme.text)
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background(isOn ? Theme.text : Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chapter.title), \(Self.clock(sec))")
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: Steps and what you need

    @ViewBuilder
    private var steps: some View {
        if let steps = answer?.steps, !steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                label("Steps")
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    stepRow(step, index: index)
                }
            }
        } else if answerLoading {
            EntitySkeleton(height: 160)
        }
    }

    private func stepRow(_ step: FindHowToAnswer.Step, index: Int) -> some View {
        let isOpen = openSteps.contains(index)
        let detail = step.detail ?? ""
        return HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(Theme.font(15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Theme.blue, in: Circle())
                .accessibilityHidden(true)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOpen { openSteps.remove(index) } else { openSteps.insert(index) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(Theme.font(17, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if isOpen, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detail.isEmpty)
            .accessibilityLabel("Step \(index + 1): \(step.title)")
            .accessibilityHint(detail.isEmpty ? "" : isOpen ? "Hides the detail" : "Shows the detail")

            if let sec = stepChapter(index) {
                Button {
                    play(at: sec)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text(Self.clock(sec)).font(Theme.font(14, weight: .bold))
                    }
                    .foregroundStyle(Theme.tBlueFg)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.tBlue, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(step.title) at \(Self.clock(sec))")
            }
        }
        .padding(.vertical, 6)
    }

    private var thingsList: [String] {
        if let ingredients = answer?.ingredients, !ingredients.isEmpty { return ingredients }
        return answer?.tools ?? []
    }

    @ViewBuilder
    private var things: some View {
        let list = thingsList
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                label(answer?.ingredients?.isEmpty == false ? "Ingredients" : "What you need")
                ForEach(Array(list.enumerated()), id: \.offset) { _, thing in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.muted).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(thing)
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var noVideoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Video")
            Text("We didn't find a video good enough to recommend for this one.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.surface2, lineWidth: 2))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.font(13, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }

    // MARK: More videos

    /// "More key lime pie videos on YouTube".
    private var moreLabel: String {
        let topic = title.lowercased()
        return topic.isEmpty ? "More videos on YouTube" : "More \(topic) videos on YouTube"
    }

    private var moreURL: URL? {
        FindWebURL.resolve((videoSection?.moreUrl ?? "").ifEmpty(answer?.moreUrl ?? ""))
    }

    // MARK: Playing

    /// The step's second in the video (0 counts), or nil when there's none.
    private func stepChapter(_ index: Int) -> Int? {
        guard video != nil, let chapters = videoSection?.stepChapters, chapters.indices.contains(index), let sec = chapters[index] else { return nil }
        return Int(sec)
    }

    /// Plays from the start, or jumps to a second and plays.
    private func play(at sec: Int) {
        guard video != nil else { return }
        activeSec = sec
        start = max(0, sec)
        if isPlaying { reload += 1 } else { isPlaying = true }
    }

    private func stop() {
        isPlaying = false
        activeSec = nil
    }

    /// 178 -> "2:58", 3730 -> "1:02:10".
    static func clock(_ sec: Int) -> String {
        let h = sec / 3600, m = sec % 3600 / 60, s = sec % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
