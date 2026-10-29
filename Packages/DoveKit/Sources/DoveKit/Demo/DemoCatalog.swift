#if DEBUG
import Foundation

public enum DemoCatalog {
    public static let addonURL = URL(string: "https://demo.dove.invalid/manifest.json")!
    private static func url(_ value: String) -> URL { URL(string: value)! }
    public static let films: [MediaDetail] = [
        .init(
            summary: .init(
                id: "tt0063350",
                type: .movie,
                name: "Night of the Living Dead",
                releaseInfo: "1968",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/Night_Of_The_Living_Dead_(1968)_-_Poster.jpg?width=500"
                ),
                description: "A small group takes shelter in a farmhouse as the dead begin to rise."
            ),
            genres: ["Horror", "Thriller"],
            runtime: "1h 36m"
        ),
        .init(
            summary: .init(
                id: "tt0013442",
                type: .movie,
                name: "Nosferatu",
                releaseInfo: "1922",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/Max_Schreck_as_Count_Orlok_in_Nosferatu_%E2%80%93_Eine_Symphonie_des_Grauens_(1922).jpg?width=500"
                ),
                description:
                    "A property agent travels to a remote castle, where its mysterious resident has a strange interest in his new home."
            ),
            genres: ["Horror", "Fantasy"],
            runtime: "1h 34m"
        ),
        .init(
            summary: .init(
                id: "tt0017136",
                type: .movie,
                name: "Metropolis",
                releaseInfo: "1927",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/Metropolis_(1926_US_ad_sheet_-_Paramount).jpg?width=500"
                ),
                description:
                    "In a vast future city, the son of its ruler encounters the workers whose labor sustains it."
            ),
            genres: ["Science Fiction", "Drama"],
            runtime: "2h 33m"
        ),
        .init(
            summary: .init(
                id: "tt0032599",
                type: .movie,
                name: "His Girl Friday",
                releaseInfo: "1940",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/His_Girl_Friday_(1940_poster).jpg?width=500"
                ),
                description:
                    "A sharp newspaper editor tries to keep his former partner on the story—and in his life."
            ),
            genres: ["Comedy", "Romance"],
            runtime: "1h 32m"
        ),
        .init(
            summary: .init(
                id: "tt0056923",
                type: .movie,
                name: "Charade",
                releaseInfo: "1963",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/Charade_(1963_poster).jpg?width=500"
                ),
                description:
                    "A widow in Paris searches for the truth about her husband’s missing fortune, with an unexpected ally."
            ),
            genres: ["Mystery", "Comedy"],
            runtime: "1h 53m"
        ),
        .init(
            summary: .init(
                id: "tt0052077",
                type: .movie,
                name: "Plan 9 from Outer Space",
                releaseInfo: "1957",
                poster: url(
                    "https://commons.wikimedia.org/wiki/Special:FilePath/Plan_9_Alternative_poster.jpg?width=500"
                ),
                description:
                    "Visitors from beyond Earth attempt to prevent humanity from creating a destructive weapon."
            ),
            genres: ["Science Fiction", "Horror"],
            runtime: "1h 19m"
        ),
    ]
    public static let series = MediaDetail(
        summary: .init(
            id: "tt0055662",
            type: .series,
            name: "The Beverly Hillbillies",
            releaseInfo: "1962",
            poster: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Buddy_Ebsen_and_Irene_Ryan_Beverly_Hillbillies_(1969_CBS_press_photo).jpg?width=500"
            ),
            description: "A country family adjusts to life in a new California home."
        ),
        genres: ["Comedy"],
        episodes: [
            .init(
                id: "tt0055662:1:2",
                season: 1,
                number: 2,
                title: "Getting Settled",
                overview: "The family begins making a home in their new surroundings."
            ),
            .init(
                id: "tt0055662:1:5",
                season: 1,
                number: 5,
                title: "Jed Buys Stock",
                overview: "Jed considers an unusual investment opportunity."
            ),
            .init(
                id: "tt0055662:1:7",
                season: 1,
                number: 7,
                title: "The Servants",
                overview: "The family meets the people who help run their household."
            ),
            .init(
                id: "tt0055662:1:10",
                season: 1,
                number: 10,
                title: "Pygmalion and Elly",
                overview: "A social visit gives Elly a chance to experience a new world."
            ),
        ]
    )
    public static let books: [BookSummary] = [
        .init(
            id: "demo:pride-and-prejudice",
            title: "Pride and Prejudice",
            authors: ["Jane Austen"],
            year: 1813,
            cover: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/PrideAndPrejudiceTitlePage.jpg?width=500"
            )
        ),
        .init(
            id: "demo:sherlock-holmes",
            title: "The Adventures of Sherlock Holmes",
            authors: ["Arthur Conan Doyle"],
            year: 1892,
            cover: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Adventures_of_sherlock_holmes.jpg?width=500"
            )
        ),
        .init(
            id: "demo:pan-tadeusz",
            title: "Pan Tadeusz",
            authors: ["Adam Mickiewicz"],
            year: 1834,
            cover: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Pan_Tadeusz_title_page_of_the_first_edition.jpg?width=500"
            )
        ),
        .init(
            id: "demo:lalka",
            title: "Lalka",
            authors: ["Bolesław Prus"],
            year: 1890,
            cover: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Lalka_-_strona_tytulowa_1_wydania.jpg?width=500"
            )
        ),
    ]
    public static let audiobooks: [(title: String, author: String, cover: URL)] = [
        (
            "The Adventures of Sherlock Holmes", "Arthur Conan Doyle",
            url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Sherlock_Holmes_-_The_Man_with_the_Twisted_Lip.jpg?width=500"
            )
        ),
        (
            "Pride and Prejudice", "Jane Austen",
            url("https://commons.wikimedia.org/wiki/Special:FilePath/Pride_and_Prejudice.jpg?width=500")
        ),
    ]
    public static let albums: [AlbumSummary] = [
        .init(
            id: "demo:chopin-nocturnes",
            title: "Nocturnes",
            artists: ["Frédéric Chopin"],
            year: 1840,
            cover: url("https://commons.wikimedia.org/wiki/Special:FilePath/Frederic_Chopin_photo.jpeg?width=500"),
            type: "Album"
        ),
        .init(
            id: "demo:beethoven-symphony-7",
            title: "Symphony No. 7",
            artists: ["Ludwig van Beethoven"],
            year: 1812,
            cover: url(
                "https://commons.wikimedia.org/wiki/Special:FilePath/Ludwig_van_Beethoven_(Stieler,_1820).jpg?width=500"
            ),
            type: "Album"
        ),
    ]
}
#endif
