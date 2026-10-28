// Orbit — a small Mac app that shows every running Claude Code session as a map
// around you, and lets you open (always in Terminal), rename, close, resume, or start sessions.
//
// Not affiliated with Anthropic. Claude and Claude Code are trademarks of Anthropic, PBC.
//
// Data sources (all written by Claude Code itself):
//   ~/.claude/sessions/<pid>.json          one file per running session
//   ~/.claude/projects/<folder>/<id>.jsonl  conversation transcripts (titles, folders)

import SwiftUI
import AppKit
import Darwin

// MARK: - Locations

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let sessions = URL(fileURLWithPath: home + "/.claude/sessions")
    static let projects = URL(fileURLWithPath: home + "/.claude/projects")

    static func abbreviate(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// Same folder, however it was spelled (symlinks like /tmp → /private/tmp resolved).
    static func canonical(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func folderName(_ p: String) -> String {
        p == home ? "~" : (p as NSString).lastPathComponent
    }
}

enum Identity {
    /// Shown in the center of the map. Override with: defaults write io.github.omarsinno54.orbit initials XY
    static var initials: String {
        if let custom = UserDefaults.standard.string(forKey: "initials"), !custom.isEmpty {
            return String(custom.prefix(3)).uppercased()
        }
        let words = NSFullUserName().split(separator: " ")
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? "ME" : String(letters).uppercased()
    }
}

// MARK: - Models

enum HostKind {
    case terminal, editor, other, none

    init(_ app: URL?) {
        guard let app else { self = .none; return }
        if app.lastPathComponent == "Terminal.app" { self = .terminal; return }
        let id = Bundle(url: app)?.bundleIdentifier?.lowercased() ?? ""
        let name = app.lastPathComponent.lowercased()
        let editor = id.contains("vscode") || ["code", "cursor", "windsurf", "zed"].contains { name.contains($0) }
        self = editor ? .editor : .other
    }
}

struct LiveSession: Identifiable, Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let title: String
    let status: String
    let startedAt: Date
    let lastActive: Date
    let tty: String?
    let hostApp: URL?
    let hostKind: HostKind
    let transcript: URL?
    let titleIsCustom: Bool
    let version: String?
    let bridgeId: String?

    var id: String { "live:\(pid)" }
    var inTerminal: Bool { hostKind == .terminal }
    var hasTranscript: Bool { transcript != nil }

    var hostName: String {
        guard let h = hostApp else { return "Background" }
        let n = h.deletingPathExtension().lastPathComponent
        return n == "Visual Studio Code" ? "VS Code" : n
    }

    var hostSymbol: String {
        switch hostName {
        case "Terminal", "iTerm", "Ghostty", "Warp": return "terminal"
        case "Background": return "gearshape"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct PastSession: Identifiable, Equatable {
    let sessionId: String
    let cwd: String?
    let title: String
    let lastActive: Date

    var id: String { "past:\(sessionId)" }
    var folderExists: Bool {
        guard let cwd else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
    }
}

struct StatusStyle {
    let label: String
    let color: Color
    let active: Bool

    /// Fits on a map card.
    var shortLabel: String { label == "Running a command" ? "Running cmd" : label }

    init(_ raw: String) {
        switch raw.lowercased() {
        case "busy", "working", "running": (label, color, active) = ("Working", .green, true)
        case "shell": (label, color, active) = ("Running a command", .blue, true)
        case "idle": (label, color, active) = ("Idle", .gray, false)
        case "waiting", "permission", "needs_input", "input", "blocked":
            (label, color, active) = ("Needs you", .orange, false)
        default: (label, color, active) = (raw.isEmpty ? "Unknown" : raw.capitalized, .gray, false)
        }
    }
}

// MARK: - Process helpers

enum Proc {
    static func info(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var k = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &k, &size, nil, 0) == 0, size > 0 else { return nil }
        return k
    }

    /// Executable path. Falls back to the path recorded at launch, because Claude's
    /// auto-updater deletes old version binaries that long-running sessions still use.
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return launchPath(pid)
    }

    private static func launchPath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size // skip argc
        var end = start
        while end < size && buf[end] != 0 { end += 1 }
        return end > start ? String(decoding: buf[start..<end], as: UTF8.self) : nil
    }

    static func startDate(_ k: kinfo_proc) -> Date {
        let tv = k.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    static func isZombie(_ k: kinfo_proc) -> Bool { Int32(k.kp_proc.p_stat) == SZOMB }

    static func tty(_ k: kinfo_proc) -> String? {
        let dev = k.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.hasPrefix("tty") ? "/dev/" + s : nil
    }

    /// The .app that ultimately hosts this process (Terminal, VS Code, …), found by walking up parents.
    static func hostApp(of pid: pid_t) -> URL? {
        var cur = pid
        for _ in 0..<15 {
            guard let k = info(cur) else { return nil }
            let ppid = k.kp_eproc.e_ppid
            if ppid <= 1 { return nil }
            if let p = path(ppid), let r = p.range(of: ".app/") {
                return URL(fileURLWithPath: String(p[..<r.lowerBound]) + ".app")
            }
            cur = ppid
        }
        return nil
    }

    /// True if `pid` is still the same Claude process we saw (guards against PID reuse).
    static func isSameClaude(_ pid: pid_t, startedNoLaterThan start: Date) -> Bool {
        guard let k = info(pid), !isZombie(k), let p = path(pid), p.lowercased().contains("claude") else { return false }
        return abs(startDate(k).timeIntervalSince(start)) < 1
    }
}

// MARK: - Transcript reading

struct TranscriptInfo { var title: String?; var cwd: String?; var titleIsCustom = false }

/// Numbers shown in a session's details panel (computed on demand from its transcript).
struct SessionStats: Equatable {
    var prompts = 0
    var workingTime: TimeInterval = 0
    var firstAt: Date?
    var model: String?
    var branch: String?
}

enum Transcript {
    static func read(_ url: URL) -> TranscriptInfo {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return TranscriptInfo() }
        return data.withUnsafeBytes { buf -> TranscriptInfo in
            var info = TranscriptInfo()
            // An empty custom title means "renamed back to automatic".
            if let d = lastRecord(buf, type: "custom-title"), let t = d["customTitle"] as? String,
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                info.title = t
                info.titleIsCustom = true
            }
            if info.title == nil, let d = lastRecord(buf, type: "ai-title") { info.title = d["aiTitle"] as? String }
            if info.title == nil, let d = lastRecord(buf, type: "last-prompt") { info.title = d["lastPrompt"] as? String }
            if info.title == nil { info.title = firstPrompt(buf) }
            for off in offsets(buf, "\"cwd\":\"", limit: 5) {
                if let d = record(buf, at: off), let c = d["cwd"] as? String { info.cwd = c; break }
            }
            info.title = info.title.map(clean).flatMap { $0.isEmpty ? nil : $0 }
            return info
        }
    }

    /// Walks the main conversation: prompt count, model, git branch, and an estimate of
    /// time spent working (from each prompt to the last message before the next prompt).
    static func stats(_ url: URL) -> SessionStats {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return SessionStats() }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? { s.flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) } }

        var st = SessionStats()
        var turnStart: Date?
        var turnEnd: Date?
        let markers = [Array("\"type\":\"user\"".utf8), Array("\"type\":\"assistant\"".utf8)]

        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count {
                let end = memchr(base + start, 0x0A, buf.count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? buf.count
                defer { start = end + 1 }
                let len = end - start
                guard len > 40 else { continue }
                let hit = markers.contains { m in m.withUnsafeBytes { memmem(base + start, len, $0.baseAddress, m.count) != nil } }
                guard hit,
                      let d = (try? JSONSerialization.jsonObject(with: Data(bytes: base + start, count: len))) as? [String: Any],
                      (d["isSidechain"] as? Bool) != true,
                      let ts = date(d["timestamp"] as? String) else { continue }
                let type = d["type"] as? String
                if st.firstAt == nil { st.firstAt = ts }
                if let b = d["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { st.branch = b }
                if type == "assistant", let m = (d["message"] as? [String: Any])?["model"] as? String, !m.hasPrefix("<") {
                    st.model = m
                }
                if type == "user", isPrompt(d) {
                    if let s = turnStart, let e = turnEnd { st.workingTime += max(0, e.timeIntervalSince(s)) }
                    st.prompts += 1
                    turnStart = ts
                    turnEnd = ts
                } else if turnStart != nil {
                    turnEnd = ts
                }
            }
        }
        if let s = turnStart, let e = turnEnd { st.workingTime += max(0, e.timeIntervalSince(s)) }
        return st
    }

    private static func isPrompt(_ d: [String: Any]) -> Bool {
        guard (d["isMeta"] as? Bool) != true, (d["isCompactSummary"] as? Bool) != true, d["toolUseResult"] == nil,
              let msg = d["message"] as? [String: Any] else { return false }
        if let s = msg["content"] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("Caveat:")
        }
        if let parts = msg["content"] as? [[String: Any]] {
            return parts.contains { $0["type"] as? String == "text" } && !parts.contains { $0["type"] as? String == "tool_result" }
        }
        return false
    }

    private static func clean(_ s: String) -> String {
        let flat = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 140 ? String(flat.prefix(139)) + "…" : flat
    }

    private static func offsets(_ buf: UnsafeRawBufferPointer, _ needle: String, limit: Int = .max) -> [Int] {
        let n = Array(needle.utf8)
        guard let base = buf.baseAddress, buf.count >= n.count else { return [] }
        var out: [Int] = []
        var pos = 0
        n.withUnsafeBytes { nb in
            while pos < buf.count, out.count < limit,
                  let hit = memmem(base + pos, buf.count - pos, nb.baseAddress, nb.count) {
                let off = base.distance(to: UnsafeRawPointer(hit))
                out.append(off)
                pos = off + n.count
            }
        }
        return out
    }

    private static func record(_ buf: UnsafeRawBufferPointer, at off: Int) -> [String: Any]? {
        var s = off
        while s > 0 && buf[s - 1] != 0x0A { s -= 1 }
        var e = off
        while e < buf.count && buf[e] != 0x0A { e += 1 }
        let line = Data(UnsafeRawBufferPointer(rebasing: buf[s..<e]))
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func lastRecord(_ buf: UnsafeRawBufferPointer, type: String) -> [String: Any]? {
        for off in offsets(buf, "\"type\":\"\(type)\"").reversed() {
            if let d = record(buf, at: off), d["type"] as? String == type { return d }
        }
        return nil
    }

    private static func firstPrompt(_ buf: UnsafeRawBufferPointer) -> String? {
        for off in offsets(buf, "\"type\":\"user\"", limit: 40) {
            guard let d = record(buf, at: off), d["type"] as? String == "user",
                  (d["isMeta"] as? Bool) != true, (d["isSidechain"] as? Bool) != true,
                  let msg = d["message"] as? [String: Any] else { continue }
            var text = msg["content"] as? String
            if text == nil, let parts = msg["content"] as? [[String: Any]] {
                text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
               !t.hasPrefix("<"), !t.hasPrefix("Caveat:") {
                return t
            }
        }
        return nil
    }
}

// MARK: - Scanner (runs on a background queue)

final class Scanner: @unchecked Sendable { // only used on one serial queue
    struct Entry { let url: URL; let mtime: Date }
    private var cache: [String: (mtime: Date, readAt: Date, info: TranscriptInfo)] = [:]
    private(set) var lastLiveIds: Set<String> = []

    /// sessionId -> newest transcript file
    func index() -> [String: Entry] {
        var out: [String: Entry] = [:]
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return out }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let sid = f.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: sid) != nil else { continue }
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let existing = out[sid], existing.mtime >= m { continue }
                out[sid] = Entry(url: f, mtime: m)
            }
        }
        return out
    }

    func forget(_ path: String) { cache[path] = nil }

    /// Transcript info, re-read at most every 15s while a file keeps changing.
    func info(_ e: Entry) -> TranscriptInfo {
        if let c = cache[e.url.path], c.mtime == e.mtime || Date().timeIntervalSince(c.readAt) < 15 { return c.info }
        let i = Transcript.read(e.url)
        cache[e.url.path] = (e.mtime, Date(), i)
        return i
    }

    func live(index: [String: Entry]) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (d["pid"] as? NSNumber)?.int32Value,
                  let sid = d["sessionId"] as? String,
                  let k = Proc.info(pid), !Proc.isZombie(k),
                  let exe = Proc.path(pid), exe.lowercased().contains("claude") else { continue }

            let procStart = Proc.startDate(k)
            let startedAt = (d["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? procStart
            if startedAt < procStart.addingTimeInterval(-120) { continue } // stale file, PID reused

            let entry = index[sid]
            let tinfo = entry.map(info)
            let host = Proc.hostApp(of: pid)
            let name = d["name"] as? String ?? String(sid.prefix(8))
            let stamps = [d["statusUpdatedAt"], d["updatedAt"]].compactMap { ($0 as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            let lastActive = (stamps + [entry?.mtime ?? startedAt]).max() ?? startedAt

            out.append(LiveSession(
                pid: pid, sessionId: sid,
                cwd: d["cwd"] as? String ?? tinfo?.cwd ?? Paths.home,
                title: tinfo?.title ?? name,
                status: d["status"] as? String ?? "",
                startedAt: procStart, lastActive: lastActive,
                tty: Proc.tty(k), hostApp: host, hostKind: HostKind(host),
                transcript: entry?.url, titleIsCustom: tinfo?.titleIsCustom ?? false,
                version: d["version"] as? String,
                bridgeId: d["bridgeSessionId"] as? String))
        }
        out.sort { $0.startedAt > $1.startedAt }
        lastLiveIds = Set(out.map(\.sessionId))
        return out
    }

    func recent(index: [String: Entry], excluding: Set<String>, limit: Int = 40) -> [PastSession] {
        var out: [PastSession] = []
        for (sid, e) in index.filter({ !excluding.contains($0.key) }).sorted(by: { $0.value.mtime > $1.value.mtime }) {
            if out.count >= limit { break }
            let i = info(e)
            guard let t = i.title else { continue }
            out.append(PastSession(sessionId: sid, cwd: i.cwd, title: t, lastActive: e.mtime))
        }
        return out
    }
}

// MARK: - Demo mode (`-demo YES`): sample sessions for screenshots; all actions are disabled

enum Demo {
    static let isOn = UserDefaults.standard.bool(forKey: "demo")

    private static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    private static let vscode = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")

    static func sessions() -> [LiveSession] {
        let now = Date()
        func make(_ pid: Int32, _ title: String, _ folder: String, _ status: String, _ app: URL,
                  startedHoursAgo: Double, activeMinutesAgo: Double) -> LiveSession {
            LiveSession(pid: pid, sessionId: UUID().uuidString.lowercased(), cwd: Paths.home + "/code/" + folder,
                        title: title, status: status,
                        startedAt: now.addingTimeInterval(-startedHoursAgo * 3600),
                        lastActive: now.addingTimeInterval(-activeMinutesAgo * 60),
                        tty: app == terminal ? "/dev/ttys00\(pid % 10)" : nil, hostApp: app, hostKind: HostKind(app),
                        transcript: URL(fileURLWithPath: "/dev/null"), titleIsCustom: false,
                        version: "2.1.311", bridgeId: nil)
        }
        return [
            make(90001, "Refactor auth middleware", "api-server", "busy", terminal, startedHoursAgo: 2.5, activeMinutesAgo: 0),
            make(90002, "Fix flaky checkout tests", "storefront", "shell", terminal, startedHoursAgo: 5, activeMinutesAgo: 0),
            make(90003, "Migration for the orders table", "storefront", "idle", vscode, startedHoursAgo: 26, activeMinutesAgo: 40),
            make(90004, "Draft release notes for v2.3", "docs", "idle", terminal, startedHoursAgo: 49, activeMinutesAgo: 180),
            make(90005, "Investigate memory leak in worker", "jobs", "busy", vscode, startedHoursAgo: 1, activeMinutesAgo: 0),
            make(90006, "Speed up CI caching", "infra", "idle", terminal, startedHoursAgo: 72, activeMinutesAgo: 1500),
        ]
    }

    static func recent() -> [PastSession] {
        let now = Date()
        return [
            ("Add dark mode to settings page", "storefront", 3.0),
            ("Rate limiter for public API", "api-server", 20.0),
            ("Postgres upgrade plan", "infra", 50.0),
        ].map { PastSession(sessionId: UUID().uuidString.lowercased(), cwd: Paths.home + "/code/" + $0.1,
                            title: $0.0, lastActive: now.addingTimeInterval(-$0.2 * 3600)) }
    }

    static let centers: [Center] = [
        .main,
        Center(id: "demo-backend", name: "Backend", color: RGB.presets[2]),
        Center(id: "demo-web", name: "Web", color: RGB.presets[5]),
    ]

    static func assignments(for sessions: [LiveSession]) -> [String: String] {
        var out: [String: String] = [:]
        for s in sessions {
            switch Paths.folderName(s.cwd) {
            case "api-server", "jobs": out[s.sessionId] = "demo-backend"
            case "storefront": out[s.sessionId] = "demo-web"
            default: break
            }
        }
        return out
    }

    static func stats(for s: LiveSession) -> SessionStats {
        let hours = Date().timeIntervalSince(s.startedAt) / 3600
        return SessionStats(prompts: max(1, Int(hours * 3)), workingTime: hours * 3600 * 0.35,
                            firstAt: s.startedAt.addingTimeInterval(20), model: "claude-opus-5-5", branch: "main")
    }
}

// MARK: - Centers (groups of sessions, each drawn as its own orbit)

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemIndigo
        (r, g, b) = (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var darker: Color { Color(red: r * 0.55, green: g * 0.55, blue: b * 0.62) }

    static let indigo = RGB(r: 0.42, g: 0.40, b: 0.95)
    static let presets: [RGB] = [
        indigo,
        RGB(r: 0.20, g: 0.52, b: 0.98),   // blue
        RGB(r: 0.16, g: 0.70, b: 0.72),   // teal
        RGB(r: 0.24, g: 0.72, b: 0.40),   // green
        RGB(r: 0.93, g: 0.72, b: 0.14),   // yellow
        RGB(r: 0.98, g: 0.55, b: 0.20),   // orange
        RGB(r: 0.93, g: 0.30, b: 0.32),   // red
        RGB(r: 0.90, g: 0.36, b: 0.66),   // pink
        RGB(r: 0.56, g: 0.58, b: 0.62),   // gray
    ]
}

struct Center: Codable, Identifiable, Equatable {
    static let mainId = "main"

    var id: String
    var name: String
    var color: RGB

    var isMain: Bool { id == Self.mainId }
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (isMain ? Identity.initials : "Untitled") : n
    }

    static let main = Center(id: mainId, name: "", color: .indigo)
}

