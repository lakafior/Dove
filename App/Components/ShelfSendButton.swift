import DoveAppCore
import DoveKit
import SwiftUI

/// "Send to Audiobookshelf" on an audiobook's screen (iPhone and Mac): the release's files come to this device, then
/// go to the server, with progress for both halves. Shown while Audiobookshelf is set up and lacks the book, or while
/// a send runs or has something to say. The transfer lives in the model (`AppModel.startShelfSend`), so a redrawn
/// screen shows the same one.
struct ShelfSendButton: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle

    var body: some View {
        let step = model.shelfSends[book.id]
        let message = model.shelfSendResults[book.id]
        if model.canSendToAudiobookshelf(book) || step != nil || message != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let step {
                    HStack {
                        ProgressView(value: fraction(step)) { Text(label(step)).font(.footnote) }
                        Button("Cancel", systemImage: "xmark.circle.fill") { model.cancelShelfSend(book.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                } else if model.canSendToAudiobookshelf(book) {
                    Button("Send to Audiobookshelf", systemImage: "square.and.arrow.up.on.square") { model.startShelfSend(book) }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fraction(_ step: AppModel.ShelfSendStep) -> Double {
        switch step {
        case .fetching(let value), .sending(let value): min(max(value, 0), 1)
        }
    }

    private func label(_ step: AppModel.ShelfSendStep) -> String {
        switch step {
        case .fetching(let value): "Fetching the files… \(value.formatted(.percent.precision(.fractionLength(0))))"
        case .sending(let value): "Sending to Audiobookshelf… \(value.formatted(.percent.precision(.fractionLength(0))))"
        }
    }
}
