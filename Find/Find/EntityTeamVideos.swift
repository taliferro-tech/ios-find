import SwiftUI

/// A team's latest videos under the scores (design_handoff_find_team_videos,
/// v2; web: find-team-videos): one main stage plus two smaller videos, each
/// behind theater curtains in the team's colours. Nothing loads from YouTube
/// until a curtain is tapped. Tapping the main curtain opens it and plays;
/// tapping a small one swaps it onto the main stage (which opens and plays)
/// and drops the old main video, player removed, into that spot with its
/// curtain closed again. Only the main stage ever plays.
struct EntityTeamVideosRow: View {
    let row: FindTeamVideos

    /// The video on the main stage, and the ones in the spots underneath (by index, in spot order).
    @State private var mainIndex = 0
    @State private var swappedSmalls: [Int]?
    /// The main curtain is open (and, if the video can be embedded, its player is in).
    @State private var isOpen = false
    /// The main stage is scaling and fading in after a swap.
    @State private var swapIn = false
    @State private var swapTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var videos: [FindTeamVideos.Video] { Array(row.videos.prefix(3)) }
    private var smalls: [Int] { swappedSmalls ?? Array(videos.indices.dropFirst()) }
    private var palette: CurtainPalette { CurtainPalette(primary: row.colors?.primary, accent: row.colors?.accent) }

    var body: some View {
        if videos.indices.contains(mainIndex) {
            let main = videos[mainIndex]
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest videos")
                        .font(Theme.font(22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(sourceLine)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 6)

                mainStage(main)
                    .id(mainIndex)
                    .scaleEffect(swapIn && !reduceMotion ? 0.94 : 1)
                    .opacity(swapIn ? 0.4 : 1)

                if isOpen && main.embeddable != false {
                    HStack(spacing: 6) {
                        Text("●").accessibilityHidden(true)
                        Text("NOW PLAYING").tracking(0.5)
                    }
                    .font(Theme.font(13, weight: .heavy))
                    .foregroundStyle(Color(hex: 0xe5484d))
                    .padding(.top, 4)
                }
                Text(main.title)
                    .font(Theme.font(20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                tagLine(main)

                if !smalls.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(smalls.enumerated()), id: \.element) { slot, index in
                            smallTile(videos[index], slot: slot)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if smalls.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                    .padding(.top, 10)

                    Text("Tap a video below the big screen to bring it up front.")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                if let url = FindWebURL.resolve(row.moreUrl) {
                    Link(destination: url) {
                        Text("More on YouTube ↗").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.blueInk)
                    }
                    .padding(.top, 6)
                }
            }
            .accessibilityIdentifier("find-team-videos")
            // Leaving the card removes the player, which stops it.
            .onDisappear {
                swapTask?.cancel()
                swapIn = false
                isOpen = false
            }
        }
    }

    /// "The newest from the Chicago Bears and the NFL on YouTube."
    private var sourceLine: String {
        let league = (row.league ?? "").trimmingCharacters(in: .whitespaces)
        return "The newest from the \(row.team)\(league.isEmpty ? "" : " and the \(league)") on YouTube."
    }

    // MARK: Stages

    private func mainStage(_ video: FindTeamVideos.Video) -> some View {
        let embeddable = video.embeddable != false
        let playing = isOpen && embeddable
        return ZStack {
            Color(hex: 0x07080c)
            if playing {
                FadeInPlayer(videoID: video.id, delay: reduceMotion ? 0 : 0.55)
            }
            Button {
                isOpen = true
            } label: {
                TheaterCurtain(palette: palette, isOpen: playing, duration: video.duration, small: false)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!isOpen)
            .accessibilityLabel(playLabel(video))
            .accessibilityHidden(playing)

            if isOpen && !embeddable { youTubeOnly(video) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func smallTile(_ video: FindTeamVideos.Video, slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                swap(slot)
            } label: {
                TheaterCurtain(palette: palette, isOpen: false, duration: video.duration, small: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color(hex: 0x07080c))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playLabel(video))

            Text(video.title)
                .font(Theme.font(16, weight: .bold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            tagLine(video)
        }
    }

    /// Can't embed: the curtain stays closed under a dark note.
    private func youTubeOnly(_ video: FindTeamVideos.Video) -> some View {
        VStack(spacing: 12) {
            Text("Plays on YouTube only").font(Theme.font(16, weight: .bold)).foregroundStyle(.white)
            if let url = watchURL(video) {
                Link(destination: url) {
                    Text("Watch on YouTube ↗")
                        .font(Theme.font(15, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0f1115))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.white, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 5 / 255, green: 6 / 255, blue: 10 / 255).opacity(0.72))
        .transition(.opacity)
    }

    // MARK: Text

    /// "[Highlights] Chicago Bears · 3 days ago".
    private func tagLine(_ video: FindTeamVideos.Video) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let type = video.type, !type.isEmpty {
                let colors = EntityTone.colors(Self.tone(type))
                Text(type)
                    .font(Theme.font(13, weight: .bold))
                    .foregroundStyle(colors.foreground)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(colors.background, in: Capsule())
                    .fixedSize()
            }
            let line = [video.channel, Self.ago(video.publishedAt)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !line.isEmpty {
                Text(line)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func playLabel(_ video: FindTeamVideos.Video) -> String {
        "Play: \(video.title)" + ((video.type ?? "").isEmpty ? "" : " \(video.type ?? "")")
    }

    private func watchURL(_ video: FindTeamVideos.Video) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: video.id)]
        return components?.url
    }

    static func tone(_ type: String) -> String {
        switch type {
        case "Highlights": return "green"
        case "Press conference": return "blue"
        case "Top plays": return "yellow"
        case "Recap": return "violet"
        case "Analysis": return "cyan"
        default: return "plain"
        }
    }

    /// "Today", "1 day ago", "3 days ago", "2 weeks ago", then "Oct 4".
    static func ago(_ text: String?) -> String? {
        guard let date = FindEntityFormat.date(text) else { return nil }
        let days = Int(floor(Date().timeIntervalSince(date) / 86_400))
        if days <= 0 { return "Today" }
        if days == 1 { return "1 day ago" }
        if days < 7 { return "\(days) days ago" }
        let weeks = days / 7
        return weeks < 5 ? "\(weeks) week\(weeks > 1 ? "s" : "") ago" : FindEntityFormat.format(date, "MMMd")
    }

    // MARK: Swapping

    /// Brings the video in spot `slot` up to the main stage and plays it.
    private func swap(_ slot: Int) {
        let current = smalls
        guard current.indices.contains(slot) else { return }
        let incoming = current[slot]
        swapTask?.cancel()

        // The old main video's player goes away; it takes the tapped spot, curtain closed.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            isOpen = false
            var next = current
            next[slot] = mainIndex
            swappedSmalls = next
            mainIndex = incoming
            swapIn = true
        }
        swapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { swapIn = false }
            // A beat with the curtain closed, so it visibly opens on the new video.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            isOpen = true
        }
    }
}

/// The player, faded in once the curtain is mostly open (the tap counts as
/// the gesture, so it autoplays inline).
private struct FadeInPlayer: View {
    let videoID: String
    let delay: Double
    @State private var shown = false

    var body: some View {
        YouTubeEmbedView(videoID: videoID, noCookie: true)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeIn(duration: 0.4).delay(delay)) { shown = true }
            }
    }
}

