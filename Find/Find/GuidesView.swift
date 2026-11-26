import SwiftUI

/// The Guides tab: find.16ahead.com/guides as app screens. The index and
/// each guide are drawn here; tapping anything inside a guide (a shop, its
/// chips, the video, Add your shop) opens it in the browser.
struct GuidesView: View {
    let apiClient: FindAPIClient
    let screenWidth: CGFloat
    let onHome: () -> Void

    @State private var index: FindGuidesIndex?
    @State private var indexFailed = false
    @State private var category: String?
    @State private var state: String?
    /// The open guide (nil = the index). More guides replaces it.
    @State private var openPath: String?

    var body: some View {
        Group {
            if let openPath {
                GuideDetailView(apiClient: apiClient, path: openPath, screenWidth: screenWidth, onBack: { self.openPath = nil }, onOpen: { self.openPath = $0 })
                    .id(openPath)
            } else {
                indexScreen
            }
        }
        .task { if index == nil { await loadIndex() } }
    }

    private func loadIndex() async {
        indexFailed = false
        do {
            index = try await apiClient.guides()
        } catch {
            indexFailed = true
        }
    }

    // MARK: - Index

    private var indexScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuidesHeader(title: "Guides", leading: .home, action: onHome)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if let index {
                        hero(index)
                        if !shown(index).isEmpty {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(shown(index)) { guide in
                                    Button { openPath = guide.path } label: { GuideCard(guide: guide) }
                                        .buttonStyle(.plain)
                                }
                            }
                        } else if !index.guides.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No guides match both filters yet.")
                                    .font(Theme.font(15))
                                    .foregroundStyle(Theme.muted)
                                Button("Show all guides") { category = nil; state = nil }
                                    .font(Theme.font(15, weight: .semibold))
                                    .foregroundStyle(Theme.blueInk)
                            }
                        }
                        OwnerBand(addShopURL: URL(string: index.addShopUrl))
                    } else if indexFailed {
                        GuidesRetry(message: "Guides are unavailable right now.") { Task { await loadIndex() } }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .refreshable { await loadIndex() }
        }
    }

    private var columns: [GridItem] {
        let count = screenWidth >= 700 ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    private func shown(_ index: FindGuidesIndex) -> [FindGuideSummary] {
        index.guides.filter { (category == nil || $0.category == category) && (state == nil || $0.state == state) }
    }

    private func hero(_ index: FindGuidesIndex) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shop independent.")
                .font(Theme.font(30, weight: .black))
                .foregroundStyle(Theme.text)
            Text(index.lead)
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if index.categories.count > 1 || index.states.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        GuideFilterChip(label: "All", on: category == nil && state == nil) { category = nil; state = nil }
                        if index.categories.count > 1 {
                            ForEach(index.categories, id: \.self) { item in
                                GuideFilterChip(label: item, on: category == item) { category = category == item ? nil : item }
                            }
                        }
                        if index.categories.count > 1 && index.states.count > 1 {
                            Rectangle().fill(Theme.surface2).frame(width: 1, height: 22)
                        }
                        if index.states.count > 1 {
                            ForEach(index.states, id: \.self) { item in
                                GuideFilterChip(label: item, on: state == item) { state = state == item ? nil : item }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - One guide

private struct GuideDetailView: View {
    let apiClient: FindAPIClient
    let path: String
    let screenWidth: CGFloat
    let onBack: () -> Void
    let onOpen: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @State private var guide: FindGuide?
    @State private var failed = false
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                GuidesHeader(title: guide?.city ?? "Guide", leading: .back, action: onBack)
                Spacer()
                if let guide, let url = URL(string: guide.url) {
                    ShareLink(item: url, subject: Text(guide.title)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                    }
                    .accessibilityLabel("Share guide")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                if let guide {
                    content(guide)
                } else if missing {
                    GuidesRetry(message: "That guide isn't here. It may have moved or been taken down.", buttonLabel: "See every guide", action: onBack)
                        .padding(.horizontal, 18)
                } else if failed {
                    GuidesRetry(message: "That guide is unavailable right now.") { Task { await load() } }
                        .padding(.horizontal, 18)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            guide = try await apiClient.guide(path: path)
            missing = guide == nil
        } catch {
            failed = true
        }
    }

    private func open(_ link: String?) {
        if let link, let url = URL(string: link) { openURL(url) }
    }

    private func content(_ guide: FindGuide) -> some View {
        let tint = FindGuideTint(guide.colors, scheme: scheme)
        return VStack(alignment: .leading, spacing: 18) {
            if guide.photos.count >= 2 {
                HStack(spacing: 4) {
                    ForEach(guide.photos, id: \.self) { photo in
                        GuidePhoto(url: photo)
                            .frame(height: 110)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Guides › \(guide.state) › \(guide.city)")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                Text("\(guide.emoji) \(guide.titleLead)")
                    .font(Theme.font(14, weight: .semibold))
                    .foregroundStyle(tint.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(tint.background, in: Capsule())
                Text(guide.city)
                    .font(Theme.font(32, weight: .black))
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel("\(guide.titleLead) \(guide.city), \(guide.state)")
                Text("\(guide.state) · \(guide.countLabel) · checked by people")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                Text(guide.intro)
                    .font(Theme.font(16))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let video = guide.video {
                Button { open(video.url) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        GuidePhoto(url: video.imageUrl)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 44)
                                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            }
                        Text(video.title.isEmpty ? "Watch on YouTube" : "Video: \(video.title) · Watch on YouTube")
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(video.title.isEmpty ? "Play video" : "Play video: \(video.title)")
            }

            VStack(spacing: 14) {
                ForEach(guide.shops) { shop in
                    GuideShopCard(shop: shop, open: open)
                }
            }

            if let add = guide.addShopUrl {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Own a shop in \(guide.city)?").font(Theme.font(16, weight: .bold)) + Text(" Add it to this guide for free.").font(Theme.font(16))
                    Button { open(add) } label: { GuidePillLabel(text: "Add your shop", primary: true) }
                        .buttonStyle(.plain)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            }

            if !guide.related.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("More guides").font(Theme.font(18, weight: .bold))
                    EntityFlow(spacing: 8) {
                        ForEach(guide.related) { other in
                            Button { onOpen(other.path) } label: { GuidePillLabel(text: "\(other.city) · \(other.category)", primary: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }

            Text("Reviewed \(guide.reviewed).")
                .font(Theme.font(13))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
    }
}

private struct GuideShopCard: View {
    let shop: FindGuideShop
    let open: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = shop.imageUrl {
                Button { open(shop.url) } label: {
                    GuidePhoto(url: image)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shop.name).font(Theme.font(19, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(shop.city).font(Theme.font(13)).foregroundStyle(Theme.muted)
                }
                if !shop.summary.isEmpty {
                    Text(shop.summary)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !shop.chips.isEmpty {
                    EntityFlow(spacing: 8) {
                        ForEach(shop.chips, id: \.self) { chip in
                            Button { open(chip.url.isEmpty ? nil : chip.url) } label: { GuidePillLabel(text: chip.label, primary: false, small: true) }
                                .buttonStyle(.plain)
                                .disabled(chip.url.isEmpty)
                        }
                    }
                }
                Button { open(shop.url) } label: { GuidePillLabel(text: "Visit \(shop.domain) ↗", primary: true) }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if let want = shop.wantUrl { ownerLink("Want to buy from them on 16Ahead Store?", want) }
                    if let claim = shop.claimUrl { ownerLink("Is this your shop? Claim it", claim) }
                    if let remove = shop.removeUrl { ownerLink("Is this your place? Remove it", remove) }
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func ownerLink(_ text: String, _ url: String) -> some View {
        Button { open(url) } label: {
            Text(text).font(Theme.font(13)).underline().foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pieces

private struct GuideCard: View {
    let guide: FindGuideSummary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = FindGuideTint(guide.colors, scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            cover(tint)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text("\(guide.emoji) \(guide.category)")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(tint.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tint.background, in: Capsule())
                    .lineLimit(1)
                Text(guide.city)
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text("\(guide.state) · \(guide.countLabel)")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                Text("Open guide →")
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(guide.title)
    }

    @ViewBuilder
    private func cover(_ tint: FindGuideTint) -> some View {
        let photos = guide.photos
        if photos.isEmpty {
            ZStack {
                tint.background
                Text(guide.emoji).font(.system(size: 44))
            }
        } else if photos.count < 4 {
            GuidePhoto(url: photos[0])
        } else {
            VStack(spacing: 2) {
                HStack(spacing: 2) { GuidePhoto(url: photos[0]); GuidePhoto(url: photos[1]) }
                HStack(spacing: 2) { GuidePhoto(url: photos[2]); GuidePhoto(url: photos[3]) }
            }
        }
    }
}

/// A photo that fills its frame, with a plain tile while it loads or if it fails.
private struct GuidePhoto: View {
    let url: String

    var body: some View {
        Color.clear
            .overlay {
                AsyncImage(url: URL(string: url)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Theme.surface2
                    }
                }
            }
            .clipped()
    }
}

private struct GuidePillLabel: View {
    let text: String
    let primary: Bool
    var small = false

    var body: some View {
        Text(text)
            .font(Theme.font(small ? 13 : 15, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, small ? 12 : 18)
            .frame(height: small ? 32 : 44)
            .background(primary ? Theme.blue : Theme.bg, in: Capsule())
            .overlay(Capsule().stroke(primary ? Color.clear : Theme.surface2, lineWidth: 1))
    }
}

private struct GuideFilterChip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(14, weight: .semibold))
                .foregroundStyle(on ? Theme.bg : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(on ? Theme.text : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct GuidesHeader: View {
    enum Leading { case home, back }
    let title: String
    let leading: Leading
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: leading == .home ? "house.fill" : "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 36, height: 36)
                    .background(Theme.cardBackground)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(leading == .home ? "Home" : "All guides")
            Text(title)
                .font(Theme.font(22, weight: .bold))
                .lineLimit(1)
        }
    }
}

private struct OwnerBand: View {
    let addShopURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run an independent shop?").font(Theme.font(20, weight: .bold))
            Text("Get listed in Find for free. Shoppers see your products and go straight to your website.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { if let addShopURL { openURL(addShopURL) } } label: { GuidePillLabel(text: "Add your shop", primary: true) }
                .buttonStyle(.plain)
            Button { if let url = URL(string: "https://16ahead.store/sign-in") { openURL(url) } } label: {
                Text("Already listed? Claim your page").font(Theme.font(14)).underline().foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct GuidesRetry: View {
    let message: String
    var buttonLabel = "Try again"
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button(buttonLabel, action: action)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.blueInk)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