/// Saved in the app's preferences: the list of centers and which session belongs to which.
enum GroupStore {
    private static let centersKey = "centers.v1"
    private static let assignmentsKey = "assignments.v1"

    static func loadCenters() -> [Center] {
        let saved = UserDefaults.standard.data(forKey: centersKey)
            .flatMap { try? JSONDecoder().decode([Center].self, from: $0) } ?? []
        return [saved.first(where: \.isMain) ?? .main] + saved.filter { !$0.isMain }
    }

    static func loadAssignments() -> [String: String] {
        UserDefaults.standard.data(forKey: assignmentsKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func save(_ centers: [Center], _ assignments: [String: String]) {
        guard !Demo.isOn else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(centers), forKey: centersKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(assignments), forKey: assignmentsKey)
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var live: [LiveSession] = []
    @Published var recent: [PastSession] = []
    @Published var loaded = false
    @Published private(set) var centers: [Center] = GroupStore.loadCenters()
    @Published private(set) var assignments: [String: String] = GroupStore.loadAssignments()

    /// New sessions started from a center: the next session that appears in that folder joins it.
    private var expected: [(folder: String, after: Date, center: String)] = []

    private let scanner = Scanner()
    private let queue = DispatchQueue(label: "orbit.scan", qos: .userInitiated)
    private var timer: Timer?
    private var ticks = 0
    private var scanning = false

    func start() {
        guard timer == nil else { return }
        if Demo.isOn {
            live = Demo.sessions()
            recent = Demo.recent()
            centers = Demo.centers
            assignments = Demo.assignments(for: live)
            loaded = true
            return
        }
        refresh(includeRecent: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ticks += 1
                self.refresh(includeRecent: self.ticks % 5 == 0)
            }
        }
    }

    func refresh(includeRecent: Bool) {
        if scanning { return }
        scanning = true
        let scanner = self.scanner
        queue.async {
            let before = scanner.lastLiveIds
            let idx = scanner.index()
            let live = scanner.live(index: idx)
            let liveIds = Set(live.map(\.sessionId))
            let recent = (includeRecent || liveIds != before) ? scanner.recent(index: idx, excluding: liveIds) : nil
            DispatchQueue.main.async {
                self.scanning = false
                if self.live != live { self.live = live }
                if let recent, self.recent != recent { self.recent = recent }
                self.loaded = true
                self.claimExpectedSessions()
            }
        }
    }

    /// Re-read a transcript right away (e.g. after renaming), skipping the cache.
    func transcriptChanged(_ url: URL) {
        let scanner = self.scanner
        queue.async { scanner.forget(url.path) }
        refreshSoon()
    }

    func refreshSoon() {
        for delay in [0.5, 1.5, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh(includeRecent: true) }
        }
    }

