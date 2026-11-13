import AppKit
import Foundation

// Menu bar item and floating panel for the usage-hp mod: reads every file in
// ~/.claude/usage-hp/, one per organization (an email can hold two plans),
// each rewritten by the mod whenever a Claude response on that plan reports
// the rate-limit windows.
//
//   usage-hp-menubar                          run in the menu bar
//       [--data-dir <dir>]                    read the entries from another folder
//   USAGE_HP_DEBUG=1 usage-hp-menubar         also say on stderr when the folder changes
//   usage-hp-menubar --snapshot <png>         draw the panel to a PNG and exit
//       [--data-dir <dir>]                    read the entries from another folder
//       [--theme <name>]                      draw it in that theme
//       [--scale <n>]                         draw it at that size, 1 to 2.5
//       [--hover-grip]                        draw the resize corner as under the pointer
//       [--server-on <organization id>]       draw that block as read from the server
//       [--server-failed <organization id>]   draw that block as failing to (both repeatable)
//
// Server mode (server.swift) is off for every account until it is ticked in
// the menu. The stored choice is used only with the real folders: with
// --home, --data-dir or --server-on, only the accounts named by --server-on
// are on, for that run.
//
//   usage-hp-menubar --server-accounts        list the logins found; the keychain is not read
//                                             (the default folder's is marked as excluded)
//       [--home <dir>]                        look for config folders under another home
//   usage-hp-menubar --server-apply <json>    write a saved answer as that login's reading
//       --config-dir <dir>                    (no keychain, no network)
//   usage-hp-menubar --server-once <organization id>
//                                             ask the server once for that account
//       [--dump-shape]                        print only the names and kinds in the answer
//       [--dump-profile-shape]                the same for the profile answer, and which of
//                                             its ids are this login's organization id
//   usage-hp-menubar --server-backoff-table   print the waits after each outcome
//   usage-hp-menubar --server-menu-titles     print the submenu's wording for each outcome
//   usage-hp-menubar --server-menu            print the submenu's rows
//
// An argument that is none of these ends the run with an error, and so does
// a second --home, --data-dir or --server-once, or an option given without
// the one it belongs to (--dump-shape without --server-once). Each option
// and its value are two arguments: "--home=<dir>" is not read. Of the
// arguments with one dash, only the system's are let through
// ("-AppleLanguages (ko)", "-NS...", "-psn_...").

struct Limit: Decodable {
    let kind: String
    let percentUsed: Double
    let resetsAt: String?
}

struct Reading: Decodable {
    let account: String?
    let organizationId: String?
    let organization: String?
    let plan: String?
    // Who wrote the file: the mod's entry point, or "server".
    let source: String?
    let updatedAt: String
    let limits: [Limit]
}

typealias Entry = (reading: Reading, updated: Date?)

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// Every value given for an option that can be repeated.
func arguments(named name: String) -> [String] {
    let all = CommandLine.arguments
    return all.indices.filter { all[$0] == name && $0 + 1 < all.count }.map { all[$0 + 1] }
}

// Every option, and whether a value follows it.
let knownOptions: [String: Bool] = [
    "--data-dir": true, "--snapshot": true, "--theme": true, "--scale": true, "--hover-grip": false,
    "--server-on": true, "--server-failed": true, "--home": true, "--config-dir": true,
    "--server-accounts": false, "--server-apply": true, "--server-once": true, "--dump-shape": false,
    "--dump-profile-shape": false,
    "--server-backoff-table": false, "--server-menu-titles": false, "--server-menu": false,
]

// What is wrong with the arguments, or nil. An option this app does not know
// would otherwise be skipped without a word, and a run meant for a test
// folder ("--home=<dir>", or the option and its folder quoted as one
// argument) would go on with the real home and the stored accounts.
//
// Arguments with a single dash are let through only when they are the ones
// Xcode and macOS add ("-NSDocumentRevisionsDebugMode YES",
// "-AppleLanguages (ko)", "-psn_..."): ending the run over one would leave
// no menu bar item and no word why. Any other is taken for a mistyped option
// of this app ("-home <dir>"), which would otherwise run on the real home.
func argumentError(_ all: [String]) -> String? {
    // The folders everything is read from and written to, and the account
    // asked for: with two of one, the first would be used without a word.
    let onlyOnce: Set<String> = ["--home", "--data-dir", "--server-once"]
    var seen: Set<String> = []
    var index = 0
    while index < all.count {
        let name = all[index]
        if name.hasPrefix("-psn_") {
            // A process serial number is one argument.
            index += 1
            continue
        }
        if name.hasPrefix("-NS") || name.hasPrefix("-Apple") {
            // A defaults override, read by the system as a name and a value.
            let hasValue = index + 1 < all.count && !all[index + 1].hasPrefix("-")
            index += hasValue ? 2 : 1
            continue
        }
        guard let takesValue = knownOptions[name] else { return "unknown argument: " + name }
        if !seen.insert(name).inserted, onlyOnce.contains(name) { return "given twice: " + name }
        if takesValue {
            guard index + 1 < all.count, !all[index + 1].hasPrefix("--") else { return "no value for " + name }
            index += 1
        }
        index += 1
    }

    // An option that does nothing without another one: left alone, the run
    // would go on as the widget, on the real home, as if nothing were asked.
    func needs(_ name: String, _ others: [String]) -> String? {
        guard seen.contains(name), seen.isDisjoint(with: others) else { return nil }
        return name + " needs " + others.joined(separator: " or ")
    }
    let modes: Set<String> = [
        "--snapshot", "--server-accounts", "--server-apply", "--server-once", "--server-backoff-table",
        "--server-menu-titles", "--server-menu",
    ]
    // Without a mode, --server-on names the accounts the widget polls.
    let onIsRead = seen.isDisjoint(with: modes) ? nil : needs("--server-on", ["--snapshot", "--server-menu"])
    return needs("--dump-shape", ["--server-once"])
        ?? needs("--dump-profile-shape", ["--server-once"])
        ?? needs("--config-dir", ["--server-apply"])
        ?? needs("--server-failed", ["--snapshot", "--server-menu"])
        ?? onIsRead
}

// Before anything is read: the folders below are worked out from the options.
if let error = argumentError(Array(CommandLine.arguments.dropFirst())) {
    FileHandle.standardError.write(("usage-hp-menubar: " + error + "\n").data(using: .utf8) ?? Data())
    exit(2)
}

