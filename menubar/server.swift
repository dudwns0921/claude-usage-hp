import AppKit
import CryptoKit
import Foundation

// Server mode: for the accounts the person ticks in the menu, and only those,
// ask Anthropic's server for the usage windows with the login Claude Code keeps
// in the keychain, and write the answer to the same per-organization file the
// mod writes. The folder watcher then redraws the panel as for any other
// write, so nothing here draws.
//
// The access token is read from the keychain for each attempt, used for that
// attempt's requests (usage, and before it the profile when the token is a
// new one) and dropped. It is never stored, logged, passed as an argument
// or refreshed, and nothing is ever written to the keychain.

// Where the config folders are looked for. Another home is for tests.
let homeFolder = argument("--home") ?? NSHomeDirectory()

// The home the keychain belongs to, asked of the system's user record: unlike
// NSHomeDirectory() it cannot be pointed elsewhere from the environment.
let accountHome: String = {
    guard let record = getpwuid(getuid()), let folder = record.pointee.pw_dir else { return NSHomeDirectory() }
    return String(cString: folder)
}()

// MARK: - Finding the logins

// One config folder that is logged in: where its token is kept and whose it is.
struct Login {
    let configDir: String
    let service: String
    let email: String
    let organizationId: String
    let organization: String?
    let plan: String?

    // Found, and listed in the menu, but never read or asked for.
    var isExcluded: Bool { isExcludedFromServerMode(service: service) }
}

// The keychain item of the default config folder ("<home>/.claude").
let defaultKeychainService = "Claude Code-credentials"

// Server mode leaves the default config folder's login alone. The desktop app
// shares that folder's ".claude.json" and can put its own organization there
// while the keychain item still holds the terminal's token for another, and
// the reading would then go to the wrong organization's file. A ".claude-*"
// folder has only the terminal writing to it.
//
// This is the one place that decides it: logins, the token reader and the
// menu all ask here. The check that a token belongs to the organization the
// file names now exists (organizationOfToken, used in attemptRefresh), and an
// attempt is dropped when the two differ. That alone does not make this
// folder usable: its ".claude.json" flips between two organizations, so the
// check would refuse every other attempt. Before this can return false, the
// file to write must be chosen by the organization the token belongs to
// (which organizationOfToken already returns), not by what ".claude.json"
// says at that moment.
func isExcludedFromServerMode(service: String) -> Bool {
    service == defaultKeychainService
}

func withoutTrailingSlash(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
}

// The keychain item Claude Code uses for a config folder: the plain name for
// the default folder, and for any other the name plus the first eight hex
// digits of the SHA-256 of the folder's absolute path, exactly as written
// (no trailing slash, no "~").
func keychainService(configDir: String, home: String) -> String {
    let folder = withoutTrailingSlash(configDir)
    if folder == withoutTrailingSlash(home) + "/.claude" { return defaultKeychainService }
    let digest = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
    return defaultKeychainService + "-" + digest.prefix(8)
}

// The account a config file says it is logged in as. Both the email and the
// organization are needed: the file is named after the two.
func login(configDir: String, file: String, home: String) -> Login? {
    guard let data = FileManager.default.contents(atPath: file),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let account = root["oauthAccount"] as? [String: Any],
          let email = known(account["emailAddress"] as? String),
          let organizationId = known(account["organizationUuid"] as? String) else { return nil }
    return Login(
        configDir: configDir, service: keychainService(configDir: configDir, home: home), email: email,
        organizationId: organizationId, organization: known(account["organizationName"] as? String),
        plan: known(account["organizationType"] as? String))
}

// The default config folder's login, whatever server mode makes of it.
func defaultLogin(home: String) -> Login? {
    let home = withoutTrailingSlash(home)
    return login(configDir: home + "/.claude", file: home + "/.claude.json", home: home)
}

