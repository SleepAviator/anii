// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import CoreGraphics

enum BulletCommentError: LocalizedError {
    case invalidFile, tooLarge, setup, invalidResponse, unsafeRedirect, http(Int), provider(String), keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Choose a Bilibili XML, Dandanplay JSON, or anii comment JSON file containing valid timed comments."
        case .tooLarge: return "Comment data is limited to 20 MB, 100,000 comments, and eight sources per video."
        case .setup: return "Enter your approved Dandanplay App ID and App Secret in Provider Setup."
        case .invalidResponse: return "The comment provider returned an incomplete response."
        case .unsafeRedirect: return "The provider redirected outside its supported HTTPS comment servers."
        case let .http(status): return "Comment request failed (HTTP \(status)). Check provider access or try again later."
        case let .provider(message): return "Dandanplay: \(message.prefix(240))"
        case let .keychain(status): return "Unable to access comment credentials in Keychain (\(status))."
        }
    }
}

enum BulletMode: String, Codable { case scroll, top, bottom }

struct BulletComment: Codable, Equatable, Identifiable {
    var id: String
    var time: Double
    var text: String
    var mode: BulletMode = .scroll
    var color: UInt32 = 0xFFFFFF
}

struct BulletDocument: Codable {
    var title: String?
    var duration: Double?
    var comments: [BulletComment]
    var ignoredCount = 0
}

struct BulletFeed: Codable, Identifiable {
    var id: String
    var name: String
    var source: String
    var enabled = true
    var delay = 0.0
    var document: BulletDocument
    var updatedAt = Date()
    var episodeID: Int64?
    var includesRelated = false
}

/// Importers retain only timed plain text. Advanced/scripted XML modes are not executed.
enum BulletCommentParser {
    static let byteLimit = 20 * 1024 * 1024
    static let countLimit = 100_000

    static func parse(_ data: Data) throws -> BulletDocument {
        guard data.count <= byteLimit else { throw BulletCommentError.tooLarge }
        guard !data.isEmpty else { throw BulletCommentError.invalidFile }
        let head = Data(data.prefix(512))
        let prefix = (xmlText(head) ?? String(decoding: head, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if prefix.hasPrefix("<") { return try xml(data) }
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = raw as? [String: Any]
        guard let rows = (object?["comments"] ?? raw) as? [Any], rows.count <= countLimit else {
            if let rows = object?["comments"] as? [Any], rows.count > countLimit { throw BulletCommentError.tooLarge }
            throw BulletCommentError.invalidFile
        }
        var comments: [BulletComment] = [], ignored = 0
        for (index, row) in rows.enumerated() {
            guard let row = row as? [String: Any] else { ignored += 1; continue }
            let value: BulletComment?
            if let parameters = row["p"] as? String, let text = row["m"] as? String {
                value = fromParameters(parameters, text: text, index: index, xml: false)
            } else if let time = number(row["time"]), let text = row["text"] as? String,
                      let mode = BulletMode(rawValue: row["mode"] as? String ?? "scroll") {
                let color: UInt32?
                if let hex = row["color"] as? String { color = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) }
                else if let number = number(row["color"]), number >= 0, number <= 0xFFFFFF { color = UInt32(number) }
                else { color = row["color"] == nil ? 0xFFFFFF : nil }
                value = color.flatMap { validated(time: time, text: text, mode: mode, color: $0, index: index) }
            } else { value = nil }
            if let value { comments.append(value) } else { ignored += 1 }
        }
        // A valid empty feed is useful for a newly created episode; corrupt nonempty data isn't.
        guard rows.isEmpty || !comments.isEmpty else { throw BulletCommentError.invalidFile }
        let duration = number(object?["duration"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return BulletDocument(title: (object?["title"] as? String).map { String($0.prefix(300)) },
                              duration: duration, comments: sorted(comments), ignoredCount: ignored)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    fileprivate static func fromParameters(_ parameters: String, text: String, index: Int, xml: Bool) -> BulletComment? {
        let parts = parameters.split(separator: ",", omittingEmptySubsequences: false)
        let colorIndex = xml ? 3 : 2
        guard parts.count > colorIndex, let time = Double(parts[0]), let modeNumber = Int(parts[1]),
              let color = UInt32(parts[colorIndex]) else { return nil }
        let mode: BulletMode
        switch modeNumber {
        case 1, 2, 3: mode = .scroll
        case 4: mode = .bottom
        case 5: mode = .top
        default: return nil
        }
        return validated(time: time, text: text, mode: mode, color: color, index: index)
    }

    private static func validated(time: Double, text: String, mode: BulletMode, color: UInt32, index: Int) -> BulletComment? {
        let text = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard time.isFinite, time >= 0, time <= 7 * 86400, color <= 0xFFFFFF, !text.isEmpty else { return nil }
        return BulletComment(id: String(index), time: time, text: String(text.prefix(500)), mode: mode, color: color)
    }

    private static func sorted(_ values: [BulletComment]) -> [BulletComment] {
        values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    private static func xmlText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0x3C, 0x00]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0x00, 0x3C]) { return String(data: data, encoding: .utf16BigEndian) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return nil }
        return text
    }

    private static func xml(_ data: Data) throws -> BulletDocument {
        // Reject DTD/entity declarations before parsing, including UTF-16 representations.
        let text = xmlText(data)
        guard let text, !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw BulletCommentError.invalidFile
        }
        let delegate = BulletXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.comments.isEmpty else {
            if delegate.overLimit { throw BulletCommentError.tooLarge }
            throw BulletCommentError.invalidFile
        }
        return BulletDocument(comments: sorted(delegate.comments), ignoredCount: delegate.ignored)
    }
}

