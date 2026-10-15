// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import CryptoKit
import Security

struct BulletProviderCredentials: Codable, Equatable {
    var appID = ""
    var appSecret = ""
    var configured: Bool { !appID.isEmpty && !appSecret.isEmpty }
}

enum BulletAccountStore {
    private static let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.local.anii.dandanplay", kSecAttrAccount as String: "application"]
    static func load() throws -> BulletProviderCredentials {
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return BulletProviderCredentials() }
        guard status == errSecSuccess else { throw BulletCommentError.keychain(status) }
        guard let data = result as? Data else { throw BulletCommentError.invalidResponse }
        return try JSONDecoder().decode(BulletProviderCredentials.self, from: data)
    }
    static func save(_ credentials: BulletProviderCredentials) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw BulletCommentError.keychain(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BulletCommentError.keychain(status) }
    }
}

struct BulletEpisode: Identifiable, Equatable, Codable {
    var id: Int64
    var title: String
    var episodeTitle: String
    var delay: Double = 0
    var duration: Double? = nil
    var exact = false
    var displayTitle: String { title + " · " + episodeTitle }
}

private final class BulletRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The client follows approved comment redirects itself, without signed headers.
        completionHandler(nil)
    }
}

/// Provider APIs accept metadata; no video bytes, directory names, or cloud URL tokens are sent.
actor DandanplayClient {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)
    private let credentials: BulletProviderCredentials
    private let fetch: Fetch
    private let now: () -> Date
    private var searches: [String: (Date, [BulletEpisode])] = [:]

    init(credentials: BulletProviderCredentials, now: @escaping () -> Date = Date.init, fetch: Fetch? = nil) {
        self.credentials = credentials; self.now = now
        if let fetch { self.fetch = fetch }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: configuration, delegate: BulletRedirectPolicy(), delegateQueue: nil)
            self.fetch = { request in
                let (bytes, response) = try await session.bytes(for: request)
                guard response.expectedContentLength <= BulletCommentParser.byteLimit else { throw BulletCommentError.tooLarge }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= BulletCommentParser.byteLimit { throw BulletCommentError.tooLarge }
                    data.append(byte)
                }
                return (data, response)
            }
        }
    }

    nonisolated static func allowedCommentURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["dandanplay.net", "dandanplay.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    nonisolated static func signature(appID: String, secret: String, timestamp: String, path: String) -> String {
        Data(SHA256.hash(data: Data((appID + timestamp + path + secret).utf8))).base64EncodedString()
    }

    func match(_ identity: BulletVideoIdentity, searchByTitle: Bool = false) async throws -> [BulletEpisode] {
        guard credentials.configured else { throw BulletCommentError.setup }
        let title: String
        if let url = URL(string: identity.title), url.scheme != nil, url.host != nil { title = url.deletingPathExtension().lastPathComponent }
        else { title = BulletVideoIdentity.cleanTitle((identity.title as NSString).lastPathComponent) }
        guard !title.isEmpty else { throw BulletCommentError.invalidResponse }
        let duration = identity.duration.isFinite ? Int(min(Double(Int32.max), max(0, identity.duration))) : 0
        let key = "\(searchByTitle):\(title):\(duration)"
        if let cached = searches[key], now().timeIntervalSince(cached.0) < 6 * 3600 { return cached.1 }
        let results: [BulletEpisode]
        if searchByTitle {
            let request = try signed(path: "/api/v2/search/episodes", query: [URLQueryItem(name: "anime", value: title), URLQueryItem(name: "v2", value: "true")])
            let data = try await response(request, requiredField: "animes")
            let value = try JSONDecoder().decode(SearchResponse.self, from: data)
            results = (value.animes ?? []).flatMap { anime in
                (anime.episodes ?? []).map { BulletEpisode(id: $0.episodeId, title: anime.animeTitle ?? "Unknown title", episodeTitle: $0.episodeTitle ?? "Episode") }
            }
        } else {
            var request = try signed(path: "/api/v2/match")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(MatchRequest(fileName: title, videoDuration: duration))
            let value = try JSONDecoder().decode(MatchResponse.self, from: try await response(request, requiredField: "matches"))
            results = (value.matches ?? []).map {
                BulletEpisode(id: $0.episodeId, title: $0.animeTitle ?? "Unknown title", episodeTitle: $0.episodeTitle ?? "Episode",
                              delay: $0.shift?.isFinite == true ? $0.shift! : 0, exact: value.isMatched == true)
            }
        }
        guard results.count <= 10_000 else { throw BulletCommentError.tooLarge }
        let ranked = results.enumerated().filter { $0.element.id > 0 }.sorted {
            let lhs = identity.score(title: $0.element.displayTitle, duration: $0.element.duration)
            let rhs = identity.score(title: $1.element.displayTitle, duration: $1.element.duration)
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
        var seen: Set<Int64> = []
        let unique = ranked.filter { seen.insert($0.id).inserted }
        if searches.count >= 30 { searches.removeAll() }
        searches[key] = (now(), unique)
        return unique
    }

    func comments(episodeID: Int64, related: Bool) async throws -> BulletDocument {
        guard episodeID > 0 else { throw BulletCommentError.invalidResponse }
        let request = try signed(path: "/api/v2/comment/\(episodeID)", query: [URLQueryItem(name: "withRelated", value: related ? "true" : "false")])
        return try BulletCommentParser.parse(try await response(request, allowCommentRedirect: true))
    }

    private func signed(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard credentials.configured else { throw BulletCommentError.setup }
        var components = URLComponents(string: "https://api.dandanplay.net" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        let timestamp = String(Int(now().timeIntervalSince1970))
        request.setValue(credentials.appID, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(Self.signature(appID: credentials.appID, secret: credentials.appSecret, timestamp: timestamp, path: path), forHTTPHeaderField: "X-Signature")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func response(_ initial: URLRequest, allowCommentRedirect: Bool = false, requiredField: String? = nil) async throws -> Data {
        var request = initial
        for attempt in 0...3 {
            let (data, raw) = try await fetch(request)
            try Task.checkCancellation()
            guard data.count <= BulletCommentParser.byteLimit else { throw BulletCommentError.tooLarge }
            guard let http = raw as? HTTPURLResponse else { throw BulletCommentError.invalidResponse }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard allowCommentRedirect, attempt < 3, let location = http.value(forHTTPHeaderField: "Location"),
                      let url = URL(string: location, relativeTo: request.url)?.absoluteURL,
                      Self.allowedCommentURL(url) else { throw BulletCommentError.unsafeRedirect }
                request = URLRequest(url: url) // Signed headers and cookies never follow the redirect.
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw BulletCommentError.http(http.statusCode) }
            let status = try JSONDecoder().decode(ResponseStatus.self, from: data)
            if status.success == false { throw BulletCommentError.provider(status.errorMessage ?? "Request rejected by provider.") }
            if let requiredField {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object[requiredField] != nil else {
                    throw BulletCommentError.invalidResponse
                }
            }
            return data
        }
        throw BulletCommentError.unsafeRedirect
    }

    private struct ResponseStatus: Decodable { let success: Bool?; let errorMessage: String? }
    private struct MatchRequest: Encodable {
        let fileName: String
        let videoDuration: Int
        let fileSize: Int64 = 0
        let matchMode = "fileNameOnly"
    }
    private struct MatchResponse: Decodable { let isMatched: Bool?; let matches: [MatchItem]? }
    private struct MatchItem: Decodable { let episodeId: Int64; let animeTitle: String?; let episodeTitle: String?; let shift: Double? }
    private struct SearchResponse: Decodable { let animes: [Anime]? }
    private struct Anime: Decodable { let animeTitle: String?; let episodes: [Episode]? }
    private struct Episode: Decodable { let episodeId: Int64; let episodeTitle: String? }
}
