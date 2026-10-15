// SPDX-License-Identifier: GPL-3.0-only

import XCTest
import AVFoundation
import SwiftUI
@testable import anii

private actor BulletFixtureAPI {
    var requests: [URLRequest] = []
    var status = 200
    var redirect: String?
    var businessError = false
    var incomplete = false
    var suspended = false
    private var pending: CheckedContinuation<Void, Never>?
    func configure(status: Int = 200, redirect: String? = nil, businessError: Bool = false, suspended: Bool = false, incomplete: Bool = false) {
        self.status = status; self.redirect = redirect; self.businessError = businessError; self.suspended = suspended; self.incomplete = incomplete
    }
    func release() { pending?.resume(); pending = nil }
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if suspended { await withCheckedContinuation { pending = $0 } }
        let url = try XCTUnwrap(request.url)
        if let redirect, url.host == "api.dandanplay.net", url.path.contains("/comment/") {
            return (Data(), HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirect])!)
        }
        let body: String
        if incomplete { body = #"{"success":true}"# }
        else if businessError { body = #"{"success":false,"errorMessage":"Fixture quota exceeded"}"# }
        else if url.path == "/api/v2/match" {
            body = #"{"success":true,"isMatched":false,"matches":[{"episodeId":12,"animeTitle":"Series","episodeTitle":"S01E04","shift":0},{"episodeId":11,"animeTitle":"Series","episodeTitle":"S01E03","shift":1.5}]}"#
        } else if url.path == "/api/v2/search/episodes" {
            body = #"{"success":true,"hasMore":false,"animes":[{"animeTitle":"Series","episodes":[{"episodeId":11,"episodeTitle":"S01E03"}]}]}"#
        } else { body = #"{"count":1,"comments":[{"cid":9,"p":"1.25,1,16777215,42","m":"Synthetic API comment"}]}"# }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class BulletCommentTests: XCTestCase {
    private let credentials = BulletProviderCredentials(appID: "test-app", appSecret: "test-secret")
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BulletTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @MainActor
    private func wait(_ message: String, timeout: Double = 12, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(condition(), message)
    }

    func testXMLModesAndMalformedRows() throws {
        let xml = #"<i><d p="2.5,1,25,16711680,0,0,user,1">A &amp; B</d><d p="1,5,25,255,0,0,user,2">Top</d><d p="3,4,25,65280,0,0,user,3">Bottom</d><d p="nan,1,25,0">Bad</d><d p="1,7,25,0">["script"]</d></i>"#
        let document = try BulletCommentParser.parse(Data(xml.utf8))
        XCTAssertEqual(document.comments.map(\.text), ["Top", "A & B", "Bottom"])
        XCTAssertEqual(document.comments.map(\.mode), [.top, .scroll, .bottom])
        XCTAssertEqual(document.comments[1].color, 0xFF0000)
        XCTAssertEqual(document.comments[1].time, 2.5)
        XCTAssertEqual(document.ignoredCount, 2)
    }

    func testXMLRejectsExternalEntitiesAndCorruption() {
        for text in [#"<!DOCTYPE i [<!ENTITY data SYSTEM "file:///private/no-such-file">]><i><d p="1,1,25,0">&data;</d></i>"#,
                     #"<i><d p="1,1,25,0">unclosed"#] {
            XCTAssertThrowsError(try BulletCommentParser.parse(Data(text.utf8)))
        }
    }

    func testXMLByteOrderMarksAndUTF16EntityRejection() throws {
        let text = #"<i><d p="1,1,25,16777215">Unicode 弹幕</d></i>"#
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let utf16 = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        for data in [utf8, utf16] {
            XCTAssertEqual(try BulletCommentParser.parse(data).comments.first?.text, "Unicode 弹幕")
        }
        let declaration = #"<!DOCTYPE i [<!ENTITY data SYSTEM "file:///private/no-such-file">]><i><d p="1,1,25,0">&data;</d></i>"#
        XCTAssertThrowsError(try BulletCommentParser.parse(Data([0xFF, 0xFE]) + declaration.data(using: .utf16LittleEndian)!))
        XCTAssertThrowsError(try BulletCommentParser.parse(declaration.data(using: .utf16BigEndian)!))
    }

    func testJSONFormatsAndBounds() throws {
        let native = ##"{"title":"Synthetic episode","duration":1200,"comments":[{"time":1,"text":"plain text <b>no HTML</b>","mode":"top","color":"#FF00FF"},{"time":-2,"text":"invalid"},{"time":true,"text":"invalid"}]}"##
        let value = try BulletCommentParser.parse(Data(native.utf8))
        XCTAssertEqual(value.title, "Synthetic episode"); XCTAssertEqual(value.duration, 1200)
        XCTAssertEqual(value.comments[0].text, "plain text <b>no HTML</b>")
        XCTAssertEqual(value.comments[0].color, 0xFF00FF); XCTAssertEqual(value.ignoredCount, 2)
        let provider = try BulletCommentParser.parse(Data(#"{"comments":[{"p":"12.34,4,16777215,user","m":"Bottom"}]}"#.utf8))
        XCTAssertEqual(provider.comments[0].time, 12.34); XCTAssertEqual(provider.comments[0].mode, .bottom)
        XCTAssertTrue(try BulletCommentParser.parse(Data(#"{"comments":[]}"#.utf8)).comments.isEmpty)
        XCTAssertThrowsError(try BulletCommentParser.parse(Data(repeating: 32, count: BulletCommentParser.byteLimit + 1)))
        XCTAssertThrowsError(try BulletCommentParser.parse(Data(#"{"comments":[{"time":1,"text":"","color":"bogus"}]}"#.utf8)))
    }

    func testMatchingKeepsEpisodeAndUsesDurationWithoutGuessing() {
        let title = BulletVideoIdentity.cleanTitle("[Release] Series.S01E03.1080p.x265.AAC.mkv")
        XCTAssertEqual(title, "Series S01E03")
        let identity = BulletVideoIdentity(title: title, duration: 1440)
        XCTAssertEqual(identity.episode, 3); XCTAssertEqual(identity.season, 1)
        XCTAssertEqual(BulletVideoIdentity(title: "节目 第12集", duration: 0).episode, 12)
        XCTAssertGreaterThan(identity.score(title: title, duration: 1441), identity.score(title: title, duration: 1800))
        XCTAssertEqual(identity.score(title: "Series S01E04", duration: 1440), -1)
        XCTAssertEqual(identity.score(title: "Series S02E03", duration: 1440), -1)
        XCTAssertEqual(identity.score(title: title, duration: nil), 1)
    }

    func testClockPauseBufferSpeedAndSeek() {
        var clock = BulletPlaybackClock()
        clock.sample(position: 10, rate: 2, now: 100)
        XCTAssertEqual(clock.time(now: 100.2), 10.4, accuracy: 0.001)
        clock.setRate(0, now: 100.2)
        XCTAssertEqual(clock.time(now: 103), 10.4, accuracy: 0.001)
        clock.setRate(0, now: 104)
        XCTAssertEqual(clock.time(now: 105), 10.4, accuracy: 0.001)
        clock.sample(position: 3, rate: 0.5, now: 106)
        XCTAssertEqual(clock.time(now: 106.2), 3.1, accuracy: 0.001)
        clock.setRate(0.5, now: 108)
        XCTAssertEqual(clock.time(now: 109), 3.15, accuracy: 0.001, "Stale samples must not advance indefinitely")
    }

    func testTimelineSeekReplayDensityAndCollisionSpacing() {
        let values = (0..<100).map { BulletComment(id: String($0), time: 1, text: "Comment \($0)") }
        var timeline = BulletTimeline(comments: values)
        let size = CGSize(width: 600, height: 500)
        let first = timeline.placements(at: 1.2, size: size, measure: { _ in 100 })
        XCTAssertEqual(first.count, 8, "A burst must fit available lanes, rather than overlap")
        let same = timeline.placements(at: 1.2, size: size, measure: { _ in 100 })
        XCTAssertEqual(first.map(\.frame), same.map(\.frame), "A stationary media clock must freeze the overlay")
        let next = timeline.placements(at: 1.4, size: size, measure: { _ in 100 })
        XCTAssertLessThan(next[0].frame.minX, first[0].frame.minX)
        XCTAssertTrue(timeline.placements(at: 10, size: size, measure: { _ in 100 }).isEmpty)
        XCTAssertEqual(timeline.placements(at: 1.2, size: size, measure: { _ in 100 }).count, 8, "Seeking backward should replay the correct window")
    }

    func testProviderSignsMetadataCachesMatchesAndRanksEpisodes() async throws {
        let api = BulletFixtureAPI()
        let client = DandanplayClient(credentials: credentials, now: { Date(timeIntervalSince1970: 1735660800) }, fetch: { try await api.fetch($0) })
        let identity = BulletVideoIdentity(title: "/private/library/Series.S01E03.1080p.mkv", duration: 1440.9)
        let results = try await client.match(identity)
        XCTAssertEqual(results.first?.id, 11); XCTAssertEqual(results.first?.delay, 1.5)
        XCTAssertNil(results.first?.duration, "Provider doesn't supply candidate duration; don't invent one")
        _ = try await client.match(identity)
        let requests = await api.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppId"), "test-app")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-AppSecret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Signature"), "qJ4Zl5JADrNh5ujPoe1zh0ObjCrdvdE1EL6VR5y1XMg=")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["fileName"] as? String, "Series S01E03")
        XCTAssertEqual(body["videoDuration"] as? Int, 1440)
        XCTAssertEqual(body["matchMode"] as? String, "fileNameOnly")
        XCTAssertNil(body["fileHash"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("/private/"))
        let search = try await client.match(BulletVideoIdentity(title: "Series", duration: 1440), searchByTitle: true)
        XCTAssertEqual(search.first?.id, 11)
    }

    func testSignedCloudURLNeverGoesToMatchingProvider() async throws {
        let api = BulletFixtureAPI()
        let client = DandanplayClient(credentials: credentials, fetch: { try await api.fetch($0) })
        _ = try await client.match(BulletVideoIdentity(title: "https://user:password@private.example/media/Series.mp4?token=private-token", duration: 12))
        let requests = await api.requests
        let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("password")); XCTAssertFalse(body.contains("private.example")); XCTAssertFalse(body.contains("token"))
    }

    func testCommentRedirectDropsCredentialsAndRejectsForeignHosts() async throws {
        let api = BulletFixtureAPI()
        await api.configure(redirect: "https://comments.dandanplay.net/fixture.json")
        let client = DandanplayClient(credentials: credentials, fetch: { try await api.fetch($0) })
        let document = try await client.comments(episodeID: 11, related: true)
        XCTAssertEqual(document.comments[0].time, 1.25)
        let requests = await api.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("withRelated=true"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-Signature")); XCTAssertNil(requests[1].value(forHTTPHeaderField: "X-AppId"))
        await api.configure(redirect: "https://dandanplay.net.attacker.example/comments")
        do { _ = try await client.comments(episodeID: 12, related: false); XCTFail("Foreign redirect was accepted") }
        catch BulletCommentError.unsafeRedirect { }
        for url in ["http://comments.dandanplay.net/a", "https://user:pass@dandanplay.net/a", "https://dandanplay.net:8443/a"] {
            XCTAssertFalse(DandanplayClient.allowedCommentURL(URL(string: url)!))
        }
    }

    func testProviderErrorsAndMissingCredentialsAreExplicit() async throws {
        let api = BulletFixtureAPI()
        let missing = DandanplayClient(credentials: BulletProviderCredentials(), fetch: { try await api.fetch($0) })
        do { _ = try await missing.match(BulletVideoIdentity(title: "Series", duration: 12)); XCTFail("Missing setup was hidden") }
        catch BulletCommentError.setup { }
        let empty = await api.requests
        XCTAssertTrue(empty.isEmpty)
        let client = DandanplayClient(credentials: credentials, fetch: { try await api.fetch($0) })
        await api.configure(status: 429)
        do { _ = try await client.comments(episodeID: 11, related: false); XCTFail("Quota error was hidden") }
        catch BulletCommentError.http(429) { }
        await api.configure(businessError: true)
        do { _ = try await client.comments(episodeID: 11, related: false); XCTFail("Business error was hidden") }
        catch BulletCommentError.provider(let text) { XCTAssertEqual(text, "Fixture quota exceeded") }
    }

    func testIncompleteMatchingResponseIsNotShownAsNoMatches() async throws {
        let api = BulletFixtureAPI(); await api.configure(incomplete: true)
        let client = DandanplayClient(credentials: credentials, fetch: { try await api.fetch($0) })
        for titleSearch in [true, false] {
            do { _ = try await client.match(BulletVideoIdentity(title: "Series", duration: 12), searchByTitle: titleSearch); XCTFail("Malformed response was hidden") }
            catch BulletCommentError.invalidResponse { }
        }
    }

    @MainActor
    func testSourcesOffsetsDeduplicationAndPersistentVideoIsolation() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = BulletCommentStore(directory: folder)
        let controller = BulletCommentController(store: store)
        let url = URL(string: "https://video.example/episode1.mp4")!
        controller.openMedia(url)
        try await wait("Saved state did not load") { !controller.restoring }
        let document = try BulletCommentParser.parse(Data(#"{"comments":[{"time":1,"text":"Same comment"}]}"#.utf8))
        try controller.add(BulletFeed(id: "one", name: "Source One", source: "Imported file", document: document))
        try controller.add(BulletFeed(id: "two", name: "Source Two", source: "Imported file", document: document))
        XCTAssertEqual(controller.timeline().comments.count, 1)
        controller.setEnabled(false, id: "one")
        controller.setDelay(2, id: "two")
        XCTAssertEqual(controller.timeline().comments.first?.time, 3)
        controller.setVisible(false)
        await controller.finishSaving()
        controller.openMedia(URL(string: "https://video.example/episode2.mp4")!)
        try await wait("Second media did not load") { !controller.restoring }
        XCTAssertTrue(controller.feeds.isEmpty)
        controller.openMedia(url)
        try await wait("First media didn't restore") { !controller.restoring }
        XCTAssertEqual(controller.feeds.count, 2); XCTAssertFalse(controller.visible)
        XCTAssertFalse(controller.feeds[0].enabled); XCTAssertEqual(controller.feeds[1].delay, 2)
        XCTAssertFalse(BulletCommentStore.key(for: url).contains("episode1"))
        controller.remove("one"); controller.remove("two"); await controller.finishSaving()
    }

    @MainActor
    func testChangedMediaDiscardsPendingMatches() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let controller = BulletCommentController(store: BulletCommentStore(directory: folder))
        controller.openMedia(URL(string: "https://video.example/one.mp4")!)
        try await wait("Restore did not finish") { !controller.restoring }
        let api = BulletFixtureAPI(); await api.configure(suspended: true)
        let client = DandanplayClient(credentials: credentials, fetch: { try await api.fetch($0) })
        controller.find(BulletVideoIdentity(title: "Series", duration: 12), client: client)
        for _ in 0..<100 { if !(await api.requests).isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        controller.openMedia(URL(string: "https://video.example/two.mp4")!)
        await api.release()
        try await wait("New media did not finish restoring") { !controller.restoring }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.results.isEmpty); XCTAssertFalse(controller.busy); XCTAssertNil(controller.error)
    }

    func testImportCopiesCommentContentWithoutKeepingFileAccess() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "comments.xml")
        try Data(#"<i><d p="0,1,25,16777215">Synthetic imported comment</d></i>"#.utf8).write(to: file)
        let store = BulletCommentStore(directory: folder.appending(path: "saved"))
        let document = try await store.importFile(file)
        try FileManager.default.removeItem(at: file)
        let key = BulletCommentStore.key(for: URL(string: "https://video.example/video.mp4")!)
        try await store.save(SavedBulletComments(feeds: [BulletFeed(id: "file", name: "Test", source: "Imported file", document: document)]), key: key)
        let restored = try await store.load(key)
        XCTAssertEqual(restored.feeds[0].document.comments[0].text, "Synthetic imported comment")
    }

    @MainActor
    func testOverlayOnNativeAndMPVPlayback() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        for ext in ["mp4", "mkv"] {
            let comments = BulletCommentController(store: BulletCommentStore(directory: folder.appending(path: ext)))
            let player = PlayerModel(bulletComments: comments)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: PlayerView(model: player))
            window.rootViewController = controller; window.makeKeyAndVisible()
            func findSurface(_ view: UIView) -> VideoSurfaceView? {
                if let surface = view as? VideoSurfaceView { return surface }
                return view.subviews.compactMap(findSurface).first
            }
            try await wait("Player surface was not created") { findSurface(controller.view) != nil }
            let surface = try XCTUnwrap(findSurface(controller.view))
            let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback", withExtension: ext))
            player.add([media])
            try await wait("\(ext) did not load") { player.duration > 10 && !player.loading && !comments.restoring }
            player.setPaused(true)
            try await wait("\(ext) did not pause") { player.paused }
            player.seek(to: 0.5)
            try await wait("\(ext) did not seek") { abs(player.position - 0.5) < 0.2 }
            let document = BulletDocument(comments: [BulletComment(id: "a", time: 0, text: "Synthetic source A", mode: .top),
                                                      BulletComment(id: "b", time: 6, text: "Later scene", mode: .top)])
            try comments.add(BulletFeed(id: "a", name: "Synthetic source A", source: "Imported file", document: document))
            try await wait("\(ext) overlay didn't render") { surface.bulletOverlay.visibleTexts.contains("Synthetic source A") }
            XCTAssertEqual(player.backend, ext == "mp4" ? .native : .mpv, "Comment rendering must not change engines")
            let start = surface.bulletOverlay.renderedTime
            try await Task.sleep(for: .milliseconds(400)); surface.bulletOverlay.render()
            XCTAssertEqual(surface.bulletOverlay.renderedTime, start, accuracy: 0.05)
            comments.setEnabled(false, id: "a")
            try await wait("Source filter did not hide comments") { surface.bulletOverlay.visibleTexts.isEmpty }
            comments.setEnabled(true, id: "a"); comments.setDelay(2, id: "a")
            try await Task.sleep(for: .milliseconds(100)); surface.bulletOverlay.render()
            XCTAssertTrue(surface.bulletOverlay.visibleTexts.isEmpty)
            player.seek(to: 2.5)
            try await wait("Delayed comment didn't follow seek") { surface.bulletOverlay.visibleTexts.contains("Synthetic source A") }
            player.setSpeed(2); player.setPaused(false)
            let position = player.position
            try await wait("\(ext) playback didn't advance at 2×") { player.position > position + 1 }
            XCTAssertEqual(surface.bulletOverlay.renderedTime, player.position, accuracy: 0.65)
            player.setPaused(true); try await wait("Playback didn't pause") { player.paused }
            player.seek(to: 8.5)
            try await wait("Later comment didn't follow seek") { surface.bulletOverlay.visibleTexts.contains("Later scene") }
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let capture = XCTAttachment(image: image)
            capture.name = "Bullet comments overlay \(ext)"; capture.lifetime = .keepAlways; add(capture)
            comments.setVisible(false)
            try await wait("Master visibility switch didn't hide overlay") { surface.bulletOverlay.isHidden }
            await comments.finishSaving()
            window.isHidden = true
        }
    }
}