private final class BulletXMLParser: NSObject, XMLParserDelegate {
    var comments: [BulletComment] = []
    var ignored = 0, rows = 0
    var overLimit = false
    private var parameters: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "d" {
            rows += 1
            if rows > BulletCommentParser.countLimit { overLimit = true; parser.abortParsing(); return }
            parameters = attributes["p"]; text = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if parameters != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "d" else { return }
        if let parameters, let comment = BulletCommentParser.fromParameters(parameters, text: text, index: rows, xml: true) {
            comments.append(comment)
        } else { ignored += 1 }
        parameters = nil; text = ""
    }
}

struct BulletVideoIdentity: Equatable {
    var title: String
    var duration: Double
    var episode: Int? { Self.capture(title, pattern: #"(?i)(?:\be|\bep|第)\s*(\d{1,3})(?:\b|集|话|話)"#) ?? Self.capture(title, pattern: #"(?i)s\d{1,2}[ ._-]*e(\d{1,3})"#) }
    var season: Int? { Self.capture(title, pattern: #"(?i)\bs(\d{1,2})[ ._-]*e"#) }

    static func cleanTitle(_ value: String) -> String {
        var result = value
        if ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts"].contains((result as NSString).pathExtension.lowercased()) {
            result = (result as NSString).deletingPathExtension
        }
        result = result.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:\d{3,4}p|4k|8k|x26[45]|h[ .]?26[45]|hevc|av1|aac|dts|bluray|web[ ._-]?dl|webrip|hdr|dv)\b.*$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capture(_ value: String, pattern: String) -> Int? {
        // Patterns are application constants; return the capture group, not a season prefix.
        let expression = try! NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }

    func score(title candidate: String, duration candidateDuration: Double?) -> Double {
        let other = BulletVideoIdentity(title: candidate, duration: candidateDuration ?? 0)
        if let episode, let target = other.episode, episode != target { return -1 }
        if let season, let target = other.season, season != target { return -1 }
        func normalize(_ title: String) -> String {
            Self.cleanTitle(title).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let first = normalize(title), second = normalize(candidate)
        var score = first == second ? 1.0 : (!first.isEmpty && (second.contains(first) || first.contains(second)) ? 0.8 : 0.3)
        if let candidateDuration, candidateDuration > 0, duration > 0 {
            score -= min(0.8, abs(candidateDuration - duration) / duration * 4)
        }
        return score
    }
}

/// A bounded clock prevents extrapolation from running ahead if an engine stops reporting time.
struct BulletPlaybackClock {
    private var position = 0.0, anchor = 0.0, rate = 0.0
    mutating func sample(position: Double, rate: Double, now: Double) {
        self.position = position.isFinite ? max(0, position) : 0
        self.rate = rate; anchor = now
    }
    mutating func setRate(_ value: Double, now: Double) {
        guard rate != value else { return }
        position = time(now: now); anchor = now; rate = value
    }
    func time(now: Double) -> Double { position + min(0.3, max(0, now - anchor)) * max(0, rate) }
}

struct BulletPlacement {
    let comment: BulletComment
    let frame: CGRect
}

/// One scheduler serves both engines. Work per tick is bounded by the visible time window.
struct BulletTimeline {
    var comments: [BulletComment]
    private var cursor = 0
    private var lastTime = -Double.infinity
    private var active: [(comment: BulletComment, start: Double, end: Double, width: CGFloat, lane: Int)] = []
    private var lanes: [(tailEntered: Double, end: Double, mode: BulletMode)] = []
    private var size = CGSize.zero
    init(comments: [BulletComment]) { self.comments = comments.sorted { $0.time < $1.time } }

    mutating func placements(at time: Double, size: CGSize, measure: (String) -> CGFloat) -> [BulletPlacement] {
        guard time.isFinite, size.width > 0, size.height > 0 else { return [] }
        let rows = max(3, min(10, Int(max(96, size.height * 0.7) / 32)))
        let velocity = max(80, size.width / 6)
        if size != self.size || time < lastTime || time - lastTime > 0.75 {
            self.size = size; active = []; lanes = Array(repeating: (-Double.infinity, -Double.infinity, .scroll), count: rows)
            var low = 0, high = comments.count
            while low < high { let mid = (low + high) / 2; if comments[mid].time < time - 12 { low = mid + 1 } else { high = mid } }
            cursor = low
        }
        active.removeAll { $0.end <= time }
        var inspected = 0
        while cursor < comments.count, comments[cursor].time <= time, inspected < 1000 {
            let comment = comments[cursor]; cursor += 1; inspected += 1
            let width = min(size.width * 0.9, max(20, measure(comment.text)))
            let end = comment.time + (comment.mode == .scroll ? Double((size.width + width) / velocity) : 4)
            let candidates: [Int] = comment.mode == .top ? [0] : comment.mode == .bottom ? [rows - 1] : Array(1..<(rows - 1))
            guard let lane = candidates.first(where: { lane in
                comment.mode == .scroll ? lanes[lane].tailEntered <= comment.time : lanes[lane].end <= comment.time
            }) else { continue }
            lanes[lane] = (comment.time + Double((width + 24) / velocity), end, comment.mode)
            if end > time, active.count < 48 { active.append((comment, comment.time, end, width, lane)) }
        }
        // Drop an excessive burst instead of replaying skipped comments on later frames.
        if cursor < comments.count, comments[cursor].time <= time {
            var low = cursor, high = comments.count
            while low < high {
                let mid = (low + high) / 2
                if comments[mid].time <= time { low = mid + 1 } else { high = mid }
            }
            cursor = low
        }
        lastTime = time
        return active.map { item in
            let x = item.comment.mode == .scroll ? size.width - CGFloat(time - item.start) * velocity : (size.width - item.width) / 2
            return BulletPlacement(comment: item.comment, frame: CGRect(x: x, y: 8 + CGFloat(item.lane) * 32, width: item.width, height: 30))
        }
    }
}
