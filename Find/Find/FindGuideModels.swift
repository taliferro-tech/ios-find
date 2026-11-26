import SwiftUI

// The Guides screens' data: the same guides as find.16ahead.com/guides
// (todd-backend findGuidePages.js, POST /find/guides and /find/guides/guide).

struct FindGuidesRequest: Encodable {}

struct FindGuideRequest: Encodable {
    let path: String
}

struct FindGuideResponse: Decodable {
    let guide: FindGuide?
}

struct FindGuideColors: Decodable, Hashable {
    let background: String
    let ink: String
    let end: String
}

/// A guide's card on the index and in More guides.
struct FindGuideSummary: Decodable, Identifiable, Hashable {
    let id: String
    let path: String
    let url: String
    let title: String
    let city: String
    let state: String
    let category: String
    let kind: String
    let emoji: String
    let colors: FindGuideColors
    let count: Int
    let countLabel: String
    let photos: [String]
}

struct FindGuidesIndex: Decodable {
    let lead: String
    let guides: [FindGuideSummary]
    let categories: [String]
    let states: [String]
    let addShopUrl: String
}

struct FindGuideChip: Decodable, Hashable {
    let label: String
    let url: String
}

struct FindGuideVideo: Decodable, Hashable {
    let url: String
    let imageUrl: String
    let title: String
}

struct FindGuideShop: Decodable, Identifiable, Hashable {
    let name: String
    let city: String
    let domain: String
    let url: String
    let imageUrl: String?
    let summary: String
    let chips: [FindGuideChip]
    /// Shops: "Want to buy from them on 16Ahead Store?" and "Is this your shop? Claim it".
    let wantUrl: String?
    let claimUrl: String?
    /// Places: "Is this your place? Remove it".
    let removeUrl: String?
    var id: String { domain }
}

struct FindGuide: Decodable, Identifiable, Hashable {
    let id: String
    let path: String
    let url: String
    let title: String
    let city: String
    let state: String
    let category: String
    let kind: String
    let emoji: String
    let colors: FindGuideColors
    let count: Int
    let countLabel: String
    let photos: [String]
    let titleLead: String
    let intro: String
    let reviewed: String
    let video: FindGuideVideo?
    let addShopUrl: String?
    let shops: [FindGuideShop]
    let related: [FindGuideSummary]
}

/// A category's tint: the web's light colours, or in dark mode its ink on a dark wash.
struct FindGuideTint {
    let background: Color
    let ink: Color

    init(_ colors: FindGuideColors, scheme: ColorScheme) {
        let ink = Color(hexString: colors.ink) ?? Theme.text
        if scheme == .dark {
            self.background = ink.opacity(0.28)
            self.ink = Theme.text
        } else {
            self.background = Color(hexString: colors.background) ?? Theme.surface
            self.ink = ink
        }
    }
}