    // MARK: centers

    func centerId(for s: LiveSession) -> String {
        if let c = assignments[s.sessionId], centers.contains(where: { $0.id == c }) { return c }
        return Center.mainId
    }

    func center(_ id: String) -> Center? { centers.first { $0.id == id } }

    func assign(_ sessionIds: [String], to centerId: String) {
        for id in sessionIds { assignments[id] = centerId == Center.mainId ? nil : centerId }
        GroupStore.save(centers, assignments)
    }

    /// Adds a center with the next unused preset colour and returns its id.
    @discardableResult
    func addCenter() -> String {
        let used = Set(centers.map(\.color))
        let color = RGB.presets.first { !used.contains($0) } ?? RGB.presets[centers.count % RGB.presets.count]
        let c = Center(id: UUID().uuidString, name: "New Center", color: color)
        centers.append(c)
        GroupStore.save(centers, assignments)
        return c.id
    }

    func update(_ c: Center) {
        guard let i = centers.firstIndex(where: { $0.id == c.id }), centers[i] != c else { return }
        centers[i] = c
        GroupStore.save(centers, assignments)
    }

    /// Removes a center; its sessions go back to the main one.
    func deleteCenter(_ id: String) {
        guard id != Center.mainId else { return }
        centers.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        GroupStore.save(centers, assignments)
    }

