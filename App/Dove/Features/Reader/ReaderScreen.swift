import DoveAppCore
import DoveKit
import PDFKit
import SwiftUI

// Brought over from AudiobookSwift's iOS reader (same author, MPL-2.0): the screen, the table of contents, the look
// settings and the PDF view; the place is Dove's (`ReadingPositions`, synced through iCloud Keychain).

/// What the reader opens: a book file already on this device (Downloads or the Read cache) and the book it is.
struct ReaderRequest: Identifiable, Hashable {
    let file: URL
    let title: String
    /// `BookGuess.key`: the place follows the book, not the release.
    let bookKey: String
    var id: URL { file }
}

/// Opens the file, starts at the saved place and saves new places (on this device at once, to the Keychain after
/// a second of quiet, so turning pages does not write on every page).
@MainActor @Observable
final class ReaderModel {
    enum Content {
        case epub(EpubController)
        case pdf(PDFDocument)
    }

    enum Phase {
        case loading
        case ready(Content)
        case failed(String)
    }

    let request: ReaderRequest
    private(set) var phase: Phase = .loading
    /// PDF: the current page (from 1) and the page count.
    var pdfPage = 1
    private(set) var pdfCount = 0

    @ObservationIgnored private let keychain: KeychainStore
    /// The first place reported after opening (the saved one): opening alone saves nothing.
    @ObservationIgnored private var openedCFI: String?
    @ObservationIgnored private var hasMoved = false
    @ObservationIgnored private var pending: ReadingPosition?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(request: ReaderRequest, keychain: KeychainStore) {
        self.request = request
        self.keychain = keychain
    }

    var title: String { request.title }

    func load(look: [String: Any], layout: [String: Any], spread: String) {
        let saved = SharedConfiguration.readingPositions(from: keychain)[request.bookKey]
        switch BookFiles.format(of: request.file.lastPathComponent) {
        case "epub":
            let size = (try? request.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let start = saved.flatMap { $0.location.hasPrefix("epubcfi(") ? $0.location : nil }
            let controller = EpubController(book: request.file, cacheKey: "\(request.bookKey)-\(size)", startLocation: start,
                                            look: look, layout: layout, spread: spread)
            controller.onMove = { [weak self] place in
                guard let self else { return }
                if openedCFI == nil {
                    openedCFI = place.cfi
                } else if hasMoved || place.cfi != openedCFI {
                    hasMoved = true
                    record(ReadingPosition(location: place.cfi, progress: place.progress))
                }
            }
            phase = .ready(.epub(controller))
        case "pdf":
            guard let document = PDFDocument(url: request.file) else {
                phase = .failed("This PDF does not open (a damaged or locked file).")
                return
            }
            pdfCount = document.pageCount
            pdfPage = min(max(1, saved?.page ?? 1), max(1, document.pageCount))
            phase = .ready(.pdf(document))
        default:
            phase = .failed("Dove's reader opens EPUB and PDF. Use Share file to open this one in another app.")
        }
    }

    func pdfPageChanged(_ page: Int) {
        guard page != pdfPage else { return }
        pdfPage = page
        record(.page(page, of: pdfCount))
    }

    private func record(_ position: ReadingPosition) {
        pending = position
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        guard let pending else { return }
        SharedConfiguration.saveReadingPosition(pending, for: request.bookKey, to: keychain)
        self.pending = nil
    }

    func close() {
        saveTask?.cancel()
        flush()
    }
}

/// The reader, full screen: EPUB (epub.js) or PDF (PDFKit); a tap in the middle hides and shows the bars.
struct ReaderScreen: View {
    let request: ReaderRequest

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model: ReaderModel?
    @State private var look = ReaderLook.load()
    @State private var showsChrome = true
    @State private var showsContents = false
    @State private var showsSettings = false
    @State private var sliderValue: Double?

    var body: some View {
        GeometryReader { geometry in
            content
                .task {
                    guard model == nil else { return }
                    let model = ReaderModel(request: request, keychain: app.keychain)
                    self.model = model
                    model.load(look: look.javaScript(dynamicType: contentSize), layout: layout, spread: spread(width: geometry.size.width))
                }
                .onChange(of: geometry.size) { _, size in
                    epub?.setSpread(spread(width: size.width))
                    // The page's `resize` can come before WKWebView has its new size (rotation), so epub.js lays
                    // out for the old width; a second call a moment later fixes it.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        epub?.call("book.resize()")
                    }
                }
        }
        .background(isPDF ? Color(.systemBackground) : look.theme.page)
        // The theme only in the reader (`preferredColorScheme` would switch the whole app underneath).
        .environment(\.colorScheme, isPDF ? systemScheme : look.theme.colorScheme)
        .statusBarHidden(!showsChrome)
        .onChange(of: look) { _, look in
            look.save()
            epub?.setLook(look.javaScript(dynamicType: contentSize))
            epub?.setLayout(layout)
        }
        .onChange(of: dynamicTypeSize) { _, _ in epub?.setLook(look.javaScript(dynamicType: contentSize)) }
        .onChange(of: verticalSizeClass) { _, _ in epub?.setLayout(layout) }
        .onDisappear { model?.close() }
        .sheet(isPresented: $showsContents) {
            if let epub { ReaderContents(controller: epub) }
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettings(look: $look)
                .presentationDetents([.medium, .large])
        }
    }

    private var contentSize: UIContentSizeCategory { UIContentSizeCategory(dynamicTypeSize) }

    /// Room for the bars (top and bottom), so they do not cover text when shown.
    private var layout: [String: Any] {
        // An iPhone on its side: lower bars, and every line of text counts.
        verticalSizeClass == .compact
            ? ["side": look.margins.points, "top": 44, "bottom": 44]
            : ["side": look.margins.points, "top": 60, "bottom": 64]
    }

