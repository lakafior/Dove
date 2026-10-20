import DoveKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (iOS 26, Apple Intelligence on): described filters and "find by description" hide
/// without it.
enum OnDeviceModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }
}

/// "2160p DV without Atmos under 20 GB, Polish audio" → a `SourceRequest`, through the on-device model. The model
/// only maps words to the fields and values it is given (the list's own values); `SourceRequest` drops anything it
/// made up. Nothing leaves the device. Hidden where the model is not available.
enum DescribedFilter {
    enum Failure: LocalizedError {
        case unavailable
        case nothingUnderstood

        var errorDescription: String? {
            switch self {
            case .unavailable: "Apple Intelligence is not available on this iPhone."
            case .nothingUnderstood: "Nothing in that matched resolution, source, codec, HDR, audio, language, size or order. Try words like \u{201C}4K DV, no Atmos, under 20 GB\u{201D}."
            }
        }
    }

    static func request(for text: String, groups: [StreamGroup]) async throws -> SourceRequest {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let wish = try await LanguageModelSession(instructions: instructions(for: groups))
                .respond(to: text, generating: SourceWish.self, options: GenerationOptions(samplingMode: .greedy))
                .content
            let request = SourceRequest(
                text: text,
                wanted: SourceRequest.grouped(wish.wanted.map { ($0.dimension, $0.value) }),
                avoided: SourceRequest.grouped(wish.avoided.map { ($0.dimension, $0.value) }),
                maxSizeGB: wish.maxSizeGB,
                minSizeGB: wish.minSizeGB,
                cachedOnly: wish.cachedOnly,
                appleTVFriendly: wish.appleTVFriendly,
                sort: wish.order,
                in: groups
            )
            guard !request.isEmpty else { throw Failure.nothingUnderstood }
            return request
        }
        #endif
        throw Failure.unavailable
    }

    /// The fields and the values this list has, so the model picks from them instead of inventing.
    private static func instructions(for groups: [StreamGroup]) -> String {
        let vocabulary = SourceRequest.vocabulary(for: groups)
        let values = SourceRequest.dimensionNames
            .sorted { $0.key < $1.key }
            .map { name, dimension in "\(name): \((vocabulary[dimension] ?? []).joined(separator: ", "))" }
            .joined(separator: "\n")
        return """
        You turn a short description of the video release someone wants into filter settings for a list of releases.
        Use only these dimensions and values; leave out anything that does not fit them rather than guess.
        \(values)
        "Without X", "no X" and "not X" go to avoided; everything asked for goes to wanted. \
        "4K" is 2160p, "Dolby Vision" is DV, a language name is its code (Polish is PL); \
        "Polish audio" is a language, not an audio format. \
        Sizes are in gigabytes: "under 20 GB" is maxSizeGB 20, "over 10 GB" is minSizeGB 10. \
        cachedOnly is true only when the description asks for cached or instant releases. \
        appleTVFriendly is true only when it mentions Apple TV. \
        order is none unless the description asks for an order.
        """
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
struct SourceWish {
    @Generable
    struct Criterion {
        @Guide(description: "Which property of the release", .anyOf(["resolution", "source", "codec", "hdr", "audio", "language", "type"]))
        var dimension: String
        @Guide(description: "One of the values listed for that dimension")
        var value: String
    }

    @Guide(description: "What the release should have")
    var wanted: [Criterion]
    @Guide(description: "What the release must not have")
    var avoided: [Criterion]
    @Guide(description: "Largest size in gigabytes, when the description gives one")
    var maxSizeGB: Double?
    @Guide(description: "Smallest size in gigabytes, when the description gives one")
    var minSizeGB: Double?
    var cachedOnly: Bool
    var appleTVFriendly: Bool
    @Guide(description: "How to order the list", .anyOf(["none", "largest", "smallest", "seeders", "newest"]))
    var order: String
}
#endif