// Under --home when that is given, so a test home never reaches the real folder.
let dataFolder = argument("--data-dir") ?? homeFolder + "/.claude/usage-hp"
// Optional, written by the person: { "<organization id>": "회사 팀" }.
let labelsFile = "labels.json"
let refreshSeconds: TimeInterval = 30
let settings = UserDefaults(suiteName: "com.local.usage-hp-menubar") ?? .standard

// MARK: - Reading the files

func parseDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

func loadLabels() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: dataFolder + "/" + labelsFile) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
}

func debug(_ text: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["USAGE_HP_DEBUG"] == "1" else { return }
    FileHandle.standardError.write((text() + "\n").data(using: .utf8) ?? Data())
}

// The last reading each file parsed to. A file caught half written does not
// parse; its block keeps what it showed until the file reads whole again.
var lastParsed: [String: Reading] = [:]
// A file did not parse on the last load, so the load is worth repeating soon.
var hadUnreadableFile = false

// Every readable entry with at least one window, newest first.
func loadEntries() -> [Entry] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dataFolder)) ?? [])
        .filter { $0.hasSuffix(".json") && $0 != labelsFile }
    var parsed: [String: Reading] = [:]
    hadUnreadableFile = false

    for name in names {
        if let data = FileManager.default.contents(atPath: dataFolder + "/" + name),
           let reading = try? JSONDecoder().decode(Reading.self, from: data) {
            parsed[name] = reading
        } else if let before = lastParsed[name] {
            parsed[name] = before
            hadUnreadableFile = true
        } else {
            hadUnreadableFile = true
        }
    }

    // A file that is gone takes its block with it.
    lastParsed = parsed

    let entries: [Entry] = parsed.values
        .filter { !$0.limits.isEmpty }
        .map { ($0, parseDate($0.updatedAt)) }
    return entries.sorted {
        let (a, b) = ($0.updated ?? .distantPast, $1.updated ?? .distantPast)
        return a != b ? a > b : ($0.reading.organizationId ?? "") < ($1.reading.organizationId ?? "")
    }
}

// Watches the data folder, so a reading shows the moment the mod writes it.
// File-level events: the mod rewrites existing files, which a watch on the
// folder alone would not report. A burst of events is one reload.
final class FolderWatcher {
    let path: String
    let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    var isWatching: Bool { stream != nil }