    private func spread(width: CGFloat) -> String { width > 900 ? "auto" : "none" }

    private var epub: EpubController? {
        if case .ready(.epub(let controller)) = model?.phase { return controller }
        return nil
    }

    private var isPDF: Bool {
        if case .ready(.pdf) = model?.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model?.phase ?? .loading {
        case .loading:
            ProgressView("Opening the book…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { closeButton.padding() }
        case .failed(let message):
            ContentUnavailableView {
                Label("The book does not open", systemImage: "book.closed")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .ready(.epub(let controller)):
            epubView(controller)
        case .ready(.pdf(let document)):
            if let model { pdfView(document, model: model) }
        }
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark") { dismiss() }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
    }

    // MARK: - EPUB

    private func epubView(_ controller: EpubController) -> some View {
        EpubPageView(controller: controller) { toggleChrome() }
            .overlay {
                if let failure = controller.failure {
                    ContentUnavailableView("The book does not open", systemImage: "book.closed", description: Text(failure))
                        .background(look.theme.page)
                }
            }
            .overlay(alignment: .top) {
                if showsChrome { topBar(controller).transition(.opacity) }
            }
            .overlay(alignment: .bottom) {
                if showsChrome {
                    bottomBar(controller).transition(.opacity)
                } else if let progress = controller.place?.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(look.theme.ink.opacity(0.6))
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Next page") { controller.next() }
            .accessibilityAction(named: "Previous page") { controller.previous() }
            .accessibilityAction(named: showsChrome ? "Hide controls" : "Show controls") { toggleChrome() }
            .accessibilityScrollAction { edge in
                switch edge {
                case .trailing, .bottom: controller.next()
                default: controller.previous()
                }
            }
    }

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsChrome.toggle() }
    }

    private func topBar(_ controller: EpubController) -> some View {
        HStack(spacing: 12) {
            closeButton
            VStack(spacing: 1) {
                Text(request.title).font(.headline).lineLimit(1)
                if let chapter = controller.place?.chapter, !chapter.isEmpty {
                    Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            Button("Contents", systemImage: "list.bullet") { showsContents = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(controller.toc.isEmpty)
            Button("Appearance", systemImage: "textformat.size") { showsSettings = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func bottomBar(_ controller: EpubController) -> some View {
        VStack(spacing: 4) {
            if controller.hasLocations, let progress = controller.place?.progress {
                Slider(value: Binding(get: { sliderValue ?? progress }, set: { sliderValue = $0 }), in: 0...1) { editing in
                    if !editing, let value = sliderValue {
                        controller.seek(value)
                        sliderValue = nil
                    }
                }
                .accessibilityLabel("Place in the book")
                .accessibilityValue(Text(sliderValue ?? progress, format: .percent.precision(.fractionLength(0))))
                Text(sliderValue ?? progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Text("Counting pages…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    // MARK: - PDF

    private func pdfView(_ document: PDFDocument, model: ReaderModel) -> some View {
        PDFPageView(document: document, page: model.pdfPage) { model.pdfPageChanged($0) }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) {
                HStack {
                    closeButton
                    Text(request.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                    Text("\(model.pdfPage) / \(model.pdfCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Page \(model.pdfPage) of \(model.pdfCount)")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
    }
}

/// The EPUB's table of contents.
private struct ReaderContents: View {
    let controller: EpubController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(controller.toc) { item in
                Button {
                    controller.go(item)
                    dismiss()
                } label: {
                    Text(item.label.isEmpty ? "Untitled" : item.label)
                        .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                        .foregroundStyle(.primary)
                }
                .accessibilityAddTraits(isCurrent(item) ? .isSelected : [])
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func isCurrent(_ item: ReaderTocItem) -> Bool {
        guard let href = controller.place?.href else { return false }
        let path = item.href.split(separator: "#").first.map(String.init) ?? item.href
        return path.hasSuffix(href) || href.hasSuffix(path)
    }
}

/// Typeface, size, margins and theme.
private struct ReaderSettings: View {
    @Binding var look: ReaderLook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $look.theme) {
                        ForEach(ReaderLook.Theme.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Typeface", selection: $look.font) {
                        ForEach(ReaderLook.Font.allCases) { Text($0.name).tag($0) }
                    }
                    Stepper(value: $look.sizeStep, in: ReaderLook.sizeSteps) {
                        LabeledContent("Size", value: "\(look.fontPercent(dynamicType: UIContentSizeCategory(dynamicTypeSize)))%")
                    }
                    Picker("Margins", selection: $look.margins) {
                        ForEach(ReaderLook.Margins.allCases) { Text($0.name).tag($0) }
                    }
                } header: {
                    Text("Text")
                } footer: {
                    Text("The size starts from the text size set for the system (Dynamic Type).")
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A PDF in PDFKit: pages one under another, page changes reported for saving.
private struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let page: Int
    let onPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        context.coordinator.observe(view)
        // The saved page only after the first layout (PDFView ignores it before); until then page changes are not
        // saved, or page 1 would overwrite the place from another device.
        let start = document.page(at: page - 1)
        DispatchQueue.main.async {
            view.layoutIfNeeded()
            if let start { view.go(to: start) }
            context.coordinator.isReady = true
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onPage = onPage
    }

    @MainActor final class Coordinator: NSObject {
        var onPage: (Int) -> Void
        var isReady = false

        init(onPage: @escaping (Int) -> Void) { self.onPage = onPage }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard isReady, let view = notification.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            onPage(document.index(for: page) + 1)
        }
    }
}
