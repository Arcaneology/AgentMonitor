import Foundation

/// The stable model families used by the token chart.
///
/// A family is presentation metadata only.  The database keeps the raw model
/// string that it read from a provider; callers can use ``TokenModelCatalog``
/// when they need a stable identity for grouping or display.
enum TokenModelFamily: String, CaseIterable, Codable, Sendable {
    case gpt
    case claude
    case gemini
    case grok
    case kimi
    case deepSeek
    case unknown

    var title: String {
        switch self {
        case .gpt: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .deepSeek: "DeepSeek"
        case .unknown: "未知"
        }
    }
}

enum TokenUsageFilter: Equatable, Sendable {
    case family(TokenModelFamily)
    case model(String)

    static func toggling(_ family: TokenModelFamily, current: Self?) -> Self? {
        current == .family(family) ? nil : .family(family)
    }

    static func toggling(modelID: String, current: Self?) -> Self? {
        let selection = Self.model(TokenModelCatalog.canonicalID(modelID))
        return current == selection ? nil : selection
    }
}

/// Presentation metadata for one canonical model identity.
///
/// `rank` is intentionally a catalog value rather than a value calculated from
/// the current snapshot. This keeps a model's visual strength stable when the
/// selected time range changes. Values are configurable in the catalog below;
/// `normalizedRank` is derived from the strongest rank in this model's family.
struct TokenModelMetadata: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let family: TokenModelFamily
    let rank: Int

    var normalizedRank: Double {
        TokenModelCatalog.normalizedRank(for: id)
    }

    var identity: String { id }
}

/// Canonical identities and the deliberately small alias table used by the
/// token chart.  This is kept free of SwiftUI so the reader and its tests can
/// use the same model identity rules without importing a UI framework.
enum TokenModelCatalog {
    private struct Definition: Sendable {
        let id: String
        let name: String
        let family: TokenModelFamily
        let rank: Int
    }