    // The folder may not be there yet (the mod makes it on its first write),
    // so this is tried again until it is.
    func startIfPossible() {
        var isFolder: ObjCBool = false
        guard stream == nil, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder),
              isFolder.boolValue else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let made = FSEventStreamCreate(
            nil,
            { _, info, count, _, _, _ in
                guard let info else { return }
                debug("usage-hp: change event (\(count))")
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
            },
            &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
        else { return }

        FSEventStreamSetDispatchQueue(made, .main)
        guard FSEventStreamStart(made) else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            return
        }
        stream = made
        debug("usage-hp: watching \(path)")
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

// MARK: - Wording

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// What is left. A window whose reset has passed is full again, whatever the
// file still says, because nothing rewrites the file while Claude is idle.
func remaining(_ limit: Limit, now: Date) -> Int {
    if let reset = parseDate(limit.resetsAt), reset <= now { return 100 }
    return Int((100 - limit.percentUsed).rounded().clamped(to: 0...100))
}

func shortLabel(_ kind: String) -> String {
    switch kind {
    case "five_hour": return "5h"
    case "seven_day": return "7d"
    case "spend_limit": return "$"
    default: return kind
    }
}

func planLabel(_ plan: String) -> String {
    switch plan {
    case "claude_max": return "Max"
    case "claude_pro": return "Pro"
    case "claude_team": return "Team"
    case "claude_enterprise": return "Enterprise"
    default: return plan
    }
}

func known(_ text: String?) -> String? {
    guard let text, !text.isEmpty, text != "unknown" else { return nil }
    return text
}

// The organization's name, unless it only repeats the email: a personal
// organization is named "<email>'s Organization".
func organizationName(_ reading: Reading) -> String? {
    guard let name = known(reading.organization) else { return nil }
    if let email = known(reading.account), name.hasPrefix(email), name.hasSuffix("s Organization") { return nil }
    return name
}

func resetText(_ limit: Limit, now: Date) -> String {
    guard let reset = parseDate(limit.resetsAt) else { return "" }
    if reset <= now { return "리셋됨" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.dateFormat = Calendar.current.isDate(reset, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: reset)
}

// MARK: - Themes

func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

// A theme is colours only; the layout is the same in all of them.
struct Theme {
    let name: String
    let background: NSColor
    let outline: NSColor
    let header: NSColor
    let label: NSColor
    let dim: NSColor
    // The weekly row stands back a step from the 5-hour row: its label and
    // its reset time, never its dots or its percent.
    let weeklyLabel: NSColor
    let weeklyDim: NSColor
    let empty: NSColor
    let good: NSColor
    let warn: NSColor
    let bad: NSColor

    // Over 50 left is good, 20 to 50 a warning, under 20 bad.
    func level(_ hp: Int) -> NSColor { hp < 20 ? bad : hp <= 50 ? warn : good }
}

let themes: [Theme] = [
    Theme(name: "Terminal",
          background: hex(0x0B0D0C, alpha: 0.92), outline: hex(0x2A2D2B), header: hex(0xE6E8E3),
          label: hex(0x8C928D), dim: hex(0xA9B0AB),
          weeklyLabel: hex(0x6C726D), weeklyDim: hex(0x8A908C), empty: hex(0x2B2F2D),
          good: hex(0x3DDC84), warn: hex(0xFFB000), bad: hex(0xFF4D4D)),
    Theme(name: "Amber",
          background: hex(0x0E0A03, alpha: 0.92), outline: hex(0x3B2A0A), header: hex(0xFFD88A),
          label: hex(0xB98A34), dim: hex(0xD0A862),
          weeklyLabel: hex(0x8A6A2E), weeklyDim: hex(0xAD8948), empty: hex(0x33250A),
          good: hex(0xFFC53D), warn: hex(0xE2701C), bad: hex(0xFF3B30)),
    Theme(name: "Phosphor",
          background: hex(0x030A05, alpha: 0.92), outline: hex(0x153A1E), header: hex(0xB8FFC4),
          label: hex(0x52B063), dim: hex(0x82CC90),
          weeklyLabel: hex(0x3C8049), weeklyDim: hex(0x5FA66D), empty: hex(0x0F2F19),
          good: hex(0x33E06A), warn: hex(0xD6F03C), bad: hex(0xFF4D4D)),
    Theme(name: "Ice",
          background: hex(0x07101C, alpha: 0.92), outline: hex(0x1E3552), header: hex(0xDDEBFF),
          label: hex(0x84A4C8), dim: hex(0x9FBADB),
          weeklyLabel: hex(0x5F7EA0), weeklyDim: hex(0x7F9CBE), empty: hex(0x17293F),
          good: hex(0x4FD8FF), warn: hex(0x8A8CFF), bad: hex(0xFF5C7A)),
    Theme(name: "Mono",
          background: hex(0x0A0A0A, alpha: 0.92), outline: hex(0x323232), header: hex(0xF2F2F2),
          label: hex(0x9C9C9C), dim: hex(0xABABAB),
          weeklyLabel: hex(0x707070), weeklyDim: hex(0x8E8E8E), empty: hex(0x2A2A2A),
          good: hex(0xF2F2F2), warn: hex(0x9C9C9C), bad: hex(0xFF4D4D)),
    Theme(name: "Paper",
          background: hex(0xF4EFE4, alpha: 0.96), outline: hex(0xC8BFAD), header: hex(0x2A2622),
          label: hex(0x6E665A), dim: hex(0x544D42),
          weeklyLabel: hex(0x8F8777), weeklyDim: hex(0x726A5D), empty: hex(0xDCD4C3),
          good: hex(0x2F7D4F), warn: hex(0xB8740A), bad: hex(0xC4302B)),
]

func theme(named name: String?) -> Theme {
    themes.first { $0.name.lowercased() == name?.lowercased() } ?? themes[0]
}

func currentTheme() -> Theme { theme(named: argument("--theme") ?? settings.string(forKey: "theme")) }

// MARK: - The panel's wording

func hudLabel(_ kind: String) -> String {
    switch kind {
    case "five_hour": return "5H"
    case "seven_day": return "7D"
    case "spend_limit": return "$"
    default: return String(kind.prefix(2)).uppercased()
    }
}

// Line 1: the plan, uppercased; the person's own label as typed wins.
func hudPlan(_ reading: Reading, labels: [String: String]) -> String {
    if let id = known(reading.organizationId), let label = known(labels[id]) { return label }
    return known(reading.plan).map { planLabel($0).uppercased() } ?? "PLAN ?"
}

// Line 2: the account, cut to `limit` characters (the font has one width).
// The email's local part gives way first, from its middle; the domain never
// does, and the organization's name goes only when that is still too long.
func hudAccount(_ reading: Reading, limit: Int) -> String {
    let name = organizationName(reading)

    guard let email = known(reading.account) else {
        let text = name ?? known(reading.organizationId).map { String($0.prefix(8)) } ?? "?"
        return text.count <= limit ? text : String(text.prefix(max(limit - 1, 0))) + "…"
    }

    let tail = name.map { " · " + $0 } ?? ""
    if email.count + tail.count <= limit { return email + tail }

    let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let local = String(parts.first ?? "")
    let domain = parts.count > 1 ? "@" + parts[1] : ""

    // The local part with its middle taken out, `room` characters in all.
    func cut(_ room: Int) -> String? {
        guard room >= 3 else { return nil }
        let head = (room - 1 + 1) / 2
        return String(local.prefix(head)) + "…" + String(local.suffix(room - 1 - head))
    }

    if let short = cut(limit - domain.count - tail.count) { return short + domain + tail }
    if email.count <= limit { return email }
    if let short = cut(limit - domain.count) { return short + domain }
    return String(email.prefix(max(limit - 1, 0))) + "…"
}

// How a block that is read from the server is marked: by the person's choice,
// not by who wrote the file last.
enum ServerMark { case on, failed }

// "2m". That an account is read from the server, and that the last attempt
// at that failed, is the badge's to say, not the age's.
func hudAge(_ updated: Date?, now: Date) -> String {
    guard let updated else { return "" }
    let minutes = Int(now.timeIntervalSince(updated) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 60 * 24 { return "\(minutes / 60)h" }
    return "\(minutes / (60 * 24))d"
}

// MARK: - The server submenu's wording

// One account's line: its name, and after it why it cannot be read, if so.
func serverMenuTitle(label: String, hasLogin: Bool, outcome: ServerOutcome?) -> String {
    guard hasLogin else { return label + " — 터미널 로그인 없음" }

    switch outcome {
    case nil, .ok:
        return label
    case .noLogin:
        return label + " — 터미널 로그인 없음"
    case .excluded:
        return label + " — 기본 폴더 로그인은 아직 지원 안 함"
    case .unreadableFile:
        return label + " — 기록 파일을 읽을 수 없음"
    case .wrongOrganization:
        return label + " — 다른 조직으로 로그인됨"
    case .expired, .unauthorized:
        return label + " — 로그인 만료 · claude 를 한 번 실행해 주세요"
    case .rateLimited:
        return label + " — 요청 제한 · 잠시 후 다시 시도"
    case .serverError:
        return label + " — 서버 응답 오류"
    case .offline:
        return label + " — 연결 안 됨"
    case .noKeychainItem:
        return label + " — 키체인에 로그인 없음"
    case .noData:
        return label + " — 데이터 없음"
    }
}

struct ServerRow {
    let organizationId: String
    let title: String
    let isOn: Bool
    let isEnabled: Bool
}

// The submenu's lines: every login found, then every account that has a file
// but no login, then every ticked account that has neither. A login with no
// file yet is listed too (ticking it makes the file). An account with no
// login, or only one that server mode leaves alone, cannot be ticked, only
// unticked.
func serverRows(logins: [Login], entries: [Entry], labels: [String: String], ticked: [String],
                isOn: (String) -> Bool, outcome: (String) -> ServerOutcome?) -> [ServerRow] {
    var readings: [String: Reading] = [:]
    for entry in entries {
        if let id = known(entry.reading.organizationId), readings[id] == nil { readings[id] = entry.reading }
    }

    // Named as the panel names it: the plan or the person's label, then the email.
    func row(_ id: String, _ reading: Reading, login: Login?) -> ServerRow {
        let label = hudPlan(reading, labels: labels) + " · " + (known(reading.account) ?? String(id.prefix(8)))
        let on = isOn(id)
        // Said whether ticked or not: it is why the line cannot be ticked.
        if login?.isExcluded == true {
            return ServerRow(
                organizationId: id, title: serverMenuTitle(label: label, hasLogin: true, outcome: .excluded),
                isOn: on, isEnabled: on)
        }
        return ServerRow(
            organizationId: id,
            title: serverMenuTitle(label: label, hasLogin: login != nil, outcome: on ? outcome(id) : nil),
            isOn: on, isEnabled: login != nil || on)
    }

    var rows: [ServerRow] = []
    for login in logins {
        let reading = readings[login.organizationId] ?? Reading(
            account: login.email, organizationId: login.organizationId, organization: login.organization,
            plan: login.plan, source: nil, updatedAt: "", limits: [])
        rows.append(row(login.organizationId, reading, login: login))
    }
    for id in readings.keys.sorted() where !logins.contains(where: { $0.organizationId == id }) {
        if let reading = readings[id] { rows.append(row(id, reading, login: nil)) }
    }

    // Ticked, then logged out and its file removed: only the id is left to
    // name it by. Without a line it could not be unticked, and would be read
    // again, unasked, the day a folder logs in to it.
    for id in ticked where !rows.contains(where: { $0.organizationId == id }) {
        rows.append(ServerRow(
            organizationId: id,
            title: serverMenuTitle(label: String(id.prefix(8)), hasLogin: false, outcome: nil),
            isOn: true, isEnabled: true))
    }
    return rows
}

// MARK: - The panel's drawing

let minimumScale: CGFloat = 1
let maximumScale: CGFloat = 2.5

func currentScale() -> CGFloat {
    let asked = argument("--scale").flatMap { Double($0) } ?? (settings.object(forKey: "hudScale") as? Double) ?? 1
    return CGFloat(asked).clamped(to: minimumScale...maximumScale)
}

// The whole panel, drawn by hand: a flat fill with notched corners and a thin
// outline, one block per plan (plan and age, account, then a row of ten dots
// per window). It is laid out once, at its natural size; a larger panel is the
// same layout with every measure multiplied and then put on a device pixel,
// so nothing reflows and every edge stays crisp. Fonts grow by point size.
final class HudCanvas: NSView {
    static let width: CGFloat = 280
    static let padding: CGFloat = 14
    static let line: CGFloat = 18
    static let accountLine: CGFloat = 15
    static let accountGap: CGFloat = 3
    static let blockGap: CGFloat = 13
    static let notch: CGFloat = 2

    static let dots = 10
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 3

    static let labelWidth: CGFloat = 15
    static let labelGap: CGFloat = 10
    static let percentGap: CGFloat = 9
    static let percentWidth: CGFloat = 29
    static let grip: CGFloat = 18

    var entries: [Entry] = []
    var labels: [String: String] = [:]
    var now = Date()
    var theme = themes[0]
    var scale: CGFloat = 1
    // By organization id: the blocks read from the server.
    var serverMarks: [String: ServerMark] = [:]

    // Dragging the grip asks for a size; letting go, or a double click (back
    // to the natural size), settles it.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    private var resizeStart: (mouse: NSPoint, scale: CGFloat)?
    private var gripArea: NSTrackingArea?
    // The pointer is over the grip: drawn, since the cursor alone cannot be
    // relied on in a panel that is never the key window.
    var isGripLit = false {
        didSet { if isGripLit != oldValue { setNeedsDisplay(gripRect) } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // The panel is moved and sized from here, so the grip can do one and the
    // rest of the surface the other.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The size at scale 1.
    static func naturalSize(for entries: [Entry]) -> NSSize {
        guard !entries.isEmpty else { return NSSize(width: width, height: padding * 2 + line) }
        let blocks = entries.reduce(CGFloat(0)) {
            $0 + line + accountLine + accountGap + CGFloat($1.reading.limits.count) * line
        }
        return NSSize(width: width, height: padding * 2 + blocks + CGFloat(entries.count - 1) * blockGap)
    }

    static func size(for entries: [Entry], scale: CGFloat) -> NSSize {
        let natural = naturalSize(for: entries)
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    func show(_ entries: [Entry], labels: [String: String], now: Date, theme: Theme, scale: CGFloat) {
        self.entries = entries
        self.labels = labels
        self.now = now
        self.theme = theme
        self.scale = scale
        needsDisplay = true
    }

    // MARK: Moving and sizing

    var gripRect: NSRect {
        let side = HudCanvas.grip * scale
        return NSRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
    }

    var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) { return NSCursor.frameResize(position: .bottomRight, directions: .all) }
        return .crosshair
    }

    // Cursor rects need a key window, which this panel never is, so the grip
    // is tracked always and the cursor is set by hand: on entering, and again
    // on every move inside, because the app in front may put its own back.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gripArea { removeTrackingArea(gripArea) }
        let area = NSTrackingArea(
            rect: gripRect, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
            owner: self)
        addTrackingArea(area)
        gripArea = area
    }

    func isOverGrip(_ event: NSEvent) -> Bool { gripRect.contains(convert(event.locationInWindow, from: nil)) }

    override func mouseEntered(with event: NSEvent) {
        isGripLit = true
        resizeCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOverGrip(event) else { return }
        isGripLit = true
        resizeCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        if resizeStart != nil || isOverGrip(event) { resizeCursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        // A drag that leaves the corner is still a resize.
        guard resizeStart == nil else { return }
        isGripLit = false
        NSCursor.arrow.set()
    }

    // Lets go of the grip and gives the arrow back: the panel is going away,
    // or its corner is no longer under the pointer. A resize cursor must never
    // outlive the hover, since the window server honours it in the background.
    func dropGrip() {
        guard isGripLit || resizeStart != nil else { return }
        resizeStart = nil
        isGripLit = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard gripRect.contains(convert(event.locationInWindow, from: nil)) else {
            window?.performDrag(with: event)
            return
        }

        if event.clickCount >= 2 {
            resizeStart = nil
            onResize?(1)
            onResizeEnd?()
            // The corner has moved out from under the pointer.
            dropGrip()
            return
        }

        resizeStart = (NSEvent.mouseLocation, scale)
        isGripLit = true
        resizeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = resizeStart else { return }
        resizeCursor.set()
        let natural = HudCanvas.naturalSize(for: entries)
        let mouse = NSEvent.mouseLocation
        // Right and down grow it; the two directions are averaged so a
        // diagonal drag tracks the corner.
        let across = (natural.width * start.scale + (mouse.x - start.mouse.x)) / natural.width
        let down = (natural.height * start.scale + (start.mouse.y - mouse.y)) / natural.height
        onResize?(((across + down) / 2).clamped(to: minimumScale...maximumScale))
    }

    override func mouseUp(with event: NSEvent) {
        guard resizeStart != nil else { return }
        resizeStart = nil
        onResizeEnd?()

        if isOverGrip(event) {
            resizeCursor.set()
        } else {
            isGripLit = false
            NSCursor.arrow.set()
        }
    }

    // MARK: Drawing

    // A rectangle with a square bite of `n` out of each corner.
    func notched(_ rect: NSRect, _ n: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + n, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - n, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - n, y: rect.minY + n))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + n))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - n))
        path.line(to: NSPoint(x: rect.maxX - n, y: rect.maxY - n))
        path.line(to: NSPoint(x: rect.maxX - n, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + n, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + n, y: rect.maxY - n))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - n))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + n))
        path.line(to: NSPoint(x: rect.minX + n, y: rect.minY + n))
        path.close()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        let backing = window?.backingScaleFactor ?? 2

        // A measure of the natural layout at this scale, on a device pixel.
        func px(_ value: CGFloat) -> CGFloat { (value * scale * backing).rounded() / backing }
        func snap(_ value: CGFloat) -> CGFloat { (value * backing).rounded() / backing }
        func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
            NSFont.monospacedSystemFont(ofSize: size * scale, weight: weight)
        }

        // Text on one line of `height` starting at `top`, its left edge at `x`
        // or its right edge at `right`.
        func write(_ text: String, _ font: NSFont, _ color: NSColor, top: CGFloat, height: CGFloat,
                   x: CGFloat? = nil, right: CGFloat? = nil) {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = string.size()
            let left = x ?? ((right ?? 0) - size.width)
            string.draw(at: NSPoint(x: snap(left), y: snap(top + (height - size.height) / 2)))
        }

        // The text, or as much of its start as fits in `width` with "…" after
        // it. Measured, not counted: a label can hold letters the monospaced
        // font does not have, drawn wider from another one.
        func fitted(_ text: String, _ font: NSFont, width: CGFloat) -> String {
            func measure(_ text: String) -> CGFloat {
                NSAttributedString(string: text, attributes: [.font: font]).size().width
            }
            guard measure(text) > width else { return text }
            var kept = Substring(text)
            while !kept.isEmpty {
                kept = kept.dropLast()
                while kept.last == " " { kept = kept.dropLast() }
                if measure(kept + "…") <= width { break }
            }
            return kept + "…"
        }

        let headerFont = font(13, .medium)
        let accountFont = font(11)
        let rowFont = font(12)
        let percentFont = font(12, .medium)
        let dateFont = font(10)

        let pad = px(HudCanvas.padding)
        let line = px(HudCanvas.line)
        let right = bounds.width - pad
        // Between the plan, the server tag and the age on a block's first line.
        let tagGap = px(7)
        let dot = px(HudCanvas.dot)
        let pitch = dot + px(HudCanvas.dotGap)
        let barX = pad + px(HudCanvas.labelWidth) + px(HudCanvas.labelGap)
        let barWidth = pitch * CGFloat(HudCanvas.dots - 1) + dot
        let percentRight = barX + barWidth + px(HudCanvas.percentGap) + px(HudCanvas.percentWidth)

        // The outline is a thin band; the fill sits inside it.
        let edge = px(1)
        let notch = px(HudCanvas.notch)
        let inside = bounds.insetBy(dx: edge, dy: edge)
        let border = notched(bounds, notch)
        border.append(notched(inside, notch))
        border.windingRule = .evenOdd
        theme.outline.setFill()
        border.fill()
        theme.background.setFill()
        notched(inside, notch).fill()

        // The grip: three small squares in the bottom-right corner; under the
        // pointer, or while it sizes the panel, brighter and with a bracket
        // along the two edges.
        let speck = px(2)
        let reach = px(5)
        (isGripLit ? theme.header : theme.weeklyLabel.withAlphaComponent(0.7)).setFill()
        for (across, down) in [(1, 1), (2, 1), (1, 2)] as [(CGFloat, CGFloat)] {
            NSRect(x: bounds.maxX - edge - reach * across + (reach - speck) - px(2),
                   y: bounds.maxY - edge - reach * down + (reach - speck) - px(2),
                   width: speck, height: speck).fill()
        }

        if isGripLit {
            let arm = px(10)
            NSRect(x: bounds.maxX - notch - arm, y: bounds.maxY - edge, width: arm, height: edge).fill()
            NSRect(x: bounds.maxX - edge, y: bounds.maxY - notch - arm, width: edge, height: arm).fill()
            NSRect(x: bounds.maxX - notch - edge, y: bounds.maxY - notch - edge, width: edge, height: edge).fill()
        }

        guard !entries.isEmpty else {
            write("측정값 없음", rowFont, theme.dim, top: pad, height: line, x: pad)
            return
        }

        let accountWidth = NSAttributedString(string: "0", attributes: [.font: accountFont]).size().width
        let accountLimit = Int((bounds.width - pad * 2) / accountWidth)
        var top = pad

        for (index, entry) in entries.enumerated() {
            if index > 0 { top += px(HudCanvas.blockGap) }

            let mark = known(entry.reading.organizationId).flatMap { serverMarks[$0] }
            let age = hudAge(entry.updated, now: now)
            write(age, rowFont, mark == .failed ? theme.bad : theme.dim, top: top, height: line, right: right)
            let ageWidth = NSAttributedString(string: age, attributes: [.font: rowFont]).size().width
            // Where the plan has to end: short of the age, or of the tag below.
            var planRight = age.isEmpty ? right : right - ageWidth - tagGap

            // A block read from the server carries a tag left of its age: the
            // far end of the line from the plan, so a long label has the most
            // room before it reaches it. It is a label and must not pass for a
            // control, hence small flat text on a flat fill, no glyph. The fill
            // is the theme's good colour. Failed, it is the bad one and the tag
            // says so: a word as well as a colour, in the same shape.
            if let mark {
                let text = NSMutableAttributedString(string: mark == .failed ? "SERVER FAIL" : "SERVER SYNC", attributes: [
                    .font: font(8, .medium), .kern: 0.6 * scale,
                    .foregroundColor: theme.background.withAlphaComponent(1),
                ])
                // The last letter's spacing is not part of the word.
                let textSize = NSSize(width: text.size().width - 0.6 * scale, height: text.size().height)
                let inset = px(4)
                let height = px(11)
                let tagRight = snap(right - (age.isEmpty ? 0 : ageWidth + tagGap))
                let tag = NSRect(x: snap(tagRight - textSize.width - inset * 2), y: top + snap((line - height) / 2),
                                 width: snap(textSize.width + inset * 2), height: height)

                (mark == .failed ? theme.bad : theme.good).setFill()
                notched(tag, px(1)).fill()
                text.draw(at: NSPoint(x: snap(tag.minX + inset), y: snap(tag.minY + (height - textSize.height) / 2)))
                planRight = tag.minX - tagGap
            }
            write(fitted(hudPlan(entry.reading, labels: labels), headerFont, width: planRight - pad),
                  headerFont, theme.header, top: top, height: line, x: pad)
            top += line

            write(hudAccount(entry.reading, limit: accountLimit), accountFont, theme.dim,
                  top: top, height: px(HudCanvas.accountLine), x: pad)
            top += px(HudCanvas.accountLine) + px(HudCanvas.accountGap)

            for limit in entry.reading.limits {
                let hp = remaining(limit, now: now)
                let color = theme.level(hp)
                let isWeekly = limit.kind == "seven_day"

                write(hudLabel(limit.kind), rowFont, isWeekly ? theme.weeklyLabel : theme.label,
                      top: top, height: line, x: pad)

                // Ten dots; the last filled one can be part full, cut on a pixel.
                let dotTop = top + snap((line - dot) / 2)
                let corner = min(px(1), dot / 4)

                for position in 0..<HudCanvas.dots {
                    let cell = NSRect(x: barX + CGFloat(position) * pitch, y: dotTop, width: dot, height: dot)
                    let shape = NSBezierPath(roundedRect: cell, xRadius: corner, yRadius: corner)
                    theme.empty.setFill()
                    shape.fill()

                    let part = (CGFloat(hp) / 100 * CGFloat(HudCanvas.dots) - CGFloat(position)).clamped(to: 0...1)
                    guard part > 0 else { continue }

                    NSGraphicsContext.saveGraphicsState()
                    shape.addClip()
                    var filled = cell
                    filled.size.width = max(snap(dot * part), 1 / backing)
                    color.setFill()
                    filled.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }

                write("\(hp)%", percentFont, color, top: top, height: line, right: percentRight)

                // Today's reset is a time; a later one carries its date, smaller.
                let reset = resetText(limit, now: now)
                write(reset, reset.contains("/") ? dateFont : rowFont, isWeekly ? theme.weeklyDim : theme.dim,
                      top: top, height: line, right: right)

                top += line
            }
        }
    }
}

