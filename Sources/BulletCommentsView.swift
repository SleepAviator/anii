// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct BulletCommentsView: View {
    @ObservedObject var player: PlayerModel
    @ObservedObject var comments: BulletCommentController
    @Environment(\.dismiss) private var dismiss
    @State private var credentials = BulletProviderCredentials()
    @State private var client: DandanplayClient?
    @State private var query = ""
    @State private var related = false
    @State private var importing = false
    @State private var setup = false
    @State private var selection: BulletEpisode?
    private var locked: Bool { comments.busy || comments.restoring || !player.hasMedia }

    init(player: PlayerModel) { self.player = player; self.comments = player.bulletComments }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show bullet comments", isOn: Binding(get: { comments.visible }, set: comments.setVisible))
                        .accessibilityIdentifier("showBulletComments")
                    Text("Comments follow the video when you pause, seek, or change speed. Display is available inside anii; system Picture in Picture shows the video only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Comment sources") {
                    if comments.feeds.isEmpty { Text("No sources selected for this video.").foregroundStyle(.secondary) }
                    ForEach(comments.feeds) { feed in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: Binding(get: { comments.feeds.first { $0.id == feed.id }?.enabled ?? false },
                                                 set: { comments.setEnabled($0, id: feed.id) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feed.name)
                                    Text("\(feed.source) · \(feed.document.comments.count) comments").font(.caption).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("bulletSource-\(feed.id)")
                            HStack {
                                Text("Delay (seconds)")
                                TextField("Delay", value: Binding(get: { comments.feeds.first { $0.id == feed.id }?.delay ?? 0 },
                                                                  set: { comments.setDelay($0, id: feed.id) }), format: .number)
                                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 85)
                                Stepper("Delay", value: Binding(get: { comments.feeds.first { $0.id == feed.id }?.delay ?? 0 },
                                                               set: { comments.setDelay($0, id: feed.id) }), in: -3600...3600, step: 0.5)
                                    .labelsHidden()
                            }
                            if let reference = feed.document.duration, player.duration > 0,
                               abs(reference - player.duration) > max(10, player.duration * 0.02) {
                                Text("This source is \(playbackTime(reference)) long; your video is \(playbackTime(player.duration)). Check the edition and timing.")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            if feed.document.ignoredCount > 0 {
                                Text("\(feed.document.ignoredCount) malformed or unsupported comments were skipped.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                if let episodeID = feed.episodeID {
                                    Button("Refresh", systemImage: "arrow.clockwise") {
                                        guard let client else { setup = true; return }
                                        comments.load(BulletEpisode(id: episodeID, title: feed.name, episodeTitle: "", delay: feed.delay),
                                                      related: feed.includesRelated, client: client, force: true)
                                    }.buttonStyle(.borderless)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) { comments.remove(feed.id) }.buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 4)
                    }
                    Button("Import Comment File…", systemImage: "square.and.arrow.down") { importing = true }
                        .accessibilityIdentifier("importBulletComments")
                    Text("Import Bilibili XML, Dandanplay JSON, or anii JSON from Files. Sources, selections, and delays are saved for this video. Positive delay makes comments appear later.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Find matching video · Dandanplay") {
                    TextField("Movie or episode title", text: $query)
                        .accessibilityIdentifier("bulletMatchTitle").onSubmit { find() }
                    Text("Video length: \(playbackTime(player.duration)). Confirm the title and episode before loading a source.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Include related platforms", isOn: $related)
                    Text("Related comments are labeled as an aggregated source; this API does not guarantee an individual platform label for every comment.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Find Matching Video", systemImage: "sparkle.magnifyingglass") { find() }
                        .accessibilityIdentifier("findBulletMatch").disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Search Title Instead", systemImage: "magnifyingglass") { find(titleSearch: true) }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    if !credentials.configured { Button("Set Up Dandanplay") { setup = true } }
                    Text("Matching sends only the title you enter and video duration when you tap Find. No video, private folder path, or cloud URL is uploaded. Provider access needs an approved application ID and secret.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if comments.busy || comments.restoring {
                    Section { HStack { ProgressView(); Text(comments.restoring ? "Restoring saved comments…" : "Loading comments…") } }
                }
                if let error = comments.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("bulletCommentError") } }
                if comments.searched {
                    Section("Choose an episode") {
                        if comments.results.isEmpty { Text("No matching episodes. Edit the title or use Search Title Instead.") }
                        ForEach(comments.results) { episode in
                            Button { selection = episode } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(episode.title).foregroundStyle(.primary)
                                    Text(episode.episodeTitle).font(.callout).foregroundStyle(.secondary)
                                    if episode.exact { Text("Provider reports an exact match").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(locked)
            .navigationTitle("Bullet Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Provider Setup") { setup = true }.disabled(locked) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .json]) { result in
                switch result {
                case let .success(url): comments.importFile(url)
                case let .failure(error): comments.error = "Unable to import comments: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $setup) {
                BulletProviderSetupView(credentials: credentials) { value in
                    credentials = value; client = value.configured ? DandanplayClient(credentials: value) : nil
                }
            }
            .alert(item: $selection) { episode in
                Alert(title: Text("Load this comment source?"), message: Text(episode.displayTitle + "\nDifferent cuts may need a timing adjustment."),
                      primaryButton: .default(Text("Load")) {
                          guard let client else { return }
                          comments.load(episode, related: related, client: client)
                      }, secondaryButton: .cancel())
            }
            .onAppear {
                query = BulletVideoIdentity.cleanTitle(player.currentURL?.lastPathComponent ?? player.title)
                do {
                    credentials = try BulletAccountStore.load()
                    if credentials.configured { client = DandanplayClient(credentials: credentials) }
                } catch { comments.error = error.localizedDescription }
            }
            .onChange(of: player.currentID) { _, _ in selection = nil; dismiss() }
        }
    }

    private func find(titleSearch: Bool = false) {
        guard let client, credentials.configured else { setup = true; return }
        comments.find(BulletVideoIdentity(title: query, duration: player.duration), client: client, titleSearch: titleSearch)
    }
}

private struct BulletProviderSetupView: View {
    @State var credentials: BulletProviderCredentials
    let saved: (BulletProviderCredentials) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Approved Dandanplay application") {
                    TextField("App ID", text: $credentials.appID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("App Secret", text: $credentials.appSecret).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Dandanplay developer center", destination: URL(string: "https://dev.dandanplay.com")!)
                    Text("Credentials stay in this device's Keychain. Local comment files work without a provider account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Remove Saved Credentials", role: .destructive) {
                        do { try BulletAccountStore.remove(); saved(BulletProviderCredentials()); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .navigationTitle("Provider Setup").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        credentials.appID = credentials.appID.trimmingCharacters(in: .whitespacesAndNewlines)
                        credentials.appSecret = credentials.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        do { try BulletAccountStore.save(credentials); saved(credentials); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!credentials.configured)
                }
            }
        }
    }
}