    // Keep these IDs stable.  Add a new provider spelling to `aliases` rather
    // than deriving one with a broad prefix/date heuristic: raw unknown models
    // must remain independently selectable in the chart.
    private static let definitions: [Definition] = [
        // GPT — Astra > Sol > Terra > Luna.
        Definition(id: "gpt-6-astra", name: "GPT Astra", family: .gpt, rank: 4),
        Definition(id: "gpt-5.6-sol", name: "GPT Sol", family: .gpt, rank: 3),
        Definition(id: "gpt-5.6-terra", name: "GPT Terra", family: .gpt, rank: 2),
        Definition(id: "gpt-5.6-luna", name: "GPT Luna", family: .gpt, rank: 1),

        // Claude — Opus 5 > Sonnet 5 > Sonnet 4.6.
        Definition(id: "claude-opus-5", name: "Claude Opus 5", family: .claude, rank: 4),
        Definition(id: "claude-sonnet-5", name: "Claude Sonnet 5", family: .claude, rank: 3),
        Definition(id: "claude-sonnet-4.6", name: "Claude Sonnet 4.6", family: .claude, rank: 2),

        // Gemini — 3.8 Flash > 3.7 Flash > 3.6 Flash.
        Definition(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", family: .gemini, rank: 3),
        Definition(id: "gemini-3.7-flash", name: "Gemini 3.7 Flash", family: .gemini, rank: 2),
        Definition(id: "gemini-3.6-flash", name: "Gemini 3.6 Flash", family: .gemini, rank: 1),

        // Grok's build variant is intentionally a separate identity at the
        // same depth.  It must not be silently merged with ordinary Grok.
        Definition(id: "grok-4.6", name: "Grok 4.6", family: .grok, rank: 2),
        Definition(id: "grok-4.6-build", name: "Grok 4.6 Build", family: .grok, rank: 2),

        Definition(id: "kimi-k3", name: "Kimi K3", family: .kimi, rank: 2),

        // DeepSeek's Vision variant is a distinct identity with the same
        // catalog depth as V4 Flash.
        Definition(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", family: .deepSeek, rank: 2),
        Definition(id: "deepseek-v4-vision", name: "DeepSeek V4 Vision", family: .deepSeek, rank: 2),

        // Explicitly known provider models that do not belong to the named
        // strongest-rank tiers.  They are kept as model identities and receive
        // the medium strength of their family rather than being gray unknowns.
        Definition(id: "gpt-5.4", name: "GPT 5.4", family: .gpt, rank: 0),
        Definition(id: "claude-sonnet", name: "Claude Sonnet", family: .claude, rank: 0),
        Definition(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", family: .gemini, rank: 0),
    ]

    /// Explicit aliases from provider clients and dated model IDs.  Keep this
    /// table finite and reviewable.  In particular, do not strip arbitrary
    /// provider prefixes or suffixes: doing that would collapse two raw model
    /// identities that happen to share a word.
    private static let aliases: [String: String] = [
        // GPT provider and dated IDs.
        "openai/gpt-6-astra": "gpt-6-astra",
        "openai/gpt-5.6-sol": "gpt-5.6-sol",
        "openai/gpt-5.6-terra": "gpt-5.6-terra",
        "openai/gpt-5.6-luna": "gpt-5.6-luna",
        "openai/gpt-5.4": "gpt-5.4",
        "openai/gpt-5.4-2026-03-05": "gpt-5.4",

        // Anthropic/Claude provider spellings.
        "anthropic/claude-opus-5": "claude-opus-5",
        "anthropic/claude-sonnet-5": "claude-sonnet-5",
        "anthropic/claude-sonnet-4.6": "claude-sonnet-4.6",
        "claude-sonnet-4-6": "claude-sonnet-4.6",
        "claude-sonnet": "claude-sonnet",

        // Gemini provider spellings and the explicit Flash quality suffix.
        "google-antigravity/gemini-3.8-flash": "gemini-3.8-flash",
        "google-antigravity/gemini-3.8-flash-high": "gemini-3.8-flash",
        "google-antigravity/gemini-3.7-flash": "gemini-3.7-flash",
        "google-antigravity/gemini-3.6-flash": "gemini-3.6-flash",
        "google/gemini-3.8-flash": "gemini-3.8-flash",
        "google/gemini-3.8-flash-high": "gemini-3.8-flash",
        "gemini-3.8-flash-high": "gemini-3.8-flash",
        "google/gemini-3.7": "gemini-3.7-flash",
        "google/gemini-3.7-flash": "gemini-3.7-flash",
        "gemini-3.7": "gemini-3.7-flash",
        "gemini-3.7-flash": "gemini-3.7-flash",
        "google/gemini-3.6": "gemini-3.6-flash",
        "google/gemini-3.6-flash": "gemini-3.6-flash",
        "gemini-3.6": "gemini-3.6-flash",
        "gemini-3.6-flash": "gemini-3.6-flash",
        "google/gemini-2.5-pro": "gemini-2.5-pro",
        "gemini-2.5-pro": "gemini-2.5-pro",

        // xAI/Grok build remains separate from regular Grok.
        "xai/grok-4.6": "grok-4.6",
        "xai/grok-4.6-build": "grok-4.6-build",

        // Kimi and DeepSeek provider spellings.
        "k3": "kimi-k3",
        "kimi-code/k3": "kimi-k3",
        "kimi/k3": "kimi-k3",
        "moonshot/kimi-k3": "kimi-k3",
        "deepseek/deepseek-v4-flash": "deepseek-v4-flash",
        "deepseek/deepseek-flash": "deepseek-v4-flash",
        "deepseek/deepseek-v4-vision": "deepseek-v4-vision",
        "deepseek/deepseek-vision": "deepseek-v4-vision",
        "deepseek-v4-flash-vision-exp": "deepseek-v4-vision",
        "deepseek/deepseek-v4-flash-vision-exp": "deepseek-v4-vision",
    ]

    private static let definitionsByID: [String: Definition] = {
        Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
    }()

    private static let aliasesByLowercasedID: [String: String] = {
        Dictionary(uniqueKeysWithValues: aliases.map { ($0.key.lowercased(), $0.value) })
    }()

    /// Canonical IDs known to the UI, sorted by family and then catalog rank.
    /// Unknown raw models are added by the current snapshot at runtime.
    static var knownModelIDs: [String] {
        definitions
            .sorted { lhs, rhs in
                if lhs.family != rhs.family {
                    return familySortIndex(lhs.family) < familySortIndex(rhs.family)
                }
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                return lhs.id < rhs.id
            }
            .map(\.id)
    }

    /// Backwards-compatible spelling for callers that describe the list as a
    /// catalog rather than a model selector.
    static var allModelIDs: [String] { knownModelIDs }

    /// Maps one explicitly registered provider/date spelling to its stable ID.
    /// Empty input is represented by the stable unknown identity.
    static func canonicalID(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "unknown" }
        let lowercased = value.lowercased()
        if let canonical = aliasesByLowercasedID[lowercased] {
            return canonical
        }
        if definitionsByID[value] != nil {
            return value
        }
        // Canonical IDs are case-insensitive at the provider boundary while
        // preserving the catalog's spelling.
        if let definition = definitions.first(where: { $0.id.lowercased() == lowercased }) {
            return definition.id
        }
        return value
    }

    static func metadata(for modelID: String) -> TokenModelMetadata {
        let canonicalID = canonicalID(modelID)
        if let definition = definitionsByID[canonicalID] {
            return TokenModelMetadata(
                id: definition.id,
                name: definition.name,
                family: definition.family,
                rank: definition.rank
            )
        }

        let family = familyHint(for: canonicalID) ?? .unknown
        let name = canonicalID == "unknown" ? "未知模型" : canonicalID
        return TokenModelMetadata(
            id: canonicalID,
            name: name,
            family: family,
            rank: mediumRank(for: family)
        )
    }

    static func displayName(for modelID: String) -> String {
        metadata(for: modelID).name
    }

    static func family(for modelID: String) -> TokenModelFamily {
        metadata(for: modelID).family
    }

    static func rank(for modelID: String) -> Int {
        metadata(for: modelID).rank
    }

    /// Returns a stable strength in 0...1 based on the strongest rank in the
    /// model's family, not on models present in a selected time range. Unknown
    /// IDs that carry a known provider family receive that family's medium
    /// rank; truly unknown IDs use zero.
    static func normalizedRank(for modelID: String) -> Double {
        let canonical = canonicalID(modelID)
        let modelMetadata = metadata(for: canonical)
        guard modelMetadata.family != .unknown else { return 0 }
        // Future provider models are intentionally not canonicalized into a
        // known identity. Keep their family tint at the stable midpoint even
        // if a stronger catalog rank is added later.
        if definitionsByID[canonical] == nil || modelMetadata.rank == 0 { return 0.5 }
        let familyRanks = definitions
            .filter { $0.family == modelMetadata.family }
            .map(\.rank)
        return normalizedRank(rank: modelMetadata.rank, familyRanks: familyRanks)
    }

    /// Pure ranking helper used by catalog tests and future catalog updates.
    /// Adding a stronger model to one family's rank list therefore cannot alter
    /// another family's normalized color strength.
    static func normalizedRank(rank: Int, familyRanks: [Int]) -> Double {
        let maximumRank = familyRanks.max() ?? max(0, rank)
        guard maximumRank > 0 else { return 0 }
        return min(1, max(0, Double(rank) / Double(maximumRank)))
    }

    static func isKnown(_ modelID: String) -> Bool {
        definitionsByID[canonicalID(modelID)] != nil
    }

    /// Family hints affect presentation metadata only. They intentionally do
    /// not change the canonical ID, so a future provider model remains a
    /// separate selectable identity instead of being destructively merged.
    private static func familyHint(for modelID: String) -> TokenModelFamily? {
        let value = modelID.lowercased()
        if value.hasPrefix("gpt-") || value.hasPrefix("openai/gpt-") { return .gpt }
        if value.hasPrefix("claude-") || value.hasPrefix("anthropic/claude-") { return .claude }
        if value.hasPrefix("gemini-") || value.hasPrefix("google/gemini-") || value.hasPrefix("google-antigravity/gemini-") { return .gemini }
        if value.hasPrefix("grok-") || value.hasPrefix("xai/grok-") { return .grok }
        if value == "k3" || value.hasPrefix("k3-") || value.hasPrefix("kimi-") || value.hasPrefix("kimi/") || value.hasPrefix("kimi-code/") { return .kimi }
        if value.hasPrefix("deepseek-") || value.hasPrefix("deepseek/") { return .deepSeek }
        return nil
    }

    private static func mediumRank(for family: TokenModelFamily) -> Int {
        switch family {
        case .gpt: 2
        case .claude: 2
        case .gemini: 2
        case .grok: 1
        case .kimi: 1
        case .deepSeek: 1
        case .unknown: 0
        }
    }

    private static func familySortIndex(_ family: TokenModelFamily) -> Int {
        switch family {
        case .gpt: 0
        case .claude: 1
        case .gemini: 2
        case .grok: 3
        case .kimi: 4
        case .deepSeek: 5
        case .unknown: 6
        }
    }
}

/// Pure selection logic behind the token card's two chip rows. Keeping it here
/// lets the tested rules decide what the panel shows: a family row that only
/// offers families with usage, and a model row that narrows to the selected
/// family.
extension TokenModelCatalog {
    /// Families available in the current snapshot. The active filter stays
    /// listed even when the selected range holds no data for it, so the filter
    /// can always be cleared again.
    static func familyOptions(
        observedModelIDs: [String],
        selectedFamily: TokenModelFamily?
    ) -> [TokenModelFamily] {
        var families = Set(observedModelIDs.map { family(for: $0) })
        if let selectedFamily {
            families.insert(selectedFamily)
        }
        families.remove(.unknown)
        return families.sorted { familySortIndex($0) < familySortIndex($1) }
    }

    /// Models shown under the family row: every observed model without a
    /// family filter, otherwise only that family's models. An explicitly
    /// selected model stays listed so it can be deselected.
    static func modelOptions(
        observedModelIDs: [String],
        selectedModelID: String?,
        selectedFamily: TokenModelFamily?
    ) -> [String] {
        var models = Set(observedModelIDs.map { canonicalID($0) })
        if let selectedFamily {
            models = models.filter { family(for: $0) == selectedFamily }
        }
        // Inserted after the family filter so a selected model is never hidden
        // by the row it has to be deselectable from.
        if let selectedModelID {
            models.insert(canonicalID(selectedModelID))
        }
        return sortedModelIDs(models)
    }

    /// Stable display order: family, then catalog strength, then name.
    static func sortedModelIDs<S: Sequence>(_ modelIDs: S) -> [String] where S.Element == String {
        modelIDs.sorted { lhs, rhs in
            let left = metadata(for: lhs)
            let right = metadata(for: rhs)
            if left.family != right.family {
                return familySortIndex(left.family) < familySortIndex(right.family)
            }
            if left.rank != right.rank { return left.rank > right.rank }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