// One login per organization, found from the files alone (the keychain is
// not touched): the default folder's, then that of each ".claude-*" folder
// directly under the home that has its own ".claude.json". Where the default
// folder and a ".claude-*" folder are logged in to one organization, the
// ".claude-*" folder is the one used, since the default folder's cannot be;
// between two ".claude-*" folders the earlier name wins.
func discoverLogins(home: String) -> [Login] {
    let home = withoutTrailingSlash(home)
    var found: [Login] = []

    let names = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [])
        .filter { $0.hasPrefix(".claude-") }
        .sorted()
    for name in names {
        let folder = home + "/" + name
        guard let next = login(configDir: folder, file: folder + "/.claude.json", home: home),
              !found.contains(where: { $0.organizationId == next.organizationId }) else { continue }
        found.append(next)
    }

    // Still listed when it is the only login to its organization, so the
    // menu can say why that account cannot be ticked.
    if let first = defaultLogin(home: home),
       !found.contains(where: { $0.organizationId == first.organizationId }) {
        found.insert(first, at: 0)
    }
    return found
}

// MARK: - From the server's answer to the file

typealias ServerLimit = (kind: String, percentUsed: Double, resetsAt: Date?)

// The two windows asked of the server. The answer holds more (per-model weeks,
// extra usage); those are not taken, since the panel's height is its windows.
let serverWindows = ["five_hour", "seven_day"]

// An ISO 8601 time to the nearest second. The server has been seen to send
// both "...Z" and "...59.943648+00:00"; the fraction is taken out by hand,
// since the system's parser accepts three digits of it and no other count.
func parseServerDate(_ text: String) -> Date? {
    var whole = text
    var fraction = 0.0

    if let point = text.firstIndex(of: ".") {
        let after = text[text.index(after: point)...]
        let digits = after.prefix { $0.isASCII && $0.isNumber }
        fraction = Double("0." + digits) ?? 0
        whole = String(text[..<point]) + after.dropFirst(digits.count)
    }

    guard let date = ISO8601DateFormatter().date(from: whole) else { return nil }
    return Date(timeIntervalSince1970: (date.timeIntervalSince1970 + fraction).rounded())
}

// The form the mod writes: "2099-01-01T05:00:00.000Z".
func fileDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

