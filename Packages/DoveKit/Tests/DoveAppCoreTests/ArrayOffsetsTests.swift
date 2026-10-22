@testable import DoveAppCore
import Foundation
import Testing

struct ArrayOffsetsTests {
    @Test func removesEveryOffset() {
        var letters = ["a", "b", "c", "d"]
        letters.remove(atOffsets: [0, 2])
        #expect(letters == ["b", "d"])
    }

    @Test func movesLikeSwiftUI() {
        var down = ["a", "b", "c", "d"]
        down.move(fromOffsets: [0], toOffset: 3)
        #expect(down == ["b", "c", "a", "d"])

        var up = ["a", "b", "c", "d"]
        up.move(fromOffsets: [3], toOffset: 1)
        #expect(up == ["a", "d", "b", "c"])

        var several = ["a", "b", "c", "d", "e"]
        several.move(fromOffsets: [0, 2], toOffset: 5)
        #expect(several == ["b", "d", "e", "a", "c"])
    }
}
