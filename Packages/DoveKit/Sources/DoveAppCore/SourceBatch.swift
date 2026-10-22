import DoveKit
import Foundation

/// Sources picked up together (one, or a pasted list of links), for `.sheet(item:)`.
public struct SourceBatch: Identifiable {
    public let id = UUID()
    public var sources: [Source]

    public init(_ sources: [Source]) {
        self.sources = sources
    }
}