// MARK: Curtains

/// The team's curtain colours: c1 primary, c2 lighter folds, c3 shadow, gold trim.
struct CurtainPalette {
    let c1: Color
    let c2: Color
    let c3: Color
    let gold: Color

    init(primary: String?, accent: String?) {
        let base = Self.rgb(primary) ?? (0x1b / 255, 0x24 / 255, 0x33 / 255)
        let trim = Self.rgb(accent) ?? (0xc9 / 255, 0xa2 / 255, 0x27 / 255)
        c1 = Self.color(base)
        c2 = Self.color(Self.mix(base, toward: 1, by: 0.2))
        c3 = Self.color(Self.mix(base, toward: 0, by: 0.6))
        gold = Self.color(trim)
    }

    private typealias RGB = (Double, Double, Double)

    private static func rgb(_ hex: String?) -> RGB? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    private static func mix(_ rgb: RGB, toward target: Double, by amount: Double) -> RGB {
        (rgb.0 + (target - rgb.0) * amount, rgb.1 + (target - rgb.1) * amount, rgb.2 + (target - rgb.2) * amount)
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Theater curtains drawn in SwiftUI: two folded panels (each 51% wide), a
/// valance with a trim and a curved bottom, a warm spotlight and the play
/// pill. Opening bunches the panels at the edges, lifts the valance and
/// fades the pill, then everything fades so nothing covers the player.
/// Reduce Motion skips the movement and just fades. No logos.
struct TheaterCurtain: View {
    let palette: CurtainPalette
    let isOpen: Bool
    let duration: String?
    let small: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let valanceHeight = height * 0.16
            let moves = isOpen && !reduceMotion

            ZStack(alignment: .topLeading) {
                panel(height: height, edge: .leading)
                    .frame(width: width * 0.51, height: height)
                    .scaleEffect(x: moves ? 0.13 : 1, y: 1, anchor: .leading)
                    .animation(moves ? .timingCurve(0.65, 0, 0.25, 1, duration: 0.9) : nil, value: isOpen)
                    .opacity(isOpen ? 0 : 1)
                    .animation(fade, value: isOpen)
                    .frame(width: width, height: height, alignment: .leading)

                panel(height: height, edge: .trailing)
                    .frame(width: width * 0.51, height: height)
                    .scaleEffect(x: moves ? 0.13 : 1, y: 1, anchor: .trailing)
                    .animation(moves ? .timingCurve(0.65, 0, 0.25, 1, duration: 0.9) : nil, value: isOpen)
                    .opacity(isOpen ? 0 : 1)
                    .animation(fade, value: isOpen)
                    .frame(width: width, height: height, alignment: .trailing)

                valance
                    .frame(width: width, height: valanceHeight)
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 6)
                    .offset(y: moves ? -valanceHeight * 0.75 : 0)
                    .animation(moves ? .timingCurve(0.6, 0, 0.3, 1, duration: 0.7).delay(0.1) : nil, value: isOpen)
                    .opacity(isOpen ? 0 : 1)
                    .animation(fade, value: isOpen)

                EllipticalGradient(
                    colors: [Color(red: 1, green: 0.94, blue: 0.78).opacity(0.22), Color(red: 1, green: 0.94, blue: 0.78).opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.6),
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.45
                )
                .frame(width: width, height: height)
                .opacity(isOpen ? 0 : 1)
                .animation(isOpen ? .easeOut(duration: 0.4) : nil, value: isOpen)

                pill
                    .position(x: width / 2, y: height * 0.56)
                    .opacity(isOpen ? 0 : 1)
                    .animation(isOpen ? .easeOut(duration: 0.25) : nil, value: isOpen)
            }
        }
        .contentShape(Rectangle())
    }

    /// The panels fade after they've bunched (right away with Reduce Motion); closing is instant.
    private var fade: Animation? {
        guard isOpen else { return nil }
        return reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.3).delay(0.9)
    }

    private func panel(height: CGFloat, edge: HorizontalEdge) -> some View {
        ZStack(alignment: .bottom) {
            // Folds: c3 → c1 → c2 → c1 → c3, every 9% of the panel.
            LinearGradient(stops: Self.folds(palette), startPoint: .leading, endPoint: .trailing)
            // A soft light and shade across the panel.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .black.opacity(0), location: 0.18),
                .init(color: .white.opacity(0.08), location: 0.30),
                .init(color: .black.opacity(0.25), location: 0.45),
                .init(color: .white.opacity(0.08), location: 0.60),
                .init(color: .black.opacity(0.30), location: 0.75),
                .init(color: .white.opacity(0.06), location: 0.88),
                .init(color: .black.opacity(0.35), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            // The darker hem.
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                .frame(height: height * 0.22)
        }
        .overlay(alignment: .trailing) {
            if edge == .leading { Rectangle().fill(.black.opacity(0.25)).frame(width: 2) }
        }
    }

    private var valance: some View {
        ZStack {
            ValanceShape()
                .fill(LinearGradient(stops: Self.repeating([palette.c3, palette.c1, palette.c3], period: 0.06), startPoint: .leading, endPoint: .trailing))
            ValanceTrim()
                .stroke(palette.gold, lineWidth: 3)
        }
    }

    private var pill: some View {
        HStack(spacing: small ? 6 : 10) {
            Image(systemName: "play.fill")
                .font(.system(size: small ? 9 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: small ? 22 : 32, height: small ? 22 : 32)
                .background(Color(hex: 0x0f1115), in: Circle())
            Text("Play" + ((duration ?? "").isEmpty ? "" : " · \(duration ?? "")"))
                .font(Theme.font(small ? 12 : 15, weight: .heavy))
                .foregroundStyle(Color(hex: 0x0f1115))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, small ? 5 : 7)
        .padding(.trailing, small ? 10 : 18)
        .frame(height: small ? 32 : 46)
        .background(.white.opacity(0.95), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }

    private static func folds(_ palette: CurtainPalette) -> [Gradient.Stop] {
        let pattern: [(Color, Double)] = [(palette.c3, 0), (palette.c1, 0.02), (palette.c2, 0.045), (palette.c1, 0.07)]
        var stops: [Gradient.Stop] = []
        var base = 0.0
        while base < 1 {
            for (color, offset) in pattern where base + offset <= 1 {
                stops.append(.init(color: color, location: base + offset))
            }
            base += 0.09
        }
        stops.append(.init(color: palette.c3, location: 1))
        return stops
    }

    private static func repeating(_ colors: [Color], period: Double) -> [Gradient.Stop] {
        let step = period / Double(colors.count - 1)
        var stops: [Gradient.Stop] = []
        var base = 0.0
        while base < 1 {
            for (offset, color) in colors.enumerated().dropLast() where base + Double(offset) * step <= 1 {
                stops.append(.init(color: color, location: base + Double(offset) * step))
            }
            base += period
        }
        stops.append(.init(color: colors[colors.count - 1], location: 1))
        return stops
    }
}

/// Straight across the top, a curved bottom that dips in the middle.
private struct ValanceShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.7), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 1.3))
        path.closeSubpath()
        return path
    }
}

/// The valance's curved bottom edge, for the trim.
private struct ValanceTrim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.7))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.7), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 1.3))
        return path
    }
}