private final class BulletDisplayTarget: NSObject {
    weak var view: BulletOverlayView?
    @objc func tick() { view?.render() }
}

/// Draw only the visible lanes. The view never handles touches or changes the playback backend.
final class BulletOverlayView: UIView {
    private weak var player: PlayerModel?
    private weak var surface: VideoSurfaceView?
    private var subscription: AnyCancellable?
    private let displayTarget = BulletDisplayTarget()
    private var displayLink: CADisplayLink?
    private var revision = -1
    private var timeline = BulletTimeline(comments: [])
    private var placements: [BulletPlacement] = []
    private var drawingRect = CGRect.zero
    private var widths: [String: CGFloat] = [:]
    private let font = UIFont.systemFont(ofSize: 22, weight: .semibold)
    private(set) var visibleTexts: [String] = []
    private(set) var renderedTime = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false; clipsToBounds = true
        isAccessibilityElement = true; accessibilityIdentifier = "bulletCommentOverlay"; accessibilityLabel = "Bullet comments"
        displayTarget.view = self
    }
    required init?(coder: NSCoder) { fatalError("BulletOverlayView uses programmatic initialization.") }

    func bind(player: PlayerModel, surface: VideoSurfaceView) {
        self.player = player; self.surface = surface
        subscription = player.objectWillChange.merge(with: player.bulletComments.objectWillChange)
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.refresh() }
        refresh()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, displayLink == nil {
            let link = CADisplayLink(target: displayTarget, selector: #selector(BulletDisplayTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common); displayLink = link
        }
        if window == nil { displayLink?.invalidate(); displayLink = nil }
        refresh()
    }
    private func refresh() {
        guard let player else { return }
        if revision != player.bulletComments.revision {
            revision = player.bulletComments.revision
            timeline = player.bulletComments.timeline(); widths.removeAll(keepingCapacity: true)
        }
        isHidden = !player.canRenderBulletComments || !player.bulletComments.visible || timeline.comments.isEmpty
        displayLink?.isPaused = isHidden || player.paused || player.buffering || player.loading
        render()
    }
    func render() {
        guard !isHidden, let player, player.canRenderBulletComments, player.bulletComments.visible, let surface else {
            placements = []; visibleTexts = []; accessibilityValue = ""; setNeedsDisplay(); return
        }
        var rect = bounds
        if !player.fillVideo {
            if player.backend == .native, surface.nativeLayer.videoRect.width > 0 { rect = surface.nativeLayer.videoRect }
            else if surface.presentedSize.width > 0 { rect = AVMakeRect(aspectRatio: surface.presentedSize, insideRect: bounds) }
        }
        drawingRect = rect.intersection(bounds)
        renderedTime = player.bulletCommentTime
        placements = timeline.placements(at: renderedTime, size: drawingRect.size) { text in
            if let width = self.widths[text] { return width }
            let width = (text as NSString).size(withAttributes: [.font: self.font]).width + 4
            self.widths[text] = width
            return width
        }
        visibleTexts = placements.map { $0.comment.text }
        let value = visibleTexts.prefix(8).joined(separator: "; ")
        if accessibilityValue != value { accessibilityValue = value }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.clip(to: drawingRect)
        for placement in placements {
            let color = placement.comment.color
            let foreground = UIColor(red: CGFloat((color >> 16) & 255) / 255, green: CGFloat((color >> 8) & 255) / 255,
                                     blue: CGFloat(color & 255) / 255, alpha: 0.9)
            (placement.comment.text as NSString).draw(in: placement.frame.offsetBy(dx: drawingRect.minX, dy: drawingRect.minY),
                withAttributes: [.font: font, .foregroundColor: foreground, .strokeColor: UIColor.black, .strokeWidth: -3])
        }
        context.restoreGState()
    }
    deinit { displayLink?.invalidate() }
}
