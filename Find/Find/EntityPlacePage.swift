import SwiftUI

/// The restaurant page and the retail store page
/// (design_handoff_find_game_restaurant_retail, parts B and C; web:
/// find-place-page), iPhone layout. Built on what the business card already
/// knows (the place, its hours and whether it's open, via EntityPlaceHours);
/// this adds the photo strip and viewer, popular dishes or quick facts, "Ask
/// this store" and "Shop online", "What people say", the week's hours and,
/// for a restaurant, videos people made about it. Every section hides when
/// there's nothing real to show. Local services keep the business card.
struct EntityPlacePage: View {
    let entity: FindEntity
    /// Sends the phone's position with each section once it's known (SearchViewModel).
    let fetch: @Sendable (String) async -> Data?
    let askStore: StoreAsk?
    @StateObject private var sections = EntitySections()

    @State private var failedPhotos: Set<String> = []
    @State private var viewerStart: ViewerStart?

    private static let storeAccent = Color(hex: 0xa34a60)

    private var isRestaurant: Bool { entity.type == "restaurant" }
    private var place: FindPlaceSection? { sections.value("place", as: FindPlaceSection.self) }
    private var summary: FindEntitySummary? { sections.value("summary", as: FindEntitySummary.self).flatMap { $0.text.isEmpty ? nil : $0 } }
    private var reviews: FindReviewsSection? {
        sections.value("reviews", as: FindReviewsSection.self).flatMap { $0.rating != nil || !($0.quotes ?? []).isEmpty ? $0 : nil }
    }
    private var dishes: FindDishesSection? { sections.value("dishes", as: FindDishesSection.self).flatMap { $0.dishes.count >= 2 ? $0 : nil } }
    private var retail: FindRetailSection? { sections.value("retail", as: FindRetailSection.self) }
    private var products: FindProductsSection? { sections.value("products", as: FindProductsSection.self).flatMap { $0.products.isEmpty ? nil : $0 } }
    private var videos: FindTeamVideos? { sections.value("videos", as: FindTeamVideos.self).flatMap { $0.videos.isEmpty ? nil : $0 } }
    private var nearest: FindPlaceLocation? { place?.nearest }
    /// A shop from the 16Ahead Store guides (id "listing:<domain>").
    private var isGuideShop: Bool { entity.id.hasPrefix("listing:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            titleBlock
            photosBlock
            visitCard

            EntitySummaryBlock(summary: summary, isLoading: sections.isLoading("summary"), extra: fitNote)

            if isRestaurant {
                dishesBlock
                servesBlock
            } else {
                quickFacts
                if let shop = retail?.shop, let askStore {
                    PlaceAskStore(shop: shop, accent: Self.storeAccent, ask: askStore)
                }
                listingBox
                shopOnline
            }

            if let reviews {
                EntityReviewsBlock(reviews: reviews)
            } else if sections.isLoading("reviews") {
                EntitySkeleton(height: 220, radius: 28)
            }

            hoursBlock

            if isRestaurant, let videos {
                EntityTeamVideosRow(row: videos)
            }

            EntityPillActions(actions: actions, showIcons: true)
        }
        .task {
            await sections.load(isRestaurant
                ? ["place", "summary", "reviews", "dishes", "videos"]
                : ["place", "summary", "reviews", "retail", "products"], fetch: fetch)
        }
        .fullScreenCover(item: $viewerStart) { start in
            PlacePhotoViewer(name: entity.name, photos: photos, index: start.index, wantsMore: (place?.photoCount ?? 0) > photos.count, fetch: fetch)
        }
    }