// The windows in an answer, or nil when it is not JSON or holds neither, so
// that an empty answer never replaces a good reading.
func serverLimits(from response: Data) -> [ServerLimit]? {
    guard let root = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] else { return nil }
    var limits: [ServerLimit] = []

    for kind in serverWindows {
        guard let window = root[kind] as? [String: Any],
              let used = (window["utilization"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
        let reset = (window["resets_at"] as? String).flatMap(parseServerDate)
        limits.append((kind, max(used, 0), reset))
    }
    return limits.isEmpty ? nil : limits
}

// The same rule as the mod's file names.
func safeName(_ text: String) -> String {
    String(text.unicodeScalars.map { scalar -> Character in
        let keep = scalar.isASCII
            && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
        return keep ? Character(scalar) : "_"
    })
}

func readingPath(_ login: Login, dataDir: String) -> String {
    dataDir + "/" + safeName(login.email) + "__" + safeName(login.organizationId) + ".json"
}

// What is at a reading's path before a write.
enum ExistingReading {
    case none
    case readable([String: Any])
    // There, but not a JSON object: most likely caught half written.
    // Starting over from nothing would lose what it holds.
    case unreadable
}

func existingReading(atPath path: String) -> ExistingReading {
    guard FileManager.default.fileExists(atPath: path) else { return .none }
    guard let data = FileManager.default.contents(atPath: path),
          let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
    return .readable(file)
}

// Writes the windows to the login's file, as the mod would. The mod writes the
// same file and the later write stands, both being readings of one counter.
// Keys this app does not know are kept as they are, and so are windows of
// other kinds. A new file or folder is the person's alone, as the mod's are:
// the file holds an email address.
func writeServerReading(_ limits: [ServerLimit], login: Login, dataDir: String, now: Date) -> Bool {
    guard !limits.isEmpty else { return false }
    let path = readingPath(login, dataDir: dataDir)
    var isNew = false
    var file: [String: Any] = [:]

    switch existingReading(atPath: path) {
    case .none: isNew = true
    case .readable(let before): file = before
    // This write fails, and the next attempt may find the file whole.
    case .unreadable: return false
    }

    // A reset time the file already has for a window is kept when it is still
    // ahead and within a minute of the server's. The mod compares these
    // strings exactly to tell one organization's window from another's, and
    // the two sources can be a few seconds apart for the same reset.
    let before = (file["limits"] as? [[String: Any]]) ?? []
    var written: [String: String] = [:]
    for old in before {
        if let kind = old["kind"] as? String, let text = old["resetsAt"] as? String { written[kind] = text }
    }
    // The mod writes every window a session reports. Only the two asked of
    // the server are replaced; the rest stay, after them, or the block would
    // change height each time the two writers took turns.
    let others = before.filter { !serverWindows.contains(($0["kind"] as? String) ?? "") }

    file["limits"] = limits.map { limit -> [String: Any] in
        // As a decimal, so 30.975 is written as that and not with the
        // sixteen digits a binary number would print.
        var entry: [String: Any] = ["kind": limit.kind, "percentUsed": NSDecimalNumber(string: "\(limit.percentUsed)")]
        if let reset = limit.resetsAt {
            if let text = written[limit.kind], let before = parseDate(text), before > now,
               abs(before.timeIntervalSince(reset)) <= 60 {
                entry["resetsAt"] = text
            } else {
                entry["resetsAt"] = fileDate(reset)
            }
        }
        return entry
    } + others

    file["account"] = login.email
    file["organizationId"] = login.organizationId
    file["source"] = "server"
    file["updatedAt"] = fileDate(now)
    // What the file already says stands where the login does not know.
    if let organization = login.organization { file["organization"] = organization }
    if let plan = login.plan { file["plan"] = plan }

    guard let data = try? JSONSerialization.data(
        withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
    try? FileManager.default.createDirectory(
        atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return false }
    // A file that was there keeps the permissions it had.
    if isNew { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    return true
}

// MARK: - The token and the request

enum ServerOutcome: Equatable, Error {
    // `excluded`: the only login to the account is one server mode leaves
    // alone (isExcludedFromServerMode); nothing was read or asked.
    // `unreadableFile`: the account's file is there and does not read, so
    // nothing could be written; nothing was read or asked.
    // `wrongOrganization`: the token in the keychain belongs to another
    // organization than the config folder names; usage was not asked.
    case ok, noLogin, excluded, unreadableFile, noKeychainItem, expired, unauthorized, wrongOrganization
    case rateLimited(retryAfter: TimeInterval?), noData, offline, serverError(Int)

    // For the debug line and the command line; never more than the kind.
    var text: String {
        switch self {
        case .ok: return "ok"
        case .noLogin: return "noLogin"
        case .excluded: return "excluded"
        case .unreadableFile: return "unreadableFile"
        case .wrongOrganization: return "wrongOrganization"
        case .noKeychainItem: return "noKeychainItem"
        case .expired: return "expired"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rateLimited"
        case .noData: return "noData"
        case .offline: return "offline"
        case .serverError(let status): return "serverError(\(status))"
        }
    }
}

let keychainSeconds: TimeInterval = 5
let requestSeconds: TimeInterval = 10

// Holds what a background read hands back to the thread waiting for it.
private final class Collected {
    var data = Data()
}

// What the keychain item holds, read with the system's own `security` tool.
// Claude Code made the item with that tool, so the tool reads it without a
// prompt, and a prompt that does come is answered for `security`, not for
// this binary, which changes with every build. Blocks for up to five seconds:
// never call it on the main thread.
//
// USAGE_HP_SECURITY_BIN names another tool to run in its place. It is for
// tests, and it is only the path of a reader, not a secret.
func keychainTool(home: String) -> String? {
    if let stand = known(ProcessInfo.processInfo.environment["USAGE_HP_SECURITY_BIN"]) { return stand }
    // Another home is a test's. Its default folder has the same item name as
    // the real default login, so the real tool would hand a test that login;
    // without a stand-in the item counts as missing and nothing is run.
    guard withoutTrailingSlash(home) == withoutTrailingSlash(accountHome) else { return nil }
    return "/usr/bin/security"
}

func readKeychainItem(service: String) -> Data? {
    // Every keychain read goes through here, so this holds whatever a caller
    // forgot to ask.
    guard !isExcludedFromServerMode(service: service) else {
        debug("usage-hp: keychain not read (the default config folder is left alone)")
        return nil
    }
    guard let tool = keychainTool(home: homeFolder) else {
        debug("usage-hp: keychain not read (another home and no USAGE_HP_SECURITY_BIN)")
        return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    guard (try? process.run()) != nil else { return nil }

    // Read while it runs, so a long value cannot fill the pipe and stall it.
    let collected = Collected()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
        finished.signal()
    }

    // Stuck, most likely behind a keychain prompt nobody is answering: give
    // up, so the next tick does not put a second prompt on top of this one.
    if exited.wait(timeout: .now() + keychainSeconds) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        return nil
    }

    guard finished.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
    return collected.data
}

// The access token of a login and when it runs out, or nil when the item is
// missing, unreadable or not in the form Claude Code writes.
func readAccessToken(service: String) -> (token: String, expiresAt: Date?)? {
    readKeychainItem(service: service).flatMap(accessToken)
}

func accessToken(in item: Data) -> (token: String, expiresAt: Date?)? {
    guard let root = (try? JSONSerialization.jsonObject(with: item)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
    // Milliseconds since 1970.
    let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    return (token, expires)
}

// Where the requests go. USAGE_HP_API_BASE names another address, for tests:
// it is read only with another home (--home), where no real token is ever
// read, and only when it is this machine's own loopback address.
func apiBase(home: String) -> String {
    let real = "https://api.anthropic.com"
    guard withoutTrailingSlash(home) != withoutTrailingSlash(accountHome),
          let stand = known(ProcessInfo.processInfo.environment["USAGE_HP_API_BASE"]),
          let host = URL(string: stand)?.host, host == "127.0.0.1" || host == "localhost" else { return real }
    return withoutTrailingSlash(stand)
}

// One GET of the usage windows. The endpoint is not a documented one: its
// address, headers and answer are as read from public tools that use it, and
// any of them may change.
func fetchUsage(token: String, completion: @escaping (Result<Data, ServerOutcome>) -> Void) {
    fetchOAuth(path: "/api/oauth/usage", token: token, completion: completion)
}

// Refuses every redirect, so the answer is the redirect itself (a status that
// is not 200) and never whatever another address says. The system drops the
// token when it follows one, but that is its choice and not a promise.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// One GET under the same address with the same headers. Sent from inside
// this process, so the token is never an argument another process could
// list; no cache and no cookies.
func fetchOAuth(path: String, token: String, completion: @escaping (Result<Data, ServerOutcome>) -> Void) {
    guard let url = URL(string: apiBase(home: homeFolder) + path) else {
        completion(.failure(.offline))
        return
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestSeconds)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("usage-hp-menubar", forHTTPHeaderField: "User-Agent")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = requestSeconds
    configuration.timeoutIntervalForResource = requestSeconds
    let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)

    session.dataTask(with: request) { data, response, _ in
        defer { session.finishTasksAndInvalidate() }
        guard let http = response as? HTTPURLResponse else {
            completion(.failure(.offline))
            return
        }

        switch http.statusCode {
        case 200:
            completion(.success(data ?? Data()))
        case 401, 403:
            completion(.failure(.unauthorized))
        case 429:
            // Only the form in seconds; a date is treated as not given.
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            completion(.failure(.rateLimited(retryAfter: wait)))
        default:
            completion(.failure(.serverError(http.statusCode)))
        }
    }.resume()
}

// MARK: - Whose token it is

// The organization a token belongs to, as the server says.
struct TokenOrganization {
    let uuid: String
    let name: String?
    let type: String?
}

// The organization in a profile answer, or nil when it is not JSON or names
// none.
func tokenOrganization(inProfile answer: Data) -> TokenOrganization? {
    guard let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
          let organization = root["organization"] as? [String: Any],
          let uuid = known(organization["uuid"] as? String) else { return nil }
    return TokenOrganization(
        uuid: uuid, name: known(organization["name"] as? String),
        type: known(organization["organization_type"] as? String))
}

// The organizations already asked for, by keychain item. Claude Code writes a
// new expiry with every new token, so the same item with the same expiry is
// taken as the same token and not asked about again. Kept in memory only: on
// disk it would outlive the login it describes. Nothing of the token itself
// is kept.
private final class KnownOrganizations {
    private let lock = NSLock()
    private var known: [String: (expiresAt: Date, organization: TokenOrganization)] = [:]

    func organization(service: String, expiresAt: Date) -> TokenOrganization? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = known[service], entry.expiresAt == expiresAt else { return nil }
        return entry.organization
    }

    func remember(_ organization: TokenOrganization, service: String, expiresAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        known[service] = (expiresAt, organization)
    }
}

private let knownOrganizations = KnownOrganizations()

// Which organization the token just read from `service` belongs to. This is
// only the question; what to do with the answer is the caller's (today:
// refuse when it is not the login's; later: pick the file by it). Costs one
// profile request per new token. A token with no expiry cannot be told from
// the one before it, so it is asked about every time.
func organizationOfToken(service: String, token: String, expiresAt: Date?,
                         completion: @escaping (Result<TokenOrganization, ServerOutcome>) -> Void) {
    if let expiresAt, let found = knownOrganizations.organization(service: service, expiresAt: expiresAt) {
        completion(.success(found))
        return
    }
    fetchOAuth(path: "/api/oauth/profile", token: token) { result in
        switch result {
        case .failure(let outcome):
            completion(.failure(outcome))
        case .success(let data):
            guard let organization = tokenOrganization(inProfile: data) else {
                completion(.failure(.noData))
                return
            }
            if let expiresAt { knownOrganizations.remember(organization, service: service, expiresAt: expiresAt) }
            completion(.success(organization))
        }
    }
}

// Organization ids are UUIDs, and the two sources need not agree on case.
func isSameOrganization(_ one: String, _ other: String) -> Bool {
    one.caseInsensitiveCompare(other) == .orderedSame
}

// A token the server turned down, known by when it runs out: asking again
// with the same one would only be turned down again.
struct RejectedToken {
    let expiresAt: Date?
    let at: Date

    // Whether a token read now is still the one turned down. One with no
    // expiry cannot be told from its replacement, so it counts as the same
    // only for a while, and is then tried again.
    func stillHolds(for expires: Date?, now: Date) -> Bool {
        guard expiresAt == expires else { return false }
        return expires != nil || now < at.addingTimeInterval(ServerPoller.longestDelay)
    }
}

// One whole attempt for one login: keychain, whose token it is, request,
// file. Every write of a reading that came from the server goes through
// here (the poller, "지금 갱신", --server-once), so this is where a token of
// another organization is stopped. The completion is called on the main
// queue with the outcome and the expiry of the token read.
// `shouldWrite` is asked on the main queue just before the file is written,
// so an answer that comes back after the account was unticked is dropped.
func attemptRefresh(_ login: Login, dataDir: String, rejected: RejectedToken?,
                    shouldWrite: @escaping () -> Bool,
                    completion: @escaping (ServerOutcome, Date?) -> Void) {
    guard !login.isExcluded else {
        DispatchQueue.main.async { completion(.excluded, nil) }
        return
    }
    DispatchQueue.global(qos: .utility).async {
        func finish(_ outcome: ServerOutcome, _ expires: Date?) {
            DispatchQueue.main.async { completion(outcome, expires) }
        }

        // Before anything is read or asked: with a file that cannot be
        // written over, the answer would have nowhere to go.
        if case .unreadable = existingReading(atPath: readingPath(login, dataDir: dataDir)) {
            finish(.unreadableFile, nil)
            return
        }

        guard let item = readAccessToken(service: login.service) else {
            finish(.noKeychainItem, nil)
            return
        }
        let expires = item.expiresAt

        // Run out, or about to: Claude Code refreshes it the next time it
        // runs with this config folder. This app never does, because a
        // refresh would have to write the new token back to the keychain.
        if let expires, expires <= Date().addingTimeInterval(60) {
            finish(.expired, expires)
            return
        }
        if let rejected, rejected.stillHolds(for: expires, now: Date()) {
            finish(.unauthorized, expires)
            return
        }

        // The config folder and the keychain item are two things, and after a
        // "/login" to another organization they can disagree for a while. A
        // reading goes to the login's file only once the server has said the
        // token is that organization's; a failure to find out fails the
        // attempt as the same failure of the usage request would.
        organizationOfToken(service: login.service, token: item.token, expiresAt: expires) { whose in
            switch whose {
            case .failure(let outcome):
                finish(outcome, expires)
                return
            case .success(let organization):
                guard isSameOrganization(organization.uuid, login.organizationId) else {
                    finish(.wrongOrganization, expires)
                    return
                }
            }

            fetchUsage(token: item.token) { result in
                switch result {
                case .failure(let outcome):
                    finish(outcome, expires)
                case .success(let data):
                    guard let limits = serverLimits(from: data) else {
                        finish(.noData, expires)
                        return
                    }
                    DispatchQueue.main.async {
                        // Unticked meanwhile: nothing is written, and the
                        // caller no longer keeps an outcome for this account.
                        guard shouldWrite() else {
                            completion(.noLogin, expires)
                            return
                        }
                        let wrote = writeServerReading(limits, login: login, dataDir: dataDir, now: Date())
                        completion(wrote ? .ok : .noData, expires)
                    }
                }
            }
        }
    }
}

func refreshFromServer(_ login: Login, dataDir: String, completion: @escaping (ServerOutcome) -> Void) {
    attemptRefresh(login, dataDir: dataDir, rejected: nil, shouldWrite: { true }) { outcome, _ in
        completion(outcome)
    }
}

// The names in a JSON value and the kind of each value, never a value itself.
func jsonShape(_ value: Any, indent: String = "") -> [String] {
    func kind(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        return "?"
    }

    if let object = value as? [String: Any] {
        return object.keys.sorted().flatMap { key -> [String] in
            let inner = object[key] ?? NSNull()
            return [indent + key + ": " + kind(inner)] + jsonShape(inner, indent: indent + "  ")
        }
    }
    if let list = value as? [Any], let first = list.first {
        return [indent + "[0]: " + kind(first)] + jsonShape(first, indent: indent + "  ")
    }
    return []
}

// The key path of every string in a JSON value that has the form of a UUID,
// and whether it is `id` (case does not matter). Never the string itself.
func uuidPaths(_ value: Any, matching id: String, path: String = "") -> [(path: String, matches: Bool)] {
    if let object = value as? [String: Any] {
        return object.keys.sorted().flatMap { key in
            uuidPaths(object[key] ?? NSNull(), matching: id, path: path.isEmpty ? key : path + "." + key)
        }
    }
    if let list = value as? [Any] {
        return list.enumerated().flatMap { index, inner in
            uuidPaths(inner, matching: id, path: path + "[\(index)]")
        }
    }
    guard let text = value as? String, UUID(uuidString: text) != nil else { return [] }
    return [(path, text.caseInsensitiveCompare(id) == .orderedSame)]
}

// MARK: - Polling

// Asks for the ticked accounts on a timer, one request at a time. All of its
// state is touched on the main queue only.
final class ServerPoller {
    static let interval: TimeInterval = 300
    static let longestDelay: TimeInterval = 3600
    // How often it looks for an account whose time has come.
    static let tick: TimeInterval = 30
    static let key = "serverOrganizations"

    // Called when a choice or an outcome changes: the menu and the panel's
    // marks are drawn from them.
    var onChange: (() -> Void)?
    private(set) var isBusy = false

    private struct State {
        var due = Date.distantPast
        var delay = ServerPoller.interval
        var outcome: ServerOutcome?
        var rejected: RejectedToken?
    }

    private let home: String
    private let dataDir: String
    // The choice is kept in the app's settings, unless it was given for this
    // run only.
    private let isKept: Bool
    private var chosen: Set<String>
    private var states: [String: State] = [:]
    private var timer: Timer?
    private var afterWake: DispatchWorkItem?

    init(home: String, dataDir: String, onlyThisRun: [String]? = nil) {
        self.home = home
        self.dataDir = dataDir
        isKept = onlyThisRun == nil
        chosen = Set(onlyThisRun ?? settings.stringArray(forKey: ServerPoller.key) ?? [])
    }

    var organizations: [String] { chosen.sorted() }

    func isOn(_ organizationId: String) -> Bool { chosen.contains(organizationId) }

    // The last attempt's outcome, nil before the first.
    func outcome(_ organizationId: String) -> ServerOutcome? { states[organizationId]?.outcome }

    // Ticking an account asks for it at once.
    func setOn(_ organizationId: String, _ on: Bool) {
        if on { chosen.insert(organizationId) } else { chosen.remove(organizationId) }
        states[organizationId] = nil
        if isKept { settings.set(chosen.sorted(), forKey: ServerPoller.key) }
        onChange?()
        if on { tick() }
    }

    // Asks now for every ticked account, whatever wait a failure had set. An
    // account stopped for a turned-down token stays stopped: its attempt
    // still ends at the keychain unless the token there is a new one.
    func refreshNow() {
        for id in chosen { states[id, default: State()].due = .distantPast }
        tick()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopTimer()
        }
        // The network is not up the moment the Mac wakes. However long it
        // slept, each account is asked once: an account has one due time, not
        // a queue of missed ones.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stopTimer()
            let work = DispatchWorkItem { [weak self] in
                self?.startTimer()
                self?.tick()
            }
            self.afterWake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        }

        startTimer()
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        let made = Timer(timeInterval: ServerPoller.tick, repeats: true) { [weak self] _ in self?.tick() }
        made.tolerance = 5
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func stopTimer() {
        afterWake?.cancel()
        afterWake = nil
        timer?.invalidate()
        timer = nil
    }

    // How long to wait after an outcome, given the wait before it. Infinity
    // means stopped: no request until the keychain holds another token.
    func nextDelay(after outcome: ServerOutcome, previous: TimeInterval) -> TimeInterval {
        let longer = previous < ServerPoller.interval * 2
            ? ServerPoller.interval * 2 : min(previous * 2, ServerPoller.longestDelay)

        switch outcome {
        case .ok, .noLogin, .excluded, .unreadableFile, .noKeychainItem, .wrongOrganization:
            // All but the first never asked for usage; looking again is
            // cheap. A token of another organization is asked about once and
            // then remembered, and the folder and the keychain usually agree
            // again within moments of a "/login".
            return ServerPoller.interval
        case .expired, .unauthorized:
            return .infinity
        case .rateLimited(let retryAfter):
            return max(longer, retryAfter ?? 0)
        case .offline, .serverError, .noData:
            return longer
        }
    }

    private func tick() {
        guard !isBusy else { return }
        let now = Date()
        let due = organizations.filter { (states[$0]?.due ?? .distantPast) <= now }
        guard !due.isEmpty else { return }

        // The folders are read again each time: a config folder can be logged
        // in to another organization since the last look, and a reading must
        // go to the file of the organization the folder is in now.
        let logins = discoverLogins(home: home)
        isBusy = true
        onChange?()
        ask(due[...], logins)
    }

    private func ask(_ waiting: ArraySlice<String>, _ logins: [Login]) {
        guard let id = waiting.first else {
            isBusy = false
            onChange?()
            return
        }
        let rest = waiting.dropFirst()

        guard isOn(id) else {
            ask(rest, logins)
            return
        }
        // No folder is logged in to it: neither the keychain nor the server
        // is touched.
        guard let login = logins.first(where: { $0.organizationId == id }) else {
            record(id, .noLogin, expires: nil)
            ask(rest, logins)
            return
        }

        attemptRefresh(
            login, dataDir: dataDir, rejected: states[id]?.rejected,
            shouldWrite: { [weak self] in self?.isOn(id) ?? false }
        ) { [weak self] outcome, expires in
            guard let self else { return }
            if self.isOn(id) { self.record(id, outcome, expires: expires) }
            self.ask(rest, logins)
        }
    }

    private func record(_ id: String, _ outcome: ServerOutcome, expires: Date?) {
        var state = states[id] ?? State()
        let wait = nextDelay(after: outcome, previous: state.delay)
        state.outcome = outcome
        // A stopped account is looked at again at the usual pace, and that
        // look ends at the keychain until the token there has changed.
        state.delay = wait.isFinite ? wait : ServerPoller.interval
        state.due = Date().addingTimeInterval(state.delay)

        switch outcome {
        case .unauthorized:
            // Not when the attempt only met the token already turned down:
            // the time it was turned down at is what lets one with no expiry
            // be tried again.
            let now = Date()
            if state.rejected?.stillHolds(for: expires, now: now) != true {
                state.rejected = RejectedToken(expiresAt: expires, at: now)
            }
        case .noLogin, .excluded, .unreadableFile, .noKeychainItem:
            // No token was read, so nothing is known to have changed.
            break
        default:
            state.rejected = nil
        }

        states[id] = state
        debug("usage-hp: server \(id.prefix(8)) \(outcome.text)")
        onChange?()
    }
}
