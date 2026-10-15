// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Combine
import CryptoKit

struct SavedBulletComments: Codable {
    var visible = true
    var feeds: [BulletFeed] = []
}

/// Disk access and file-provider reads run off the main actor. Only content is retained,
/// so imported feeds continue to work after Files revokes access to the selected document.
actor BulletCommentStore {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "anii/BulletComments", directoryHint: .isDirectory)
    }
    nonisolated static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func file(_ key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { throw BulletCommentError.invalidFile }
        return directory.appending(path: key + ".json")
    }
    func load(_ key: String) throws -> SavedBulletComments {
        let url = try file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedBulletComments() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= BulletCommentParser.byteLimit else { throw BulletCommentError.tooLarge }
        let value = try JSONDecoder().decode(SavedBulletComments.self, from: Data(contentsOf: url))
        guard value.feeds.count <= 8, value.feeds.reduce(0, { $0 + $1.document.comments.count }) <= BulletCommentParser.countLimit else {
            throw BulletCommentError.tooLarge
        }
        return value
    }
    func save(_ value: SavedBulletComments, key: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= BulletCommentParser.byteLimit else { throw BulletCommentError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(key), options: .atomic)
    }
    func importFile(_ url: URL) throws -> BulletDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<BulletDocument, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
            result = Result {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BulletCommentParser.byteLimit else { throw BulletCommentError.tooLarge }
                return try BulletCommentParser.parse(Data(contentsOf: file))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BulletCommentError.invalidFile }
        return try result.get()
    }
}

@MainActor
final class BulletCommentController: ObservableObject {
    @Published private(set) var feeds: [BulletFeed] = []
    @Published private(set) var visible = true
    @Published private(set) var revision = 0
    @Published private(set) var busy = false
    @Published private(set) var restoring = false
    @Published private(set) var results: [BulletEpisode] = []
    @Published private(set) var searched = false
    @Published var error: String?
    private let store: BulletCommentStore
    private var key: String?
    private var generation = UUID()
    private var request: Task<Void, Never>?
    private var restore: Task<Void, Never>?
    private var save: Task<Void, Never>?

    init(store: BulletCommentStore = BulletCommentStore()) { self.store = store }

    func openMedia(_ url: URL?) {
        generation = UUID(); request?.cancel(); restore?.cancel()
        key = url.map(BulletCommentStore.key)
        feeds = []; visible = true; results = []; searched = false; error = nil; busy = false; restoring = key != nil
        revision += 1
        guard let key else { return }
        let ticket = generation, pendingSave = save
        restore = Task {
            await pendingSave?.value
            do {
                let saved = try await store.load(key)
                guard ticket == generation, !Task.isCancelled else { return }
                feeds = saved.feeds; visible = saved.visible; revision += 1
            } catch { if ticket == generation, !Task.isCancelled { self.error = "Unable to restore comments: \(error.localizedDescription)" } }
            if ticket == generation { restoring = false }
        }
    }

    func setVisible(_ value: Bool) { visible = value; changed() }
    func setEnabled(_ value: Bool, id: String) {
        guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds[index].enabled = value; changed()
    }
    func setDelay(_ value: Double, id: String) {
        guard value.isFinite, abs(value) <= 3600 else {
            error = "Comment delay must be between −3600 and 3600 seconds."; return
        }
        guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds[index].delay = value; changed()
    }
    func remove(_ id: String) { feeds.removeAll { $0.id == id }; changed() }

    @discardableResult
    func add(_ feed: BulletFeed) throws -> Bool {
        guard key != nil, !restoring else { throw BulletCommentError.provider("Wait for the current video's saved comments to load.") }
        let others = feeds.filter { $0.id != feed.id }
        guard others.count < 8, others.reduce(feed.document.comments.count, { $0 + $1.document.comments.count }) <= BulletCommentParser.countLimit else {
            throw BulletCommentError.tooLarge
        }
        feeds = others + [feed]; changed(); return true
    }

    func importFile(_ url: URL) {
        begin { [store] in
            let document = try await store.importFile(url)
            return BulletFeed(id: UUID().uuidString, name: document.title ?? url.deletingPathExtension().lastPathComponent,
                              source: "Imported file", document: document)
        }
    }

    func find(_ identity: BulletVideoIdentity, client: DandanplayClient, titleSearch: Bool = false) {
        guard !restoring, key != nil else { return }
        request?.cancel(); busy = true; results = []; searched = false; error = nil
        let ticket = generation
        request = Task {
            do {
                let values = try await client.match(identity, searchByTitle: titleSearch)
                guard ticket == generation, !Task.isCancelled else { return }
                results = values; searched = true
            } catch { if ticket == generation, !Task.isCancelled { self.error = error.localizedDescription } }
            if ticket == generation, !Task.isCancelled { busy = false }
        }
    }

    func load(_ episode: BulletEpisode, related: Bool, client: DandanplayClient, force: Bool = false) {
        let id = "dandanplay:\(episode.id):\(related)"
        if !force, let existing = feeds.first(where: { $0.id == id }), Date().timeIntervalSince(existing.updatedAt) < 6 * 3600 {
            setEnabled(true, id: id); return
        }
        let existing = feeds.first { $0.id == id }
        begin {
            let document = try await client.comments(episodeID: episode.id, related: related)
            return BulletFeed(id: id, name: episode.episodeTitle.isEmpty ? episode.title : episode.displayTitle, source: related ? "Dandanplay + related (aggregated)" : "Dandanplay",
                              enabled: existing?.enabled ?? true, delay: existing?.delay ?? episode.delay, document: document,
                              episodeID: episode.id, includesRelated: related)
        }
    }

    private func begin(_ action: @escaping () async throws -> BulletFeed) {
        guard key != nil, !restoring else { return }
        request?.cancel(); busy = true; error = nil
        let ticket = generation
        request = Task {
            do {
                let feed = try await action()
                guard ticket == generation, !Task.isCancelled else { return }
                try add(feed)
            } catch { if ticket == generation, !Task.isCancelled { self.error = error.localizedDescription } }
            if ticket == generation, !Task.isCancelled { busy = false }
        }
    }

    func timeline() -> BulletTimeline {
        var values: [BulletComment] = [], seen: Set<String> = []
        for feed in feeds where feed.enabled {
            for var comment in feed.document.comments {
                comment.time += feed.delay
                guard comment.time.isFinite, comment.time >= 0 else { continue }
                let duplicate = "\(Int((comment.time * 10).rounded())):\(comment.mode.rawValue):\(comment.text.lowercased())"
                guard seen.insert(duplicate).inserted else { continue }
                comment.id = feed.id + ":" + comment.id
                values.append(comment)
            }
        }
        return BulletTimeline(comments: values)
    }

    private func changed() {
        revision += 1
        guard let key, !restoring else { return }
        let snapshot = SavedBulletComments(visible: visible, feeds: feeds)
        let previous = save, ticket = generation
        save = Task {
            await previous?.value
            do { try await store.save(snapshot, key: key) }
            catch { if ticket == generation { self.error = "Unable to save comment selection: \(error.localizedDescription)" } }
        }
    }

    /// Used by shutdown and verification to wait for the final serialized write.
    func finishSaving() async { await save?.value }
    deinit { request?.cancel(); restore?.cancel() }
}
