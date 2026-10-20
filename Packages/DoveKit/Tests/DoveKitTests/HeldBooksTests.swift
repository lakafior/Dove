import Foundation
import Testing
@testable import DoveKit

struct HeldBooksTests {
    private func title(_ id: String, _ name: String, _ authors: [String], format: BookFormat = .ebook) -> BookTitle {
        BookTitle(
            id: id,
            guess: BookGuess(title: name, author: authors.first, format: format),
            book: BookSummary(id: "calibre:\(id)", title: name, authors: authors),
            items: []
        )
    }

    private var held: HeldBooks {
        HeldBooks([
            title("1", "Klara i słońce", ["Kazuo Ishiguro"]),
            title("2", "„A co ciebie obchodzi, co myślą inni?”", ["Feynman Richard P."]),
            title("3", "Mistborn", ["Brandon Sanderson"]),
            title("4", "Solaris", ["Stanisław Lem"]),
            title("5", "Project Hail Mary", ["Andy Weir"], format: .audiobook),
        ])
    }

    @Test func sameTitleAndAuthorWordsMatch() {
        #expect(held.held(BookSummary(id: "ol:1", title: "Klara i Słońce", authors: ["Kazuo Ishiguro"]), format: .ebook)?.id == "1")
        // Calibre keeps "Surname Name"; the services say "Name Surname".
        #expect(held.held(BookSummary(id: "ol:2", title: "A co ciebie obchodzi, co myślą inni?", authors: ["Richard P. Feynman"]), format: .ebook)?.id == "2")
        // A subtitle the library's copy lacks.
        #expect(held.held(BookSummary(id: "ol:3", title: "Mistborn: The Final Empire", authors: ["Brandon Sanderson"]), format: .ebook)?.id == "3")
    }

    @Test func anotherAuthorOrFormatOrTitleIsNotHeld() {
        #expect(held.held(BookSummary(id: "ol:4", title: "Solaris", authors: ["Chantal Thomas"]), format: .ebook) == nil)
        #expect(held.held(BookSummary(id: "ol:5", title: "Project Hail Mary", authors: ["Andy Weir"]), format: .ebook) == nil)
        #expect(held.held(BookSummary(id: "ol:5", title: "Project Hail Mary", authors: ["Andy Weir"]), format: .audiobook)?.id == "5")
        #expect(held.held(BookSummary(id: "ol:6", title: "Klara", authors: ["Kazuo Ishiguro"]), format: .ebook) == nil)
    }

    @Test func withoutAuthorsTheTitleDecides() {
        #expect(held.held(BookSummary(id: "x", title: "Solaris"), format: .ebook)?.id == "4")
        #expect(HeldBooks([]).isEmpty)
    }
}