    // MARK: Title block

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(initials)
                .font(Theme.font(24, weight: .heavy))
                .foregroundStyle(isRestaurant ? Theme.tVioletFg : .white)
                .frame(width: 64, height: 64)
                .background(isRestaurant ? Theme.tViolet : Self.storeAccent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                // "Closes in 12 min" counts down without a refresh.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    EntityFlow(spacing: 8) {
                        EntityChip(text: (place?.category ?? "").ifEmpty(entity.label ?? (isRestaurant ? "Restaurant" : "Store")), tone: isRestaurant ? "yellow" : "pink")
                        if let chip = openChip(at: context.date) { EntityChip(text: chip.text, tone: chip.tone) }
                        if isRestaurant, let price = place?.priceLevel, !price.isEmpty { EntityChip(text: price, tone: "plain") }
                        if retail?.shop != nil {
                            EntityChip(text: "On 16Ahead Store", tone: "violet")
                        } else if isGuideShop {
                            EntityChip(text: "In our Store guides", tone: "violet")
                        }
                    }
                }
                Text(entity.name)
                    .font(Theme.font(32, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = metaText {
                    meta.font(Theme.font(15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else if sections.isLoading("place") {
                    EntitySkeleton(height: 16, radius: 8).frame(width: 180)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var initials: String {
        let cleaned = entity.name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) }
        let words = String(String.UnicodeScalarView(cleaned)).split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return "?" }
        if isRestaurant || words.count < 2 { return String(first).uppercased() }
        return (String(first) + String(words[1].first ?? Character(" "))).uppercased()
    }

    /// Green open, amber closing soon, red closed.
    private func openChip(at now: Date) -> (text: String, tone: String)? {
        guard let location = nearest, let status = EntityPlaceHours.status(location, at: now) else { return nil }
        let tone = status.tone == "green" ? "green" : status.tone == "yellow" ? "amber" : "red"
        if location.open24Hours != true {
            if status.tone == "green", location.nextCloseTime != nil { return ("Open · closes \(EntityPlaceHours.time(location.nextCloseTime, location))", tone) }
            if status.tone == "plain", location.nextOpenTime != nil { return ("Closed · opens \(EntityPlaceHours.time(location.nextOpenTime, location))", tone) }
        }
        return (status.short, tone)
    }

    /// "★ 4.7  867 reviews  9413 16th Ave SW, Seattle" (restaurant), "★ 4.9  64 reviews  $$$  Los Angeles, CA" (store)
    /// or "San Francisco, CA · Shops online" (a guide shop with no storefront).
    private var metaText: Text? {
        guard let place else { return nil }
        var items: [String] = []
        if let rating = place.rating { items.append("\(rating.count.formatted()) reviews") }
        if let location = place.nearest {
            if isRestaurant {
                items.append([location.street, location.city ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            } else {
                items.append(place.priceLevel ?? "")
                items.append(cityState(location))
            }
        } else {
            items.append(place.priceLevel ?? "")
            items.append([place.city ?? "", place.online == true ? "Shops online" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        items = items.filter { !$0.isEmpty }
        let rest = Text(items.joined(separator: "  "))
        guard let rating = place.rating else { return items.isEmpty ? nil : rest }
        return Text("★ \(String(format: "%.1f", rating.value))").font(Theme.font(15, weight: .bold)).foregroundColor(Theme.text) + Text(items.isEmpty ? "" : "  ") + rest
    }

    /// "Los Angeles, CA" from "123 Main St, Los Angeles, CA 90012, USA".
    private func cityState(_ location: FindPlaceLocation) -> String {
        let parts = location.address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let state = parts.count >= 2 ? String(parts[parts.count - 2].split(separator: " ").first ?? "") : ""
        let text = [location.city ?? "", state].filter { !$0.isEmpty }.joined(separator: ", ")
        return text.isEmpty ? (location.shortAddress ?? "") : text
    }

    // MARK: Photos

    private var photos: [FindPlacePhoto] { (place?.photos ?? []).filter { !failedPhotos.contains($0.url) } }

    @ViewBuilder
    private var photosBlock: some View {
        if sections.isLoading("place") {
            EntitySkeleton(height: 220, radius: 26)
        } else if let hero = photos.first {
            VStack(spacing: 10) {
                Button { viewerStart = ViewerStart(index: 0) } label: {
                    photo(hero)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if let count = place?.photoCount, count > 1 {
                                Text("See all \(count) photos")
                                    .font(Theme.font(14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background(Color(hex: 0x0f1115).opacity(0.72), in: Capsule())
                                    .padding(14)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photos of \(entity.name)")

                let strip = Array(photos.dropFirst().prefix(4))
                if !strip.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(strip.enumerated()), id: \.element.url) { index, item in
                            Button { viewerStart = ViewerStart(index: index + 1) } label: {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay { photo(item) }
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo \(index + 2) of \(entity.name)")
                        }
                        ForEach(strip.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                    }
                }
            }
        }
    }

    private func photo(_ item: FindPlacePhoto) -> some View {
        AsyncImage(url: URL(string: item.url)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: Theme.surface.onAppear { failedPhotos.insert(item.url) }
            default: Theme.surface
            }
        }
        .background(Theme.surface)
    }

    // MARK: Nearest location (restaurant, yellow) / Visit (store, green)

    @ViewBuilder
    private var visitCard: some View {
        if let location = nearest {
            let fg = isRestaurant ? Theme.tYellowFg : Theme.tGreenFg
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text(visitLabel(location, at: context.date)).font(Theme.font(14, weight: .bold)).foregroundStyle(fg)
                    Text(isRestaurant ? location.street : cityState(location))
                        .font(Theme.font(26, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    let line = visitLine(location)
                    if !line.isEmpty {
                        Text(line).font(Theme.font(15)).foregroundStyle(fg).fixedSize(horizontal: false, vertical: true)
                    }
                    let tiles = visitTiles(location)
                    if !tiles.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(tiles, id: \.0) { tile in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tile.0).font(Theme.font(12)).foregroundStyle(Theme.muted)
                                    Text(tile.1).font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    }
                    if let others = place?.others, !others.isEmpty {
                        Text("Also nearby: " + others.prefix(2).map { "\($0.street), \($0.city ?? "") (\($0.milesText ?? $0.city ?? ""))" }.joined(separator: " · "))
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isRestaurant ? Theme.tYellow : Theme.tGreen, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
        } else if sections.isLoading("place") {
            EntitySkeleton(height: 200, radius: 26)
        }
    }

    private func visitLabel(_ location: FindPlaceLocation, at now: Date) -> String {
        let where_ = isRestaurant ? (place?.usedPosition == true ? "Nearest location" : "Location") : "Visit"
        return [where_, EntityPlaceHours.status(location, at: now)?.short].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Seattle · 0.1 mi away · open until 2 PM, then 4–8 PM".
    private func visitLine(_ location: FindPlaceLocation) -> String {
        var parts: [String] = []
        if isRestaurant, let city = location.city, !city.isEmpty { parts.append(city) }
        if isRestaurant, let miles = location.milesText { parts.append("\(miles) away") }
        if let until = untilText(location) { parts.append(until) }
        if !isRestaurant && retail?.shipsNationwide == true { parts.append("also ships across the US") }
        return parts.joined(separator: " · ")
    }

    private func untilText(_ location: FindPlaceLocation) -> String? {
        guard location.openNow == true, location.nextCloseTime != nil else { return nil }
        let close = EntityPlaceHours.time(location.nextCloseTime, location)
        guard !close.isEmpty else { return nil }
        let shifts = EntityPlaceHours.shifts(rawTodayHours(location))
        let later = shifts.firstIndex { shift in
            shift.hasSuffix(close.replacingOccurrences(of: " ", with: "")) || shift.components(separatedBy: "–").dropFirst().first?.trimmingCharacters(in: .whitespaces) == close
        }
        let next = later.flatMap { shifts.indices.contains($0 + 1) ? shifts[$0 + 1] : nil }
        return "\(isRestaurant ? "open" : "Open") until \(close)\(next.map { ", then \($0)" } ?? "")"
    }

    private func rawTodayHours(_ location: FindPlaceLocation) -> String {
        guard let week = place?.hoursWeek, week.count == 7 else { return "" }
        return week[EntityPlaceHours.todayIndex(location)].hours
    }

    private func visitTiles(_ location: FindPlaceLocation) -> [(String, String)] {
        let today = EntityPlaceHours.compactHours(rawTodayHours(location)).components(separatedBy: " · ").first ?? ""
        let price = [place?.priceLevel ?? "", place?.priceRange ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let returns = retail?.returns ?? ""
        return [
            today.isEmpty ? nil : ("Today", today),
            location.milesText.map { ("Distance", $0) },
            isRestaurant ? (price.isEmpty ? nil : ("Price", price)) : (returns.isEmpty ? nil : ("Returns", returns)),
        ].compactMap { $0 }
    }

    // MARK: Restaurant: popular dishes and what it serves

    @ViewBuilder
    private var dishesBlock: some View {
        if let dishes {
            VStack(alignment: .leading, spacing: 0) {
                EntitySectionLabel(text: "Popular dishes").padding(.bottom, 6)
                ForEach(Array(dishes.dishes.enumerated()), id: \.offset) { index, dish in
                    HStack(spacing: 14) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.tAmberFg)
                            .frame(width: 64, height: 64)
                            .background(Theme.tAmber, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dish.name).font(Theme.font(16, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            if let note = dish.note, !note.isEmpty {
                                Text(note).font(Theme.font(13)).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        if let price = dish.price, !price.isEmpty {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(price).font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text)
                                Text("Menu").font(Theme.font(12)).foregroundStyle(Theme.muted)
                            }
                            .fixedSize()
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.surface).frame(height: 1) }
                    }
                }
                Text("Picked from reviews and the menu. Prices may have changed.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        } else if sections.isLoading("dishes") {
            EntitySkeleton(height: 180)
        }
    }

    @ViewBuilder
    private var servesBlock: some View {
        if let serves = place?.serves, !serves.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                EntitySectionLabel(text: "Serves")
                EntityFlow(spacing: 8) {
                    ForEach(serves, id: \.self) { EntityChip(text: $0, tone: "plain") }
                }
            }
        }
    }

    // MARK: Store: quick facts, Shop online

    private var fitNote: String? {
        guard let note = retail?.fitNote, !note.isEmpty else { return nil }
        return note.hasSuffix(".") ? note : "\(note)."
    }

    @ViewBuilder
    private var quickFacts: some View {
        let facts: [(String, String)] = [
            ("Known for", retail?.knownFor ?? ""),
            ("Made in", retail?.madeIn ?? ""),
            ("Prices", retail?.prices ?? ""),
        ].filter { !$0.1.isEmpty }
        if !facts.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.0).font(Theme.font(12)).foregroundStyle(Theme.muted)
                        Text(fact.1).font(Theme.font(16, weight: .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if sections.isLoading("retail") {
            EntitySkeleton(height: 72, radius: 16)
        }
    }

    /// A guide shop that hasn't joined 16Ahead Store: ask for it, or claim it.
    @ViewBuilder
    private var listingBox: some View {
        if let listing = retail?.listing {
            let want = FindWebURL.resolve(listing.wantUrl)
            let claim = FindWebURL.resolve(listing.claimUrl)
            if want != nil || claim != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not on 16Ahead Store yet").font(Theme.font(16, weight: .bold)).foregroundStyle(Theme.text)
                    if let want {
                        Link(destination: want) {
                            Text("Want to buy from them on 16Ahead Store?")
                                .font(Theme.font(15, weight: .bold))
                                .foregroundStyle(Theme.indigo)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    if let claim {
                        Link(destination: claim) {
                            Text("Is this your shop? Claim it").font(Theme.font(13)).foregroundStyle(Theme.muted).underline()
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))
            }
        }
    }

    @ViewBuilder
    private var shopOnline: some View {
        if let products {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shop online").font(Theme.font(24, weight: .bold)).foregroundStyle(Theme.text)
                        if let title = products.title, !title.isEmpty {
                            Text(title).font(Theme.font(15)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    if let total = products.total, total > products.products.count, let url = FindWebURL.resolve(products.seeAllUrl) {
                        Link(destination: url) {
                            Text("See all \(total) ›").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.indigo)
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(products.products.enumerated()), id: \.offset) { _, product in
                            productCard(product)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        } else if sections.isLoading("products") {
            EntitySkeleton(height: 260, radius: 20)
        }
    }

    @ViewBuilder
    private func productCard(_ product: FindProductsSection.Product) -> some View {
        let card = VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    if let image = product.imageUrl, let url = URL(string: image) {
                        Color.white
                        AsyncImage(url: url) { phase in
                            if case .success(let picture) = phase {
                                picture.resizable().scaledToFit()
                            } else {
                                Theme.surface
                            }
                        }
                    } else {
                        Theme.surface
                        Image(systemName: "tshirt").font(.system(size: 28)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(width: 160, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if let chip = stockChip(product.stock) {
                    EntityChip(text: chip.text, tone: chip.tone).scaleEffect(0.92, anchor: .topLeading).padding(10)
                }
            }
            .padding(.bottom, 6)
            Text(product.title).font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2)
            if let price = product.price, !price.isEmpty {
                Text(price).font(Theme.font(14)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 160, alignment: .leading)

        if let url = URL(string: product.url) {
            Link(destination: url) { card.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private func stockChip(_ stock: String?) -> (text: String, tone: String)? {
        switch stock {
        case "in": return ("In stock", "green")
        case "low": return ("Low stock", "amber")
        case "new": return ("New", "violet")
        default: return nil
        }
    }

    // MARK: Hours

    @ViewBuilder
    private var hoursBlock: some View {
        if let week = place?.hoursWeek, !week.isEmpty, let location = nearest {
            let today = EntityPlaceHours.todayIndex(location)
            VStack(alignment: .leading, spacing: 0) {
                EntitySectionLabel(text: "Hours").padding(.bottom, 8)
                ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                    let isToday = week.count == 7 && index == today
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(day.day.prefix(3)))
                        Spacer(minLength: 8)
                        Text(EntityPlaceHours.compactHours(day.hours)).multilineTextAlignment(.trailing)
                    }
                    .font(Theme.font(15, weight: isToday ? .bold : .regular))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        if isToday { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.bg) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    // MARK: Actions

    private var actions: [EntityAction] {
        let website = (place?.website ?? "").ifEmpty(entity.website ?? "")
        let directions = EntityAction("Directions", systemImage: "location.fill", url: nearest?.directionsUrl)
        let call = nearest?.phone.flatMap { phone in EntityAction("Call", systemImage: "phone.fill", url: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") }
        if isRestaurant {
            return [
                EntityAction("Menu & ordering", systemImage: "fork.knife", url: (dishes?.menuUrl ?? "").ifEmpty(website)),
                directions,
                call,
                EntityAction("Google Maps", systemImage: "map", url: nearest?.mapsUrl),
            ].compactMap { $0 }
        }
        return [
            EntityAction("Shop online", systemImage: "bag.fill", url: (retail?.shop?.url ?? "").ifEmpty(website)),
            directions,
            call,
            EntityAction("Instagram", systemImage: "camera", url: retail?.instagram),
        ].compactMap { $0 }
    }
}

private struct ViewerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: Ask this store

/// The store's own 16Ahead Store search: the best match, or where it sends
/// you for something it doesn't carry.
private struct PlaceAskStore: View {
    let shop: FindRetailSection.Shop
    let accent: Color
    let ask: @Sendable (String, String) async -> FindAskResult?

    @State private var query = ""
    @State private var asking = false
    @State private var result: FindAskResult?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                EntitySectionLabel(text: "Ask this store").padding(.bottom, 10)
                HStack(spacing: 8) {
                    TextField("What are you looking for at \(shop.name)?", text: $query)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.text)
                        .submitLabel(.search)
                        .onSubmit(run)
                        .accessibilityLabel("Search \(shop.name)")
                    Button(action: run) {
                        Text(asking ? "Finding…" : "Find")
                            .font(Theme.font(15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(asking || query.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(asking || query.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
                }
                .padding(.leading, 18)
                .padding([.vertical, .trailing], 6)
                .background(Theme.surface, in: Capsule())

                if let result, let best = result.best {
                    let row = HStack(spacing: 12) {
                        ZStack {
                            Theme.surface
                            if let image = best.imageUrl, let url = URL(string: image) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let picture) = phase { picture.resizable().scaledToFill() }
                                }
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(result.count) match\(result.count == 1 ? "" : "es") at \(shop.name)").font(Theme.font(15, weight: .bold)).foregroundStyle(Theme.text)
                            Text("Best match: \(best.title)\((best.price ?? "").isEmpty ? "" : ", \(best.price ?? "")")")
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 14)
                    if let url = URL(string: (result.searchUrl ?? "").ifEmpty(best.url ?? "")) {
                        Link(destination: url) { row.contentShape(Rectangle()) }.buttonStyle(.plain)
                    } else {
                        row
                    }
                } else if let result, result.referral == nil {
                    note("\(shop.name) doesn’t have that right now.")
                }
                if failed { note("The store couldn’t search right now.") }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))

            if let referral = result?.referral, let url = URL(string: referral.url) {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 8) {
                        ReferralTrace(from: shop.name, to: referral.store)
                        Text("Don’t see it here? \(shop.name) sends you to \(referral.store)\((referral.location ?? "").isEmpty ? "" : " in \(referral.location ?? "")"), which carries it.")
                            .font(Theme.font(14))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.tCyanFg)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.tCyan, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.font(14)).foregroundStyle(Theme.muted).padding(.top, 12)
    }

    private func run() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        failed = false
        result = nil
        Task {
            let found = await ask(shop.slug, text)
            asking = false
            result = found
            failed = found == nil
        }
    }
}

/// "Calle Del Mar ——●—— Linden Knits": a dot travels from the store to its partner.
private struct ReferralTrace: View {
    let from: String
    let to: String
    @State private var travelled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(from).font(Theme.font(14, weight: .bold)).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().frame(height: 2).opacity(0.5)
                    Circle()
                        .fill(Color(hex: 0x2563eb))
                        .frame(width: 10, height: 10)
                        .offset(x: reduceMotion ? (proxy.size.width - 10) / 2 : travelled ? proxy.size.width - 10 : 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            Text(to).font(Theme.font(14, weight: .bold)).lineLimit(1)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) { travelled = true }
        }
    }
}

// MARK: Photo viewer

/// All of Google's photos (up to ten, loaded when it opens), paged, each
/// credited to whoever took it.
private struct PlacePhotoViewer: View {
    let name: String
    @State var photos: [FindPlacePhoto]
    @State var index: Int
    let wantsMore: Bool
    let fetch: @Sendable (String) async -> Data?

    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(hex: 0x080a0e).ignoresSafeArea()

            VStack(spacing: 12) {
                TabView(selection: $index) {
                    ForEach(Array(photos.enumerated()), id: \.element.url) { offset, photo in
                        AsyncImage(url: URL(string: photo.url)) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit()
                            case .failure: Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.5))
                            default: ProgressView().tint(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 12)
                        .tag(offset)
                        .accessibilityLabel("Photo \(offset + 1) of \(name)")
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                credit
                    .font(Theme.font(13))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .padding(.top, 60)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: 0x0f1115))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.92), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close photos")
        }
        .task {
            guard wantsMore else { return }
            loading = true
            if let data = await fetch("photos"), let more = try? JSONDecoder().decode(FindPlacePhotos.self, from: data), !more.photos.isEmpty {
                let shown = photos.indices.contains(index) ? photos[index].url : nil
                photos = more.photos
                index = shown.flatMap { url in more.photos.firstIndex { $0.url == url } } ?? min(index, more.photos.count - 1)
            }
            loading = false
        }
    }

    private static func linked(_ text: String, _ url: URL) -> AttributedString {
        var value = AttributedString(text)
        value.link = url
        return value
    }

    private var credit: some View {
        let shown = photos.indices.contains(index) ? photos[index] : nil
        let author = shown?.author ?? ""
        let tail = "\(index + 1) of \(photos.count)\(loading ? " · loading more…" : "")"
        return Group {
            if !author.isEmpty, let link = shown?.authorUrl, let url = URL(string: link) {
                (Text("Photo by ") + Text(Self.linked(author, url)).underline() + Text(" · Google Maps · \(tail)"))
                    .tint(.white)
            } else if !author.isEmpty {
                Text("Photo by \(author) · Google Maps · \(tail)")
            } else {
                Text(tail)
            }
        }
    }
}

// MARK: What people say

/// Google's rating and review count; the themes 16Ahead found in three or
/// more reviews (counts are mentions); two quotes, word for word. Google
/// gives no per-star counts, so there's no histogram (web: find-reviews-block).
struct EntityReviewsBlock: View {
    let reviews: FindReviewsSection

    private static let gold = Color(hex: 0xe3a008)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let rating = reviews.rating {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.1f", rating)).font(Theme.font(48, weight: .heavy)).tracking(-1.8).foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.stars(rating)).font(.system(size: 18)).tracking(2).foregroundStyle(Self.gold)
                            .accessibilityLabel("\(String(format: "%.1f", rating)) out of 5 stars")
                        let count = "\((reviews.count ?? 0).formatted()) reviews on Google"
                        if let url = FindWebURL.resolve(reviews.mapsUrl) {
                            Link(destination: url) { Text(count).font(Theme.font(14)).foregroundStyle(Theme.muted) }
                        } else {
                            Text(count).font(Theme.font(14)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                EntitySectionLabel(text: "What people say")
                if let themes = reviews.themes, !themes.isEmpty {
                    EntityFlow(spacing: 8) {
                        let grouped = reviews.grouped ?? 0
                        Text("16Ahead grouped \(grouped) review\(grouped == 1 ? "" : "s")")
                            .font(Theme.font(13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Theme.bg, in: Capsule())
                        ForEach(themes, id: \.self) { theme in
                            EntityChip(text: "\(theme.text) · \(theme.count) mentions", tone: theme.tone)
                        }
                    }
                }
                ForEach(Array((reviews.quotes ?? []).prefix(2).enumerated()), id: \.offset) { _, quote in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("“\(quote.text)”").font(Theme.font(15)).lineSpacing(3).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        caption(quote).font(Theme.font(12))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What people say")
    }

    /// "★★★★★ · Oct 28 · Dana K."
    private func caption(_ quote: FindReviewsSection.Quote) -> Text {
        // Google's publishTime has nanoseconds; the formatter reads whole seconds.
        let when = quote.date?.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let rest = [FindEntityFormat.date(when).map { FindEntityFormat.format($0, "MMMd") }, quote.author]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let stars = quote.stars.map { Text(Self.stars($0)).foregroundColor(Self.gold) } ?? Text("")
        let tail = rest.joined(separator: " · ")
        let joiner = quote.stars != nil && !tail.isEmpty ? " · " : ""
        return stars + Text(joiner + tail).foregroundColor(Theme.muted)
    }

    private static func stars(_ rating: Double) -> String {
        let full = max(0, min(5, Int(rating.rounded())))
        return String(repeating: "★", count: full) + String(repeating: "☆", count: 5 - full)
    }
}