    // MARK: starting sessions

    func startSession(in folder: String, center: String?) {
        Actions.newSession(in: folder)
        if let center, center != Center.mainId {
            expected.append((Paths.canonical(folder), Date(), center))
        }
        refreshSoon()
    }

    func startSessionPickingFolder(center: String?) {
        if let folder = Actions.chooseFolder() { startSession(in: folder, center: center) }
    }

    private func claimExpectedSessions() {
        expected.removeAll { Date().timeIntervalSince($0.after) > 180 }
        guard !expected.isEmpty else { return }
        for i in expected.indices.reversed() {
            let e = expected[i]
            if let s = live.first(where: { assignments[$0.sessionId] == nil
                                             && $0.startedAt >= e.after.addingTimeInterval(-5)
                                             && Paths.canonical($0.cwd) == e.folder }) {
                assignments[s.sessionId] = e.center
                expected.remove(at: i)
                GroupStore.save(centers, assignments)
            }
        }
    }
}

// MARK: - Actions

@MainActor
enum Actions {
    /// Brings a Terminal-hosted session's tab to the front.
    static func focus(_ s: LiveSession) {
        if Demo.isOn { NSSound.beep(); return }
        if let tty = s.tty, runAppleScript(focusTerminalScript(tty: tty))?.booleanValue == true { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Stops a session running somewhere else (e.g. VS Code) and reopens the same
    /// conversation in a new Terminal window. A session can't run in two places at once.
    static func moveToTerminal(_ s: LiveSession) {
        if Demo.isOn { NSSound.beep(); return }
        let pid = s.pid, cwd = s.cwd
        let command = s.hasTranscript ? "claude --resume \(s.sessionId)" : "claude"
        // Make sure we're allowed to drive Terminal before stopping anything,
        // so a blocked permission never leaves the session stopped and not reopened.
        guard runAppleScript("tell application \"Terminal\" to count windows") != nil else { return }
        guard let k = Proc.info(pid), let exe = Proc.path(pid), exe.lowercased().contains("claude") else {
            runInTerminal(cd: cwd, command: command)   // already gone: just reopen it
            return
        }
        let start = Proc.startDate(k)
        kill(pid, SIGTERM)
        DispatchQueue.global().async {
            var waited = 0.0
            while Proc.isSameClaude(pid, startedNoLaterThan: start), waited < 8 {
                usleep(200_000)
                waited += 0.2
            }
            if Proc.isSameClaude(pid, startedNoLaterThan: start) {
                kill(pid, SIGKILL)
                usleep(300_000)
            }
            Task { @MainActor in runInTerminal(cd: cwd, command: command) }
        }
    }

    /// Asks Claude to exit (SIGTERM). The transcript is already on disk, so it can be resumed.
    static func close(_ s: LiveSession) {
        if Demo.isOn { NSSound.beep(); return }
        let pid = s.pid
        guard let k = Proc.info(pid), let p = Proc.path(pid), p.lowercased().contains("claude") else { return }
        let start = Proc.startDate(k)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if Proc.isSameClaude(pid, startedNoLaterThan: start) { kill(pid, SIGKILL) }
        }
    }

    static func resume(_ p: PastSession) {
        runInTerminal(cd: p.cwd, command: "claude --resume \(p.sessionId)")
    }

    static func newSession(in dir: String) {
        runInTerminal(cd: dir, command: "claude")
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude Here"
        panel.message = "Choose the folder for the new Claude session"
        panel.directoryURL = URL(fileURLWithPath: Paths.home)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: helpers

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func asString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func focusTerminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(asString(tty)) then
                        if miniaturized of w then set miniaturized of w to false
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func runInTerminal(cd: String?, command: String) {
        if Demo.isOn { NSSound.beep(); return }
        var cmd = command
        if let cd { cmd = "cd \(shellQuote(cd)) && \(command)" }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
        let script = wasRunning ? """
            tell application "Terminal"
                do script \(asString(cmd))
                activate
            end tell
            """ : """
            tell application "Terminal"
                activate
                repeat 30 times
                    if (count of windows) > 0 then exit repeat
                    delay 0.1
                end repeat
                if (count of windows) > 0 then
                    do script \(asString(cmd)) in window 1
                else
                    do script \(asString(cmd))
                end if
            end tell
            """
        _ = runAppleScript(script)
    }

    @discardableResult
    /// Runs a script; returns nil (after telling the user why) if it failed.
    private static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            let alert = NSAlert()
            if code == -1743 || code == -1744 {
                alert.messageText = "Allow Orbit to control Terminal"
                alert.informativeText = "macOS blocked the request. Turn on Terminal for Orbit in System Settings → Privacy & Security → Automation, then try again."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            } else if code != -128 { // -128 = user cancelled
                alert.messageText = "Couldn't talk to Terminal"
                alert.informativeText = (err[NSAppleScript.errorMessage] as? String) ?? "Unknown error \(code)"
                alert.runModal()
            }
            return nil
        }
        return result
    }
}

// MARK: - Formatting

enum Fmt {
    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ d: Date) -> String {
        Date().timeIntervalSince(d) < 60 ? "just now" : rel.localizedString(for: d, relativeTo: Date())
    }

    private static let span: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()

    static func duration(_ t: TimeInterval) -> String {
        t < 60 ? "\(max(0, Int(t)))s" : (span.string(from: t) ?? "—")
    }

    static func when(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Renaming

enum TitleWriter {
    /// Writes a title the same way Claude Code's /rename does: a `custom-title` line appended
    /// to the transcript, plus `<session-id>/custom-title.json` beside it. Empty = automatic title.
    static func setTitle(_ title: String, sessionId: String, transcript: URL) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ["type": "custom-title", "customTitle": clean, "sessionId": sessionId]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)

        // Never glue our line onto an unfinished one.
        let reader = try FileHandle(forReadingFrom: transcript)
        let size = try reader.seekToEnd()
        if size > 0 {
            try reader.seek(toOffset: size - 1)
            if reader.readData(ofLength: 1).first != 0x0A { line.insert(0x0A, at: 0) }
        }
        try reader.close()

        // One O_APPEND write, so it can't interleave with Claude's own appends.
        let fd = open(transcript.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let dir = transcript.deletingLastPathComponent().appendingPathComponent(sessionId)
        let sidecar = dir.appendingPathComponent("custom-title.json")
        if clean.isEmpty {
            try? FileManager.default.removeItem(at: sidecar)
        } else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let body = try JSONSerialization.data(withJSONObject: ["customTitle": clean], options: [.withoutEscapingSlashes])
            try body.write(to: sidecar, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
        }
    }
}