// MARK: - The floating panel

// Never key or main: a click or a drag on it must not take the keyboard from
// the app the person is typing in.
final class HudPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Hud: NSObject, NSWindowDelegate {
    let panel: HudPanel
    let canvas = HudCanvas()
    var hasPlaced = false
    var isPlacing = false
    var scale = currentScale()

    var isHidden: Bool {
        get { settings.bool(forKey: "hudHidden") }
        set { settings.set(newValue, forKey: "hudHidden") }
    }

    override init() {
        panel = HudPanel(
            contentRect: NSRect(x: 0, y: 0, width: HudCanvas.width, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: the system's would be a rectangle behind notched corners.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The canvas moves and sizes the panel itself.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        panel.contentView = canvas

        // The size follows the drag; it is kept when the drag ends.
        canvas.onResize = { [weak self] scale in
            guard let self else { return }
            self.scale = scale
            self.canvas.scale = scale
            self.canvas.needsDisplay = true
            self.fit()
        }
        canvas.onResizeEnd = { [weak self] in
            guard let self else { return }
            settings.set(Double(self.scale), forKey: "hudScale")
        }
    }

    func update(_ entries: [Entry], labels: [String: String], now: Date) {
        canvas.show(entries, labels: labels, now: now, theme: currentTheme(), scale: scale)
        fit()

        if isHidden {
            canvas.dropGrip()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // Top-right of the main screen, under the menu bar.
    func defaultTopLeft(width: CGFloat) -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - width - 12, y: frame.maxY - 8)
    }

    func isOnScreen(_ topLeft: NSPoint, width: CGFloat) -> Bool {
        let probe = NSRect(x: topLeft.x, y: topLeft.y - 40, width: width, height: 40)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
    }

    func topLeft(width: CGFloat) -> NSPoint {
        var point: NSPoint

        if hasPlaced {
            point = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        } else if let x = settings.object(forKey: "hudX") as? Double,
                  let y = settings.object(forKey: "hudTop") as? Double {
            point = NSPoint(x: x, y: y)
        } else {
            point = defaultTopLeft(width: width)
        }

        // A saved or current place on a display that is gone: start over.
        if !isOnScreen(point, width: width) { point = defaultTopLeft(width: width) }
        return point
    }

    // Size to the content at the current scale, the top-left corner staying
    // where it is, on whole points so the drawing lands on pixels.
    func fit() {
        let size = HudCanvas.size(for: canvas.entries, scale: scale)
        let corner = topLeft(width: size.width)
        isPlacing = true
        panel.setFrame(
            NSRect(x: corner.x.rounded(), y: (corner.y - size.height).rounded(), width: size.width, height: size.height),
            display: true)
        isPlacing = false
        hasPlaced = true
    }

    func windowDidMove(_ notification: Notification) {
        guard hasPlaced, !isPlacing else { return }
        settings.set(Double(panel.frame.minX), forKey: "hudX")
        settings.set(Double(panel.frame.maxY), forKey: "hudTop")
    }
}

// MARK: - Snapshot

// Stands in for what only a window on screen has: a busy desktop behind it.
final class SnapshotBack: NSView {
    static let margin: CGFloat = 30

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colors = [hex(0x4D73BF), hex(0xCC8C73), hex(0xD9D1B3), hex(0x599980)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -45)
    }
}

// The same canvas from the same files, drawn offscreen at 2x.
func snapshot(to path: String) -> Bool {
    let entries = loadEntries()
    let scale = currentScale()
    let margin = SnapshotBack.margin
    let panel = HudCanvas.size(for: entries, scale: scale)
    let size = NSSize(width: panel.width + margin * 2, height: panel.height + margin * 2)

    let back = SnapshotBack(frame: NSRect(origin: .zero, size: size))
    let canvas = HudCanvas(frame: NSRect(x: margin, y: margin, width: panel.width, height: panel.height))
    for id in arguments(named: "--server-on") { canvas.serverMarks[id] = .on }
    for id in arguments(named: "--server-failed") { canvas.serverMarks[id] = .failed }
    canvas.show(entries, labels: loadLabels(), now: Date(), theme: currentTheme(), scale: scale)
    canvas.isGripLit = CommandLine.arguments.contains("--hover-grip")
    back.addSubview(canvas)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
    rep.size = size
    back.cacheDisplay(in: back.bounds, to: rep)

    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

// MARK: - Menu bar

// The stored choice of server accounts is for the real folders. A run that
// names another home or data folder, or its own accounts, has only the
// accounts it names, and stores nothing.
func serverAccountsForThisRun() -> [String]? {
    let named = arguments(named: "--server-on")
    let isElsewhere = argument("--home") != nil || argument("--data-dir") != nil
    return isElsewhere || !named.isEmpty ? named : nil
}

final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let hud = Hud()
    let poller = ServerPoller(home: homeFolder, dataDir: dataFolder, onlyThisRun: serverAccountsForThisRun())
    // What the panel shows now; the server submenu is filled from it.
    private var shown: (entries: [Entry], labels: [String: String]) = ([], [:])
    lazy var watcher = FolderWatcher(path: dataFolder) { [weak self] in
        debug("usage-hp: reload after change")
        self?.refresh()
    }
    private var retry: DispatchWorkItem?

    // The watcher shows a new reading at once. The timer stays for what no
    // file change announces: an age growing ("now" to "1m"), a window going
    // back to full when its reset time passes, and the folder first appearing.
    func start() {
        poller.onChange = { [weak self] in self?.refresh() }
        refresh()
        poller.start()
        let timer = Timer(timeInterval: refreshSeconds, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func refresh() {
        let now = Date()
        let menu = NSMenu()
        watcher.startIfPossible()
        let entries = loadEntries()
        let labels = loadLabels()
        shown = (entries, labels)

        // The mark follows the choice: failed when the last attempt was not a
        // success, whatever the file holds.
        var marks: [String: ServerMark] = [:]
        for id in poller.organizations {
            let outcome = poller.outcome(id)
            marks[id] = outcome == nil || outcome == .ok ? .on : .failed
        }
        hud.canvas.serverMarks = marks
        hud.update(entries, labels: labels, now: now)

        // A file caught half written: look again shortly, not at the next tick.
        retry?.cancel()
        if hadUnreadableFile {
            let again = DispatchWorkItem { [weak self] in self?.refresh() }
            retry = again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: again)
        }

        // The title is the entry used last; the panel shows them all, and the
        // menu holds only the actions.
        if let newest = entries.first {
            let left = newest.reading.limits.map { ($0, remaining($0, now: now)) }
            let lowest = left.map { $0.1 }.min() ?? 100
            let color: NSColor? = lowest < 20 ? .systemRed : lowest <= 50 ? .systemOrange : nil
            setTitle(left.map { "\(shortLabel($0.0.kind)) \($0.1)%" }.joined(separator: " · "), color: color)
        } else {
            setTitle("HP –", color: nil)
        }

        finish(menu)
    }

    func finish(_ menu: NSMenu) {
        let toggle = NSMenuItem(
            title: hud.isHidden ? "플로팅 창 보이기" : "플로팅 창 숨기기", action: #selector(toggleHud), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // The panel's colours; the choice is kept.
        let current = currentTheme().name
        let choices = NSMenu()
        for theme in themes {
            let choice = NSMenuItem(title: theme.name, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            choice.target = self
            choice.state = theme.name == current ? .on : .off
            choices.addItem(choice)
        }
        let themeItem = NSMenuItem(title: "테마", action: nil, keyEquivalent: "")
        themeItem.submenu = choices
        menu.addItem(themeItem)

        // Filled when it opens (menuNeedsUpdate), so the config folders are
        // read then and not on every refresh.
        let server = NSMenu()
        server.autoenablesItems = false
        server.delegate = self
        let serverItem = NSMenuItem(title: "서버에서 읽기", action: nil, keyEquivalent: "")
        serverItem.submenu = server
        menu.addItem(serverItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quitNow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    // The server submenu: one line per account, ticked when it is read from
    // the server, then the action that asks now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = serverRows(
            logins: discoverLogins(home: homeFolder), entries: shown.entries, labels: shown.labels,
            ticked: poller.organizations, isOn: { self.poller.isOn($0) }, outcome: { self.poller.outcome($0) })

        for row in rows {
            let line = NSMenuItem(title: row.title, action: #selector(toggleServer(_:)), keyEquivalent: "")
            line.target = self
            line.representedObject = row.organizationId
            line.state = row.isOn ? .on : .off
            line.isEnabled = row.isEnabled
            menu.addItem(line)
        }

        if !rows.isEmpty { menu.addItem(.separator()) }
        let now = NSMenuItem(title: "지금 갱신", action: #selector(refreshServer), keyEquivalent: "")
        now.target = self
        now.isEnabled = !poller.organizations.isEmpty
        menu.addItem(now)
    }

    // The title never says a request is out: a mark that comes and goes in the
    // menu bar reads as something to press.
    func setTitle(_ text: String, color: NSColor?) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: .medium)
        ]
        if let color { attributes[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    @objc func toggleHud() {
        hud.isHidden.toggle()
        refresh()
    }
    @objc func chooseTheme(_ sender: NSMenuItem) {
        settings.set(sender.title, forKey: "theme")
        refresh()
    }
    @objc func toggleServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        poller.setOn(id, !poller.isOn(id))
    }
    @objc func refreshServer() {
        poller.refreshNow()
    }
    @objc func quitNow() {
        hud.canvas.dropGrip()
        NSCursor.arrow.set()
        NSApp.terminate(nil)
    }
}

// An UNDOCUMENTED CoreGraphics call, the only one in this app. This app is
// never the active one (the panel must not take the keyboard), and the window
// server ignores a cursor set by an app in the background, so without this the
// resize cursor never shows over the panel's corner. It asks the window server
// to honour this process's cursor while in the background, as overlay
// utilities have long done. The app works without it; only the cursor's shape
// is lost (the corner still lights up). The two functions are looked up at run
// time, so a system that no longer has them, or a call that fails, changes
// nothing else.
func allowCursorInBackground() {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    let anywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let connectionSymbol = dlsym(anywhere, "_CGSDefaultConnection"),
          let propertySymbol = dlsym(anywhere, "CGSSetConnectionProperty") else { return }

    let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
    _ = unsafeBitCast(propertySymbol, to: SetProperty.self)(
        connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}

// MARK: - Command line

func say(_ text: String) {
    FileHandle.standardOutput.write((text + "\n").data(using: .utf8) ?? Data())
}

if CommandLine.arguments.contains("--server-accounts") {
    func line(_ login: Login) -> String {
        [login.service, login.email, login.organizationId, login.plan ?? ""].joined(separator: "\t")
    }
    // The default folder first, always, with why it is not used; then the
    // logins server mode can use.
    let first = defaultLogin(home: homeFolder)
    if let first { say(line(first) + (first.isExcluded ? "\texcluded: default folder" : "")) }
    for login in discoverLogins(home: homeFolder) where login.configDir != first?.configDir { say(line(login)) }
    exit(0)
}

if let file = argument("--server-apply") {
    guard let folder = argument("--config-dir").map(withoutTrailingSlash),
          let login = discoverLogins(home: homeFolder).first(where: { $0.configDir == folder && !$0.isExcluded }),
          let response = FileManager.default.contents(atPath: file),
          let limits = serverLimits(from: response) else { exit(1) }
    exit(writeServerReading(limits, login: login, dataDir: dataFolder, now: Date()) ? 0 : 1)
}

if CommandLine.arguments.contains("--server-backoff-table") {
    let poller = ServerPoller(home: homeFolder, dataDir: dataFolder, onlyThisRun: [])

    // The waits after the same outcome `times` in a row, from the usual one.
    func waits(_ outcome: ServerOutcome, _ times: Int) -> String {
        var wait = ServerPoller.interval
        var texts: [String] = []
        for _ in 0..<times {
            wait = poller.nextDelay(after: outcome, previous: wait)
            texts.append(wait.isFinite ? String(Int(wait)) : "halt")
        }
        return texts.joined(separator: " ")
    }

    say("ok " + waits(.ok, 1))
    say("offline " + waits(.offline, 5))
    say("rateLimited(nil) " + waits(.rateLimited(retryAfter: nil), 5))
    say("rateLimited(471) " + waits(.rateLimited(retryAfter: 471), 1))
    say("rateLimited(7200) " + waits(.rateLimited(retryAfter: 7200), 1))
    say("expired " + waits(.expired, 1))
    say("unauthorized " + waits(.unauthorized, 1))
    say("wrongOrganization " + waits(.wrongOrganization, 2))
    exit(0)
}

if CommandLine.arguments.contains("--server-menu-titles") {
    let label = "PRO · b@example.com"
    let cases: [(String, Bool, ServerOutcome?)] = [
        ("none", true, nil), ("noLogin", false, nil), ("excluded", true, .excluded), ("expired", true, .expired),
        ("unauthorized", true, .unauthorized), ("rateLimited", true, .rateLimited(retryAfter: nil)),
        ("serverError", true, .serverError(500)), ("offline", true, .offline),
        ("noKeychainItem", true, .noKeychainItem), ("noData", true, .noData), ("ok", true, .ok),
        ("wrongOrganization", true, .wrongOrganization), ("unreadableFile", true, .unreadableFile),
    ]
    for (name, hasLogin, outcome) in cases {
        say(name + "\t" + serverMenuTitle(label: label, hasLogin: hasLogin, outcome: outcome))
    }
    exit(0)
}

if CommandLine.arguments.contains("--server-menu") {
    let on = Set(arguments(named: "--server-on") + arguments(named: "--server-failed"))
    let failed = Set(arguments(named: "--server-failed"))
    let rows = serverRows(
        logins: discoverLogins(home: homeFolder), entries: loadEntries(), labels: loadLabels(),
        ticked: on.sorted(), isOn: { on.contains($0) }, outcome: { failed.contains($0) ? .expired : nil })
    for row in rows {
        say((row.isOn ? "[x] " : "[ ] ") + row.title + (row.isEnabled ? "" : "\t(disabled)"))
    }
    exit(0)
}

if let id = argument("--server-once") {
    let short = String(id.prefix(8))
    guard let login = discoverLogins(home: homeFolder).first(where: { $0.organizationId == id }) else {
        say(short + "\t" + ServerOutcome.noLogin.text)
        exit(1)
    }
    // Before either way of asking, so neither reaches the keychain.
    guard !login.isExcluded else {
        say(short + "\t" + ServerOutcome.excluded.text)
        exit(1)
    }

    let dumpProfile = CommandLine.arguments.contains("--dump-profile-shape")
    if dumpProfile || CommandLine.arguments.contains("--dump-shape") {
        // Names and kinds only, of the login's part of the keychain item and
        // of the answer. Nothing is written. The profile form leaves the
        // keychain part out and asks the profile endpoint instead.
        DispatchQueue.global(qos: .utility).async {
            // Read once: a second read could mean a second keychain prompt.
            let item = readKeychainItem(service: login.service)
            if !dumpProfile {
                let fields = item.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                say("keychain claudeAiOauth:")
                jsonShape(fields?["claudeAiOauth"] ?? NSNull(), indent: "  ").forEach(say)
            }

            guard let token = item.flatMap(accessToken) else {
                say(short + "\t" + ServerOutcome.noKeychainItem.text)
                exit(1)
            }
            if let expires = token.expiresAt, expires <= Date().addingTimeInterval(60) {
                say(short + "\t" + ServerOutcome.expired.text)
                exit(1)
            }
            fetchOAuth(path: dumpProfile ? "/api/oauth/profile" : "/api/oauth/usage", token: token.token) { result in
                switch result {
                case .failure(let outcome):
                    say(short + "\t" + outcome.text)
                    exit(1)
                case .success(let data):
                    let answer = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
                    say(dumpProfile ? "profile:" : "response:")
                    jsonShape(answer, indent: "  ").forEach(say)
                    if dumpProfile {
                        // Does the answer name the organization? The place of
                        // each id and whether it is this login's, not the id.
                        for found in uuidPaths(answer, matching: login.organizationId) {
                            say(found.path + "\t" + (found.matches ? "matches-login" : "differs"))
                        }
                    }
                    exit(0)
                }
            }
        }
    } else {
        refreshFromServer(login, dataDir: dataFolder) { outcome in
            say(short + "\t" + outcome.text)
            exit(outcome == .ok ? 0 : 1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let path = argument("--snapshot") {
    exit(snapshot(to: path) ? 0 : 1)
}

allowCursorInBackground()
let controller = Controller()
controller.start()
app.run()