// MARK: - Map layout

/// One center on the map, in view coordinates.
struct PlacedGroup {
    let center: Center
    let sessions: [LiveSession]
    let origin: CGPoint
    let radius: CGFloat
    let points: [CGPoint]
}

/// Each center gets its own ring of cards (spread until nothing overlaps) inside a circle.
/// The circles are laid out in rows, choosing the row length that lets the map be drawn
/// the largest, then everything is scaled down to fit the window if needed.
struct MapLayout {
    static let card = CGSize(width: 214, height: 72)
    static let hub: CGFloat = 116

    let groups: [PlacedGroup]
    let scale: CGFloat

    /// Card offsets around a hub and the radius of the circle around them (unscaled).
    static func ring(_ n: Int) -> (offsets: [CGPoint], radius: CGFloat) {
        guard n > 0 else { return ([], hub / 2 + 46) }
        let cw = card.width, ch = card.height, gap: CGFloat = 14
        let angles = (0..<n).map { -CGFloat.pi / 2 + 2 * .pi * CGFloat($0) / CGFloat(n) }
        func place(_ r: CGFloat) -> [CGPoint] { angles.map { CGPoint(x: r * cos($0), y: r * sin($0)) } }
        func crowded(_ p: [CGPoint]) -> Bool {
            for i in p.indices {
                // Keep a visible stretch of line between the hub and every card.
                if abs(p[i].x) < (cw + hub) / 2 + 48, abs(p[i].y) < (ch + hub) / 2 + 48 { return true }
                for j in p.indices where j > i {
                    if abs(p[i].x - p[j].x) < cw + gap, abs(p[i].y - p[j].y) < ch + gap { return true }
                }
            }
            return false
        }
        var r = hub / 2 + ch / 2 + 48
        var p = place(r)
        while crowded(p), r < 4000 { r *= 1.05; p = place(r) }
        let radius = p.map { hypot(abs($0.x) + cw / 2, abs($0.y) + ch / 2) }.max()! + 22
        return (p, radius)
    }

    init(groups input: [(Center, [LiveSession])], in size: CGSize) {
        let rings = input.map { Self.ring($0.1.count) }
        let diam = rings.map { $0.radius * 2 }
        let gap: CGFloat = 36, pad: CGFloat = 20
        let count = max(1, input.count)

        func rowWidth(_ row: [Int]) -> CGFloat {
            var w: CGFloat = gap * CGFloat(row.count - 1)
            for i in row { w += diam[i] }
            return w
        }
        func rowHeight(_ row: [Int]) -> CGFloat {
            var h: CGFloat = 0
            for i in row { h = max(h, diam[i]) }
            return h
        }
        func split(_ cols: Int) -> [[Int]] {
            stride(from: 0, to: input.count, by: cols).map { Array($0..<min($0 + cols, input.count)) }
        }
        func height(_ rows: [[Int]]) -> CGFloat {
            var h: CGFloat = gap * CGFloat(max(0, rows.count - 1))
            for r in rows { h += rowHeight(r) }
            return h
        }

        var best: (scale: CGFloat, rows: [[Int]])?
        for cols in 1...count {
            let rows = split(cols)
            let w = rows.map(rowWidth).max() ?? 1
            let h = height(rows)
            let s: CGFloat = min(1, (size.width - 2 * pad) / w, (size.height - 2 * pad) / h)
            if best == nil || s > best!.scale + 0.001 { best = (s, rows) }
        }
        let s = max(0.2, best?.scale ?? 1)
        let rows = best?.rows ?? []

        // Unscaled positions, centred on the origin.
        let rowWidths = rows.map(rowWidth)
        let rowHeights = rows.map(rowHeight)
        let totalH = height(rows)
        var centers = [CGPoint](repeating: .zero, count: input.count)
        var y = -totalH / 2
        for (r, row) in rows.enumerated() {
            var x = -rowWidths[r] / 2
            for i in row {
                centers[i] = CGPoint(x: x + diam[i] / 2, y: y + rowHeights[r] / 2)
                x += diam[i] + gap
            }
            y += rowHeights[r] + gap
        }

        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        scale = s
        groups = input.indices.map { i in
            let o = CGPoint(x: mid.x + centers[i].x * s, y: mid.y + centers[i].y * s)
            return PlacedGroup(center: input[i].0, sessions: input[i].1, origin: o,
                               radius: rings[i].radius * s,
                               points: rings[i].offsets.map { CGPoint(x: o.x + $0.x * s, y: o.y + $0.y * s) })
        }
    }
}

// MARK: - Map pieces

struct Edge {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let active: Bool
    let emphasized: Bool
    let dimmed: Bool
}

struct EdgesLayer: View {
    let edges: [Edge]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !edges.contains { $0.active })) { tl in
            Canvas { ctx, _ in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600)
                let phase = CGFloat(t) * -22
                for e in edges {
                    var path = Path()
                    path.move(to: e.from)
                    path.addLine(to: e.to)
                    let opacity = e.dimmed ? 0.12 : (e.emphasized ? 1 : (e.active ? 0.85 : 0.4))
                    let width: CGFloat = e.emphasized ? 3 : 2
                    if e.active {
                        ctx.stroke(path, with: .color(e.color.opacity(opacity * 0.25)),
                                   style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
                        ctx.stroke(path, with: .color(e.color.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [8, 7], dashPhase: phase))
                    } else {
                        ctx.stroke(path, with: .color(e.color.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)),
                             with: .color(.primary.opacity(0.07)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// The nearly transparent circle behind a center and its sessions.
struct GroupBackdrop: View {
    let color: RGB
    let radius: CGFloat
    let targeted: Bool

    var body: some View {
        Circle()
            .fill(color.color.opacity(targeted ? 0.2 : 0.09))
            .overlay(Circle().strokeBorder(color.color.opacity(targeted ? 0.9 : 0.35), lineWidth: targeted ? 2.5 : 1.5))
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
    }
}

struct HubNode: View {
    let center: Center

    var body: some View {
        let name = center.displayName
        ZStack {
            Circle().fill(LinearGradient(colors: [center.color.color, center.color.darker],
                                         startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Text(name)
                .font(.system(size: name.count <= 3 ? 40 : 21, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.4)
                .padding(16)
        }
        .frame(width: MapLayout.hub, height: MapLayout.hub)
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
    }
}

/// Rename / recolour / delete a center. Shown as a sheet so the system colour panel can stay open.
struct CenterEditor: View {
    @EnvironmentObject var store: Store
    let centerId: String
    let onDone: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let c = store.center(centerId) {
            let count = store.live.filter { store.centerId(for: $0) == c.id }.count
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    HubNode(center: c).scaleEffect(0.42).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.isMain ? "Main center" : "Center").font(.headline)
                        Text("\(count) session\(count == 1 ? "" : "s") · drag cards onto a center to move them")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField(c.isMain ? Identity.initials : "Center name",
                              text: Binding(get: { c.name }, set: { var n = c; n.name = $0; store.update(n) }))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(onDone)
                    if c.isMain {
                        Text("Leave empty to show your initials.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 9) {
                        ForEach(RGB.presets, id: \.self) { p in
                            Button { var n = c; n.color = p; store.update(n) } label: {
                                Circle().fill(p.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-4)
                                                .opacity(p == c.color ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                            .help("Use this color")
                        }
                        Divider().frame(height: 20)
                        ColorPicker("Custom", selection: Binding(get: { c.color.color },
                                                                 set: { var n = c; n.color = RGB($0); store.update(n) }),
                                    supportsOpacity: false)
                            .labelsHidden()
                            .help("Pick any color")
                    }
                    Text("The circle behind the center uses this color, nearly transparent.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("New Session Here…") {
                        onDone()
                        DispatchQueue.main.async { store.startSessionPickingFolder(center: c.id) }
                    }
                    if !c.isMain {
                        Button("Delete Center", role: .destructive) {
                            store.deleteCenter(c.id)
                            onDone()
                        }
                        .help("Its sessions move back to the main center")
                    }
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
            .onAppear { if c.name == "New Center" { nameFocused = true } }
        }
    }
}

struct SessionNode: View {
    let s: LiveSession
    let emphasized: Bool

    var body: some View {
        let st = StatusStyle(s.status)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(st.color)
                    .symbolEffect(.pulse, isActive: st.active)
                Text(s.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Image(systemName: s.hostSymbol)
                Text(s.hostName)
                Text("·")
                Text(Paths.folderName(s.cwd)).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(st.shortLabel)
                    .foregroundStyle(st.color == .gray ? Color.secondary : st.color)
                    .layoutPriority(1)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 15)
        }
        .padding(.horizontal, 11)
        .frame(width: MapLayout.card.width, height: MapLayout.card.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                emphasized ? Color.accentColor : st.color.opacity(st.active ? 0.7 : 0.3),
                lineWidth: emphasized ? 2 : 1)
        )
        .shadow(color: .black.opacity(emphasized ? 0.28 : 0.14), radius: emphasized ? 12 : 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SessionDetail: View {
    @EnvironmentObject var store: Store
    let s: LiveSession
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var stats: SessionStats?
    @State private var editing = false
    @State private var draft = ""
    @State private var pendingTitle: String?   // shown until the next refresh picks the rename up
    @State private var saveError: String?
    @FocusState private var titleFocused: Bool

    private var shownTitle: String { pendingTitle ?? s.title }

    var body: some View {
        let st = StatusStyle(s.status)
        VStack(alignment: .leading, spacing: 14) {
            titleArea

            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(st.color)
                Text(st.label)
                Text("·").foregroundStyle(.secondary)
                Label(s.hostName, systemImage: s.hostSymbol)
                if let tty = s.tty { Text("(\((tty as NSString).lastPathComponent))").foregroundStyle(.secondary) }
            }
            .font(.callout)

            TimelineView(.periodic(from: .now, by: 1)) { _ in infoGrid }

            if !s.inTerminal {
                Text(s.hasTranscript
                     ? "This runs in \(s.hostName). Moving it stops it there and resumes the same conversation in a new Terminal window."
                     : "This runs in \(s.hostName) and has no conversation yet. Moving it stops it there and starts a fresh session in Terminal in the same folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(s.inTerminal ? "Open in Terminal" : "Move to Terminal", action: onOpen)
                    .keyboardShortcut(editing ? nil : .defaultAction)
                Button("Close…", action: onClose)
                Spacer()
                Menu {
                    Button("New Session in This Folder") { store.startSession(in: s.cwd, center: store.centerId(for: s)) }
                    if let b = s.bridgeId, let url = URL(string: "https://claude.ai/code/\(b)") {
                        Button("Open on claude.ai") { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Copy Resume Command") {
                        Actions.copy("cd \(Actions.shellQuote(s.cwd)) && claude --resume \(s.sessionId)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(18)
        .frame(width: 450)
        .task(id: Int(s.lastActive.timeIntervalSince1970 / 15)) { // at most every 15s while busy
            if Demo.isOn { stats = Demo.stats(for: s); return }
            guard let url = s.transcript else { return }
            stats = await Task.detached(priority: .userInitiated) { Transcript.stats(url) }.value
        }
        .onChange(of: s.title) { pendingTitle = nil }
    }

    // MARK: title

    @ViewBuilder private var titleArea: some View {
        if editing {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Session title", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($titleFocused)
                    .onSubmit(save)
                    .onExitCommand { editing = false }
                HStack {
                    Text("Leave empty to go back to the automatic title.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shownTitle)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    draft = s.titleIsCustom ? shownTitle : ""
                    saveError = nil
                    editing = true
                    DispatchQueue.main.async { titleFocused = true }
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(!s.hasTranscript)
                .help(s.hasTranscript ? "Rename this session" : "You can rename it once the session has a conversation")
            }
        }
    }

    private func save() {
        if Demo.isOn { pendingTitle = draft; editing = false; return }
        guard let url = s.transcript else { return }
        do {
            try TitleWriter.setTitle(draft, sessionId: s.sessionId, transcript: url)
            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingTitle = t.isEmpty ? nil : t
            editing = false
            store.transcriptChanged(url)
        } catch {
            saveError = "Couldn't save the title: \(error.localizedDescription)"
        }
    }

    // MARK: info

    /// True when this run picked up a conversation that started earlier.
    private var resumed: Bool {
        guard let first = stats?.firstAt else { return false }
        return s.startedAt.timeIntervalSince(first) > 120
    }

    private var infoGrid: some View {
        let now = Date()
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            row("Session ID") {
                HStack(spacing: 6) {
                    Text(s.sessionId).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).fixedSize()
                    copyButton(s.sessionId)
                }
            }
            row("Center") {
                Picker("Center", selection: Binding(get: { store.centerId(for: s) },
                                                    set: { store.assign([s.sessionId], to: $0) })) {
                    ForEach(store.centers) { c in
                        Label { Text(c.displayName) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(c.color.color)
                        }
                        .tag(c.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            row("Folder") {
                HStack(spacing: 6) {
                    Text(Paths.abbreviate(s.cwd)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Button { Actions.reveal(s.cwd) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
            row("Started") { Text("\(Fmt.when(s.startedAt)) · \(Fmt.ago(s.startedAt))") }
            if resumed, let first = stats?.firstAt {
                row("Conversation") { Text("began \(Fmt.when(first)) · resumed since") }
            }
            row("Running for") { Text(Fmt.duration(now.timeIntervalSince(s.startedAt))).monospacedDigit() }
            row("Time working") {
                if let stats {
                    Text(stats.prompts == 0 ? "No prompts yet"
                         : "≈ \(Fmt.duration(stats.workingTime)) across \(stats.prompts) prompt\(stats.prompts == 1 ? "" : "s")"
                           + (resumed ? " (whole conversation)" : ""))
                } else {
                    Text(s.hasTranscript ? "Calculating…" : "No conversation yet").foregroundStyle(.secondary)
                }
            }
            row("Last active") { Text("\(Fmt.ago(s.lastActive)) · \(Fmt.when(s.lastActive))") }
            if let model = stats?.model { row("Model") { Text(model) } }
            if let branch = stats?.branch { row("Git branch") { Text(branch).font(.system(.callout, design: .monospaced)) } }
            row("Process") {
                Text("PID \(s.pid)" + (s.version.map { " · Claude Code \($0)" } ?? ""))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value()
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { Actions.copy(text) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
    }
}

struct RecentRow: View {
    let p: PastSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).lineLimit(1)
                HStack(spacing: 5) {
                    Text(p.cwd.map(Paths.abbreviate) ?? "Unknown folder").truncationMode(.middle)
                    Text("·")
                    Text(Fmt.ago(p.lastActive))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Resume") { Actions.resume(p) }
                .disabled(!p.folderExists)
                .help(p.folderExists ? "Reopen this conversation in Terminal" : "Its folder no longer exists")
        }
        .controlSize(.small)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Resume") { Actions.resume(p) }.disabled(!p.folderExists)
            if let cwd = p.cwd, p.folderExists {
                Button("New Session in This Folder") { Actions.newSession(in: cwd) }
                Button("Show Folder in Finder") { Actions.reveal(cwd) }
            }
            Divider()
            Button("Copy Session ID") { Actions.copy(p.sessionId) }
            Button("Copy Resume Command") {
                Actions.copy((p.cwd.map { "cd \(Actions.shellQuote($0)) && " } ?? "") + "claude --resume \(p.sessionId)")
            }
        }
    }
}

struct RecentPanel: View {
    let items: [PastSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently closed").font(.headline).padding(14)
            Divider()
            if items.isEmpty {
                Text("Nothing here yet.").foregroundStyle(.secondary).padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { p in
                            RecentRow(p: p).padding(.horizontal, 12)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
        .frame(width: 460)
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.green, "Working")
            item(.blue, "Running a command")
            item(.gray, "Idle")
            Text("Click a session for details · double-click to open it · drag it to another center")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private func item(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Main view

enum PendingAction: Identifiable {
    case close(LiveSession), move(LiveSession)

    var id: String {
        switch self {
        case .close(let s): return "close:\(s.id)"
        case .move(let s): return "move:\(s.id)"
        }
    }
    var session: LiveSession {
        switch self { case .close(let s), .move(let s): return s }
    }
}

struct CenterRef: Identifiable { let id: String }

struct PlacedCard: Identifiable {
    let s: LiveSession
    let point: CGPoint
    let group: PlacedGroup
    var id: String { s.id }
}

struct MapView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var hovered: String?
    @State private var selected: String?
    @State private var pending: PendingAction?
    @State private var showRecent = false
    @State private var editingCenter: CenterRef?
    @State private var dropTarget: String?

    private func matches(_ fields: String?...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }

    private var recent: [PastSession] { store.recent.filter { matches($0.title, $0.cwd) } }

    /// Changes whenever a session or center appears, disappears or moves (drives the animation).
    private var layoutKey: String {
        store.centers.map(\.id).joined(separator: ",") + "|" +
        store.live.map { $0.id + ">" + store.centerId(for: $0) }.joined(separator: ",")
    }

    /// Everything opens in Terminal: Terminal sessions are brought forward,
    /// sessions running elsewhere (VS Code, …) are moved over.
    private func open(_ s: LiveSession) {
        selected = nil
        if s.inTerminal { Actions.focus(s); return }
        if StatusStyle(s.status).active || s.hostKind == .other {
            pending = .move(s)
        } else {
            Actions.moveToTerminal(s)
            store.refreshSoon()
        }
    }

    private func newCenter(moving sessionIds: [String] = []) {
        let id = store.addCenter()
        if !sessionIds.isEmpty { store.assign(sessionIds, to: id) }
        editingCenter = CenterRef(id: id)
    }

    private func dropTargeting(_ centerId: String) -> (Bool) -> Void {
        { inside in
            if inside { dropTarget = centerId } else if dropTarget == centerId { dropTarget = nil }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let input = store.centers.map { c in (c, store.live.filter { store.centerId(for: $0) == c.id }) }
            // Keep the bottom strip free for the legend.
            let layout = MapLayout(groups: input,
                                   in: CGSize(width: geo.size.width, height: max(200, geo.size.height - 48)))
            let cards = layout.groups.flatMap { g in zip(g.sessions, g.points).map { PlacedCard(s: $0, point: $1, group: g) } }
            let edges = cards.map { c -> Edge in
                let st = StatusStyle(c.s.status)
                return Edge(from: c.group.origin, to: c.point, color: st.color, active: st.active,
                            emphasized: hovered == c.s.id || selected == c.s.id,
                            dimmed: !matches(c.s.title, c.s.cwd, c.s.hostName))
            }

            ZStack {
                DotGrid()

                // Circles behind each center (also where cards can be dropped).
                ForEach(layout.groups, id: \.center.id) { g in
                    GroupBackdrop(color: g.center.color, radius: g.radius, targeted: dropTarget == g.center.id)
                        .dropDestination(for: String.self, action: { ids, _ in
                            store.assign(ids, to: g.center.id)
                            return true
                        }, isTargeted: dropTargeting(g.center.id))
                        .position(g.origin)
                }

                EdgesLayer(edges: edges)

                ForEach(layout.groups, id: \.center.id) { g in
                    HubNode(center: g.center)
                        .scaleEffect(layout.scale)
                        .onTapGesture(count: 2) { store.startSessionPickingFolder(center: g.center.id) }
                        .onTapGesture { editingCenter = CenterRef(id: g.center.id) }
                        .contextMenu {
                            Button("New Session Here…") { store.startSessionPickingFolder(center: g.center.id) }
                            Button("Edit Center…") { editingCenter = CenterRef(id: g.center.id) }
                            if !g.center.isMain {
                                Divider()
                                Button("Delete Center") { store.deleteCenter(g.center.id) }
                            }
                        }
                        .help("\(g.center.displayName) · \(g.sessions.count) running · click to rename or recolor, double-click to start a session here")
                        .dropDestination(for: String.self, action: { ids, _ in
                            store.assign(ids, to: g.center.id)
                            return true
                        }, isTargeted: dropTargeting(g.center.id))
                        .position(g.origin)
                }

                if store.loaded && store.live.isEmpty, let main = layout.groups.first {
                    Text("No Claude sessions running.\nDouble-click a center or press ⌘N to start one.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .position(x: main.origin.x, y: main.origin.y + main.radius + 30)
                }

                ForEach(cards) { card in
                    let s = card.s
                    let emphasized = hovered == s.id || selected == s.id
                    SessionNode(s: s, emphasized: emphasized)
                        .scaleEffect(layout.scale * (hovered == s.id ? 1.04 : 1))
                        .opacity(matches(s.title, s.cwd, s.hostName) ? 1 : 0.3)
                        .onHover { inside in
                            if inside { hovered = s.id } else if hovered == s.id { hovered = nil }
                        }
                        .onTapGesture(count: 2) { open(s) }
                        .onTapGesture { selected = s.id }
                        .popover(isPresented: Binding(get: { selected == s.id },
                                                      set: { if !$0, selected == s.id { selected = nil } }),
                                 arrowEdge: card.point.y < card.group.origin.y ? .bottom : .top) {
                            SessionDetail(s: s, onOpen: { open(s) }, onClose: {
                                selected = nil
                                pending = .close(s)
                            })
                            .environmentObject(store)
                        }
                        .contextMenu {
                            Button(s.inTerminal ? "Open in Terminal" : "Move to Terminal") { open(s) }
                            Button("Close…") { pending = .close(s) }
                            Divider()
                            Menu("Move to Center") {
                                ForEach(store.centers) { c in
                                    Button {
                                        store.assign([s.sessionId], to: c.id)
                                    } label: {
                                        if store.centerId(for: s) == c.id {
                                            Label(c.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(c.displayName)
                                        }
                                    }
                                }
                                Divider()
                                Button("New Center…") { newCenter(moving: [s.sessionId]) }
                            }
                            Divider()
                            Button("New Session in This Folder") {
                                store.startSession(in: s.cwd, center: store.centerId(for: s))
                            }
                            Button("Show Folder in Finder") { Actions.reveal(s.cwd) }
                            Divider()
                            Button("Copy Session ID") { Actions.copy(s.sessionId) }
                        }
                        .draggable(s.sessionId) {
                            SessionNode(s: s, emphasized: true).opacity(0.85)
                        }
                        .dropDestination(for: String.self, action: { ids, _ in
                            store.assign(ids, to: card.group.center.id)
                            return true
                        }, isTargeted: dropTargeting(card.group.center.id))
                        .position(card.point)
                }
            }
            .animation(.spring(duration: 0.45), value: layoutKey)
            .animation(.easeOut(duration: 0.15), value: hovered)
        }
        .overlay(alignment: .bottom) { Legend().padding(.bottom, 12) }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $query, placement: .toolbar, prompt: "Filter sessions")
        .navigationTitle("Orbit")
        .navigationSubtitle(store.live.isEmpty ? "" : "\(store.live.count) running")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.startSessionPickingFolder(center: nil) } label: { Label("New Session", systemImage: "plus") }
                    .help("Start a new Claude session in a folder (⌘N)")
                Button { newCenter() } label: { Label("New Center", systemImage: "circle.badge.plus") }
                    .help("Add a center to group sessions around")
                Button { showRecent.toggle() } label: { Label("Recently Closed", systemImage: "clock.arrow.circlepath") }
                    .help("Recently closed sessions you can resume")
                    .popover(isPresented: $showRecent, arrowEdge: .bottom) { RecentPanel(items: recent) }
                Button { store.refresh(includeRecent: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh now (⌘R)")
            }
        }
        .sheet(item: $editingCenter) { ref in
            CenterEditor(centerId: ref.id, onDone: { editingCenter = nil })
                .environmentObject(store)
        }
        .alert(pending.map(alertTitle) ?? "",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { action in
            switch action {
            case .close(let s):
                Button("Close Session", role: .destructive) {
                    Actions.close(s)
                    store.refreshSoon()
                }
            case .move(let s):
                Button("Move to Terminal") {
                    Actions.moveToTerminal(s)
                    store.refreshSoon()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(alertMessage(action))
        }
        .task {
            store.start()
            // Launch with `-debugSelectFirst YES` to open the first session's details (for screenshots).
            if UserDefaults.standard.bool(forKey: "debugSelectFirst") {
                try? await Task.sleep(for: .seconds(1.5))
                selected = store.live.first?.id
            }
            // `-debugEditCenter <id>` opens a center's editor (for screenshots).
            if let id = UserDefaults.standard.string(forKey: "debugEditCenter") {
                try? await Task.sleep(for: .seconds(1.5))
                editingCenter = CenterRef(id: id)
            }
        }
    }

    private func alertTitle(_ a: PendingAction) -> String {
        switch a {
        case .close: return "Close this session?"
        case .move: return "Move this session to Terminal?"
        }
    }

    private func alertMessage(_ a: PendingAction) -> String {
        let s = a.session
        let busy = StatusStyle(s.status).active ? " It's working right now and will be interrupted." : ""
        switch a {
        case .close:
            return "“\(s.title)” in \(Paths.abbreviate(s.cwd)) will stop.\(busy) The conversation is saved — you can resume it from Recently Closed."
        case .move:
            return "“\(s.title)” will stop in \(s.hostName) and reopen in a new Terminal window.\(busy)"
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Orbit", id: "main") {
            MapView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { store.startSessionPickingFolder(center: nil) }.keyboardShortcut("n")
                Button("Refresh") { store.refresh(includeRecent: true) }.keyboardShortcut("r")
            }
        }
    }
}

// MARK: - Command-line mode (`Orbit --list`, `--details`, `--rename`)

enum CLI {
    /// Accepts a session ID or a path to a transcript (.jsonl).
    private static func transcript(for idOrPath: String) -> (url: URL, sessionId: String)? {
        if idOrPath.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: idOrPath)
            return (url, url.deletingPathExtension().lastPathComponent)
        }
        return Scanner().index()[idOrPath].map { ($0.url, idOrPath) }
    }

    static func details(_ idOrPath: String) {
        guard let t = transcript(for: idOrPath) else { print("No transcript found for \(idOrPath)"); exit(1) }
        let info = Transcript.read(t.url)
        let st = Transcript.stats(t.url)
        print("Title:        \(info.title ?? "—")\(info.titleIsCustom ? "  (custom)" : "")")
        print("Session ID:   \(t.sessionId)")
        print("Folder:       \(info.cwd.map(Paths.abbreviate) ?? "—")")
        print("First message: \(st.firstAt.map(Fmt.when) ?? "—")")
        print("Time working: ≈ \(Fmt.duration(st.workingTime)) across \(st.prompts) prompts")
        print("Model:        \(st.model ?? "—")")
        print("Git branch:   \(st.branch ?? "—")")
    }

    static func rename(_ idOrPath: String, to title: String) {
        guard let t = transcript(for: idOrPath) else { print("No transcript found for \(idOrPath)"); exit(1) }
        do {
            try TitleWriter.setTitle(title, sessionId: t.sessionId, transcript: t.url)
            print(title.isEmpty ? "Title reset to automatic." : "Renamed to “\(title)”.")
        } catch {
            print("Rename failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func list() {
        let sc = Scanner()
        let idx = sc.index()
        let live = sc.live(index: idx)
        print("RUNNING (\(live.count))")
        for s in live {
            print("  pid \(s.pid)  \(StatusStyle(s.status).label)  ·  \(s.hostName)\(s.tty.map { " " + $0 } ?? "")  ·  \(Paths.abbreviate(s.cwd))  ·  started \(Fmt.ago(s.startedAt))")
            print("      \(s.title)")
        }
        let rec = sc.recent(index: idx, excluding: Set(live.map(\.sessionId)), limit: 10)
        print("\nRECENTLY CLOSED (showing \(rec.count))")
        for p in rec {
            print("  \(p.sessionId)  ·  \(p.cwd.map(Paths.abbreviate) ?? "?")  ·  \(Fmt.ago(p.lastActive))")
            print("      \(p.title)")
        }
    }
}

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            print("""
            Orbit — your Claude Code sessions, as a map.

            Run with no arguments to open the app. Command-line options:
              --list                          List running and recently closed sessions
              --details <session-id|file>     Show details for a session (or a .jsonl transcript)
              --rename <session-id|file> "T"  Rename a session (use "" to go back to the automatic title)
              -demo YES                       Open the app with sample data (for screenshots)
            """)
            return
        }
        if args.contains("--list") {
            CLI.list()
            return
        }
        if let i = args.firstIndex(of: "--details"), i + 1 < args.count {
            CLI.details(args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--rename"), i + 2 < args.count {
            CLI.rename(args[i + 1], to: args[i + 2])
            return
        }
        OrbitApp.main()
    }
}
