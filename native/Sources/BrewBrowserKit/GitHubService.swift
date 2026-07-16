//
//  GitHubService.swift
//  BrewBrowser (native macOS port)
//
//  Native Swift 6 / SwiftUI port of the Tauri app's GitHub integration.
//  This is a faithful re-implementation of the Rust modules under
//  `src-tauri/src/github/`:
//
//    - OAuth Device Flow (RFC 8628) sign-in  ⟵ `github/auth.rs`
//    - macOS Keychain token/scope/username storage ⟵ `github/auth.rs`
//    - Read-only repo stats ⟵ `github/stats.rs`
//    - Authenticated star / watch / file-issue actions ⟵ `github/actions.rs`
//    - Strict `github.com/<owner>/<repo>` URL allowlist
//      ⟵ `github/url.rs` + `commands/github.rs` (`parse_github_url`)
//
//  Design notes carried over from the Rust source:
//    * The OAuth `client_id` is public (RFC 8628 §3.1) and hardcoded —
//      see `auth.rs:81-93`.
//    * The access token lives ONLY in the Keychain. It is never returned
//      from any public method here; the `GithubStatus` value is the
//      derived "what can this session do?" view, mirroring
//      `GithubStatusDto` in `auth.rs:183-189`.
//    * Authed actions re-validate the (owner, repo) pair defensively
//      before every request — `actions.rs:340-377`.
//
//  Self-contained: depends on no other BrewBrowser app types, only
//  Foundation + Security.framework.
//

import Foundation
import Security

// MARK: - Public value types

/// Read-only repository statistics.
///
/// Mirrors `RepoStats` in `src-tauri/src/github/stats.rs:62-87`. Field
/// origins (all from `GET /repos/{owner}/{repo}` unless noted):
///   - `stars`          ⟵ `stargazers_count`
///   - `forks`          ⟵ `forks_count`
///   - `openIssues`     ⟵ `open_issues_count`
///   - `archived`       ⟵ `archived`
///   - `archivedAt`     ⟵ `archived_at`
///   - `licenseSpdx`    ⟵ `license.spdx_id`
///   - `primaryLanguage`⟵ `language`
///   - `lastReleaseTag` / `lastReleaseDate` ⟵ `GET /repos/{o}/{r}/releases/latest`
///     (falls back to `GET /repos/{o}/{r}/tags?per_page=1` for repos that
///     only ship tags), per `stats.rs:226-273`.
public struct RepoStats: Sendable, Hashable {
    public var owner: String
    public var repo: String
    public var stars: Int
    public var forks: Int
    public var openIssues: Int
    public var lastReleaseTag: String?
    public var lastReleaseDate: String?
    public var archived: Bool
    /// `archived_at` from the repo payload, ISO 8601. Absent for live repos.
    public var archivedAt: String?
    public var licenseSpdx: String?
    public var primaryLanguage: String?

    public init(
        owner: String,
        repo: String,
        stars: Int,
        forks: Int,
        openIssues: Int,
        lastReleaseTag: String?,
        lastReleaseDate: String?,
        archived: Bool,
        archivedAt: String?,
        licenseSpdx: String?,
        primaryLanguage: String?
    ) {
        self.owner = owner
        self.repo = repo
        self.stars = stars
        self.forks = forks
        self.openIssues = openIssues
        self.lastReleaseTag = lastReleaseTag
        self.lastReleaseDate = lastReleaseDate
        self.archived = archived
        self.archivedAt = archivedAt
        self.licenseSpdx = licenseSpdx
        self.primaryLanguage = primaryLanguage
    }
}

/// Derived sign-in status. Contains NO token — mirrors `GithubStatusDto`
/// in `auth.rs:183-189`. Read purely from the Keychain.
public struct GithubStatus: Sendable, Hashable {
    public var signedIn: Bool
    public var username: String?
    public var scopes: [String]

    public init(signedIn: Bool, username: String?, scopes: [String]) {
        self.signedIn = signedIn
        self.username = username
        self.scopes = scopes
    }

    /// The "not signed in" shape, matching `auth.rs:326-332`.
    static let signedOut = GithubStatus(signedIn: false, username: nil, scopes: [])
}

/// Result of starting the OAuth Device Flow. Mirrors `DeviceFlowStart`
/// in `auth.rs:195-203`. The `deviceCode` is opaque to the UI — it is
/// only passed back into `pollDeviceFlow`.
public struct DeviceFlowStart: Sendable, Hashable {
    public var userCode: String
    public var verificationUri: String
    public var deviceCode: String
    public var interval: Int
    public var expiresIn: Int

    public init(
        userCode: String,
        verificationUri: String,
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) {
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// Typed errors surfaced by `GitHubService`. Mirrors the relevant arms
/// of `BrewError` used by the GitHub modules:
///   - `authRequired`        ⟵ `BrewError::AuthRequired` (`github.rs:185`)
///   - `scopeRequired(_)`    ⟵ `BrewError::ScopeRequired { scope }` (`github.rs:191`)
///   - `rateLimited(_)`      ⟵ `BrewError::GithubRateLimited { reset_at }`
///                              (`stats.rs:301-315`, `actions.rs:381-401`)
///   - `notAGithubURL`       ⟵ the `InvalidArgument` "not a github.com/<o>/<r>"
///                              path in `github.rs:180-182`
///   - `http(_)`             ⟵ `BrewError::HttpStatus { status }`
///   - `network(_)`          ⟵ `BrewError::Network { message }`
public enum GithubError: Error, LocalizedError, Sendable, Equatable {
    case authRequired
    case scopeRequired(String)
    case rateLimited(resetAt: String?)
    case notAGithubURL
    case http(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .authRequired:
            return L10n.isRussian
                ? "Для этого действия нужно войти в GitHub."
                : "GitHub sign-in is required for this action."
        case .scopeRequired(let scope):
            return L10n.isRussian
                ? "GitHub-токену не хватает разрешения \(scope). Войдите в GitHub ещё раз."
                : "GitHub token is missing the \(scope) scope. Sign in again."
        case .rateLimited(let resetAt):
            if L10n.isRussian {
                if let resetAt { return "GitHub ограничил частоту запросов. Повторите после \(resetAt)." }
                return "GitHub ограничил частоту запросов. Повторите позже."
            }
            if let resetAt { return "GitHub rate limit reached. Try again after \(resetAt)." }
            return "GitHub rate limit reached. Try again later."
        case .notAGithubURL:
            return L10n.isRussian
                ? "Это не ссылка GitHub вида github.com/<owner>/<repo>."
                : "This is not a GitHub URL in the form github.com/<owner>/<repo>."
        case .http(let status):
            return L10n.isRussian
                ? "GitHub вернул HTTP \(status)."
                : "GitHub returned HTTP \(status)."
        case .network(let message):
            if L10n.isRussian {
                switch message {
                case "access denied":
                    return "Авторизация GitHub отклонена."
                case "device code expired":
                    return "Код входа GitHub истёк. Начните вход заново."
                case "malformed device/code response":
                    return "GitHub вернул некорректный ответ для device flow."
                case "device flow returned neither access_token nor error":
                    return "GitHub не вернул ни токен доступа, ни ошибку device flow."
                case "malformed repo response":
                    return "GitHub вернул некорректные данные репозитория."
                case "create_issue returned no number/html_url":
                    return "GitHub создал issue, но не вернул номер или ссылку."
                case "/user returned empty login":
                    return "GitHub не вернул имя пользователя."
                case "issue title must not be empty":
                    return "Заголовок issue не может быть пустым."
                default:
                    if message.hasPrefix("github device flow error: ") {
                        let raw = String(message.dropFirst("github device flow error: ".count))
                        return "GitHub вернул ошибку device flow: \(raw)."
                    }
                    if message.hasPrefix("bad url: ") {
                        let url = String(message.dropFirst("bad url: ".count))
                        return "Некорректный URL GitHub: \(url)."
                    }
                    if message.hasPrefix("non-HTTP response from ") {
                        let url = String(message.dropFirst("non-HTTP response from ".count))
                        return "GitHub вернул не-HTTP ответ от \(url)."
                    }
                    if message.hasPrefix("issue title exceeds ") {
                        return "Заголовок issue слишком длинный."
                    }
                    if message.hasPrefix("issue body exceeds ") {
                        return "Текст issue слишком длинный."
                    }
                    if message.hasPrefix("too many labels") {
                        return "Слишком много меток issue."
                    }
                    if message.hasPrefix("label length must be ") {
                        return "Недопустимая длина метки issue."
                    }
                    if message.hasPrefix("label contains invalid character: ") {
                        let label = String(message.dropFirst("label contains invalid character: ".count))
                        return "Метка issue содержит недопустимый символ: \(label)."
                    }
                    return "Ошибка GitHub: \(message)"
                }
            }
            return message
        }
    }
}

// MARK: - GitHubService

/// Actor wrapping the GitHub integration. All mutable interaction with
/// the Keychain + network is serialized through the actor.
public struct GitHubService: Sendable {

    // MARK: Constants (mirrored from the Rust source)

    /// macOS Keychain service identifier. **Must match the app bundle
    /// identifier.** Verbatim from `auth.rs:65` (`KEYCHAIN_SERVICE`).
    private static let keychainService = "com.zerologic.brew-browser"

    /// Keychain account names. Verbatim from `auth.rs:69-79`.
    /// Renaming these would orphan tokens already in users' Keychains.
    private static let accountToken = "github_access_token"        // KEYCHAIN_ACCOUNT_TOKEN
    private static let accountScopes = "github_access_token_scopes" // KEYCHAIN_ACCOUNT_SCOPES
    private static let accountUsername = "github_username"          // KEYCHAIN_ACCOUNT_USERNAME
    /// Combined credential item (token + username + scopes as one JSON blob).
    /// ONE Keychain item = ONE access = ONE prompt, in dev AND prod — the legacy
    /// three-item layout above needs three single-item reads (three prompts) in
    /// dev, because a `kSecMatchLimitAll` batch silently skips consent-required
    /// items instead of prompting. Reads migrate the legacy items into this.
    private static let accountCredential = "github_credential_v1"

    /// OAuth Device Flow client identifier. Public per RFC 8628 §3.1.
    /// Verbatim from `auth.rs:93` (`GITHUB_OAUTH_CLIENT_ID`).
    private static let oauthClientId = "Ov23liJZKbvrSBuiOPkT"

    /// OAuth scopes requested at sign-in. Verbatim from `auth.rs:111`
    /// (`GITHUB_OAUTH_SCOPES`). Kept minimum:
    ///   - `read:user`     — show "Signed in as @username"
    ///   - `public_repo`   — star/unstar + create issues
    ///   - `notifications` — watch/unwatch (the subscription endpoint
    ///                       requires this specifically; `public_repo`
    ///                       alone returns 404)
    private static let oauthScopes = ["read:user", "public_repo", "notifications"]

    /// Per-action scope requirements, mirroring `github.rs:41-42`.
    private static let scopePublicRepo = "public_repo"
    private static let scopeNotifications = "notifications"

    // Endpoints. From `auth.rs:115-117` and `stats.rs`/`actions.rs:78`.
    private static let deviceCodeURL = "https://github.com/login/device/code"          // auth.rs:115
    private static let tokenURL = "https://github.com/login/oauth/access_token"        // auth.rs:116
    private static let userURL = "https://api.github.com/user"                         // auth.rs:117
    private static let apiBase = "https://api.github.com"                              // stats.rs:56 / actions.rs:78

    // Polling bounds, from `auth.rs:127-132`.
    private static let minPollIntervalSecs = 5
    private static let maxExpiresInSecs = 60 * 60

    // Issue input caps, from `actions.rs:63-72`.
    private static let issueTitleMaxChars = 256
    private static let issueBodyMaxBytes = 64 * 1024
    private static let issueLabelsMaxCount = 10
    private static let issueLabelMaxChars = 50

    /// User-Agent for every GitHub round-trip. Matches the Rust UA
    /// shape (`stats.rs:49-53` / `actions.rs:80-84`).
    private static let userAgent = "brew-browser-native (+https://github.com/msitarzewski/brew-browser)"

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Status / sign-out (Keychain only, no network)

    /// Current sign-in status, read entirely from the Keychain. No
    /// network. Mirrors `auth::status` / `status_with` (`auth.rs:324-348`)
    /// and the `github_status` command (`github.rs:96-101`).
    public func status() -> GithubStatus {
        // One Keychain access (the combined credential item) = one prompt.
        guard let cred = Self.readCredential() else { return .signedOut }
        return GithubStatus(signedIn: true, username: cred.username, scopes: cred.scopes)
    }

    /// Delete every stored credential. Idempotent. Mirrors
    /// `auth::signout` / `signout_with` (`auth.rs:393-403`) and the
    /// `github_signout` command (`github.rs:131-136`).
    public func signOut() {
        Self.keychainDelete(account: Self.accountCredential)
        // Clean up any legacy three-item layout too.
        Self.keychainDelete(account: Self.accountToken)
        Self.keychainDelete(account: Self.accountUsername)
        Self.keychainDelete(account: Self.accountScopes)
    }

    // MARK: - Device Flow

    /// POST `client_id` + scope to `https://github.com/login/device/code`
    /// and return the user-facing code + polling parameters. Mirrors
    /// `auth::start_device_flow` (`auth.rs:423-489`).
    ///
    /// Does NOT start the polling loop — call `pollDeviceFlow` with the
    /// returned `deviceCode`.
    public func startDeviceFlow() async throws -> DeviceFlowStart {
        let scope = Self.oauthScopes.joined(separator: " ")
        let form = [
            "client_id": Self.oauthClientId,
            "scope": scope,
        ]
        let (data, http) = try await postForm(urlString: Self.deviceCodeURL, form: form)
        guard (200...299).contains(http.statusCode) else {
            throw GithubError.http(http.statusCode)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let verificationUri = json["verification_uri"] as? String
        else {
            throw GithubError.network("malformed device/code response")
        }
        // Clamp interval + expires_in defensively, per `auth.rs:478-480`.
        let rawInterval = (json["interval"] as? Int) ?? Self.minPollIntervalSecs
        let interval = min(max(rawInterval, Self.minPollIntervalSecs), 60)
        let rawExpires = (json["expires_in"] as? Int) ?? Self.maxExpiresInSecs
        let expiresIn = min(rawExpires, Self.maxExpiresInSecs)

        return DeviceFlowStart(
            userCode: userCode,
            verificationUri: verificationUri,
            deviceCode: deviceCode,
            interval: interval,
            expiresIn: expiresIn
        )
    }

    /// Poll `https://github.com/login/oauth/access_token` until the user
    /// approves, denies, or the code expires. On success the token,
    /// scopes, and resolved username are written to the Keychain and the
    /// derived `GithubStatus` is returned.
    ///
    /// Mirrors the single-poll logic of `auth::poll_device_flow_with`
    /// (`auth.rs:514-604`) plus the frontend's polling loop:
    ///   - `authorization_pending` → keep polling at `interval`
    ///   - `slow_down`             → double the interval (RFC 8628 §3.5,
    ///                               `auth.rs:606-617`)
    ///   - `access_denied`         → throws `GithubError.network("access denied")`
    ///   - `expired_token`         → throws `GithubError.network("device code expired")`
    public func pollDeviceFlow(deviceCode: String, interval: Int) async throws -> GithubStatus {
        var currentInterval = max(interval, Self.minPollIntervalSecs)
        let form: [String: String] = [
            "client_id": Self.oauthClientId,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]

        while true {
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)

            let (data, http) = try await postForm(urlString: Self.tokenURL, form: form)
            guard (200...299).contains(http.statusCode) else {
                throw GithubError.http(http.statusCode)
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                // GitHub returns `scope` comma- or space-separated; split on
                // both defensively, mirroring `auth.rs:562-571`.
                let scopes = Self.splitScopes(json["scope"] as? String)
                // Resolve username for display (non-fatal; `auth.rs:572-579`).
                let username = try? await fetchUsername(token: accessToken)

                // Persist to Keychain as the single combined item — no disk
                // fallback (`auth.rs:580-588`).
                Self.writeCredential(token: accessToken, username: username, scopes: scopes)
                return GithubStatus(signedIn: true, username: username, scopes: scopes)
            }

            // Error states, mirroring `auth.rs:592-603`.
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                currentInterval = min(currentInterval * 2, 60) // auth.rs:615-616
                continue
            case "access_denied":
                throw GithubError.network("access denied")
            case "expired_token":
                throw GithubError.network("device code expired")
            case let other?:
                throw GithubError.network("github device flow error: \(other)")
            case nil:
                throw GithubError.network("device flow returned neither access_token nor error")
            }
        }
    }

    // MARK: - Repo stats (read-only)

    /// Fetch read-only stats for a `github.com/<owner>/<repo>` homepage.
    /// Returns `nil` when `homepage` is not a valid GitHub repo URL —
    /// matching the `Ok(None)` collapse in `github_repo_stats`
    /// (`github.rs:81-84`). The fetch itself mirrors
    /// `stats::fetch_repo_stats` (`stats.rs:140-224`).
    ///
    /// Uses the stored token when present to lift the rate budget
    /// (60 → 5000/hr); anonymous otherwise (`stats.rs:19-23`).
    /// First candidate that parses as a `github.com/<owner>/<repo>` URL,
    /// canonicalized to `https://github.com/owner/repo`. Mirrors the Tauri
    /// `resolve_github_homepage` cascade (task #17) — packages often have a
    /// non-GitHub homepage but a GitHub-hosted source URL.
    public static func resolveGithubURL(_ candidates: [String?]) -> String? {
        for case let c? in candidates {
            if let repo = parseGithubURL(c) {
                return "https://github.com/\(repo.owner)/\(repo.repo)"
            }
        }
        return nil
    }

    public func repoStats(homepage: String) async throws -> RepoStats? {
        guard let repo = Self.parseGithubURL(homepage) else { return nil }
        let token = Self.readCredential()?.token

        let url = "\(Self.apiBase)/repos/\(repo.owner)/\(repo.repo)"
        let (data, http) = try await get(urlString: url, token: token)

        switch http.statusCode {
        case 200:
            break
        case 404:
            // Repo doesn't exist → treat same as "no GitHub URL"
            // (`stats.rs:159`).
            return nil
        case 403:
            throw Self.rateLimitedOrHTTP(http)
        default:
            throw GithubError.http(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GithubError.network("malformed repo response")
        }

        let (releaseTag, releaseDate) = await fetchLatestRelease(
            owner: repo.owner, repo: repo.repo, token: token
        )

        let license = json["license"] as? [String: Any]
        return RepoStats(
            owner: repo.owner,
            repo: repo.repo,
            stars: (json["stargazers_count"] as? Int) ?? 0,
            forks: (json["forks_count"] as? Int) ?? 0,
            openIssues: (json["open_issues_count"] as? Int) ?? 0,
            lastReleaseTag: releaseTag,
            lastReleaseDate: releaseDate,
            archived: (json["archived"] as? Bool) ?? false,
            archivedAt: json["archived_at"] as? String,
            licenseSpdx: license?["spdx_id"] as? String,
            primaryLanguage: json["language"] as? String
        )
    }

    // MARK: - Authed actions

    /// Whether the signed-in user has starred the repo. `GET
    /// /user/starred/{owner}/{repo}` → 204 = yes, 404 = no. Mirrors
    /// `actions::is_starred` (`actions.rs:157-171`).
    public func isStarred(homepage: String) async throws -> Bool {
        let (repo, token) = try authedGate(homepage: homepage, requiredScope: Self.scopePublicRepo)
        let url = "\(Self.apiBase)/user/starred/\(repo.owner)/\(repo.repo)"
        let (_, http) = try await send(method: "GET", urlString: url, token: token)
        switch http.statusCode {
        case 204: return true
        case 404: return false
        case 403: throw Self.rateLimitedOrHTTP(http)
        default: throw GithubError.http(http.statusCode)
        }
    }

    /// Star-status for many homepages → `homepage: isStarred`. Soft-fails per
    /// entry (errors omitted). Powers the dashboard "starred N of M" card.
    /// Bounded-concurrency fan-out (GitHubService is a value type, so these run
    /// in parallel) — keeps the dashboard card responsive over ~200 packages.
    public func batchIsStarred(_ homepages: [String]) async -> [String: Bool] {
        let limit = 12
        var out: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool)?.self) { group in
            var i = 0
            func spawnNext() {
                guard i < homepages.count else { return }
                let hp = homepages[i]; i += 1
                group.addTask { (try? await self.isStarred(homepage: hp)).map { (hp, $0) } }
            }
            for _ in 0..<min(limit, homepages.count) { spawnNext() }
            while let res = await group.next() {
                if let (hp, starred) = res { out[hp] = starred }
                spawnNext()
            }
        }
        return out
    }

    /// Star (PUT) or unstar (DELETE) `/user/starred/{owner}/{repo}`.
    /// Both return 204 and are idempotent. Mirrors `actions::star` /
    /// `actions::unstar` (`actions.rs:120-152`).
    public func setStar(homepage: String, starred: Bool) async throws {
        let (repo, token) = try authedGate(homepage: homepage, requiredScope: Self.scopePublicRepo)
        let url = "\(Self.apiBase)/user/starred/\(repo.owner)/\(repo.repo)"
        let (_, http) = try await send(method: starred ? "PUT" : "DELETE", urlString: url, token: token)
        switch http.statusCode {
        case 204: return
        case 403: throw Self.rateLimitedOrHTTP(http)
        default: throw GithubError.http(http.statusCode)
        }
    }

    /// Watch (PUT, 200) or unwatch (DELETE, 204) via the subscription
    /// endpoint `/repos/{owner}/{repo}/subscription`. Watch requires the
    /// `notifications` scope. Mirrors `actions::watch` / `actions::unwatch`
    /// (`actions.rs:177-222`).
    public func setWatch(homepage: String, watching: Bool) async throws {
        let (repo, token) = try authedGate(homepage: homepage, requiredScope: Self.scopeNotifications)
        let url = "\(Self.apiBase)/repos/\(repo.owner)/\(repo.repo)/subscription"
        if watching {
            let body = try JSONSerialization.data(withJSONObject: ["subscribed": true, "ignored": false])
            let (_, http) = try await send(method: "PUT", urlString: url, token: token, jsonBody: body)
            switch http.statusCode {
            case 200: return
            case 403: throw Self.rateLimitedOrHTTP(http)
            default: throw GithubError.http(http.statusCode)
            }
        } else {
            let (_, http) = try await send(method: "DELETE", urlString: url, token: token)
            switch http.statusCode {
            case 204: return
            case 403: throw Self.rateLimitedOrHTTP(http)
            default: throw GithubError.http(http.statusCode)
            }
        }
    }

    /// File an issue: `POST /repos/{owner}/{repo}/issues` → 201, returns
    /// `(html_url, number)`. Input is validated/sanitised before sending
    /// per the §12f caps. Mirrors `actions::create_issue`
    /// (`actions.rs:232-298`) and the `github_create_issue` command
    /// (`github.rs:253-267`).
    public func createIssue(
        homepage: String,
        title: String,
        body: String,
        labels: [String]
    ) async throws -> (url: String, number: Int) {
        let (repo, token) = try authedGate(homepage: homepage, requiredScope: Self.scopePublicRepo)

        let cleanTitle = try Self.sanitiseTitle(title)
        let cleanBody = try Self.sanitiseBody(body)
        let cleanLabels = try Self.sanitiseLabels(labels)

        let url = "\(Self.apiBase)/repos/\(repo.owner)/\(repo.repo)/issues"
        let payload: [String: Any] = [
            "title": cleanTitle,
            "body": cleanBody,
            "labels": cleanLabels,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await send(method: "POST", urlString: url, token: token, jsonBody: bodyData)

        if http.statusCode == 403 { throw Self.rateLimitedOrHTTP(http) }
        guard http.statusCode == 201 else { throw GithubError.http(http.statusCode) }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let number = json["number"] as? Int,
            let htmlURL = json["html_url"] as? String,
            number != 0, !htmlURL.isEmpty
        else {
            throw GithubError.network("create_issue returned no number/html_url")
        }
        return (url: htmlURL, number: number)
    }

    // MARK: - Authed-action gate

    /// Common gate for every authed action. Mirrors `authed_gate`
    /// (`github.rs:166-201`): validate the URL → require a token →
    /// require the specific scope. The paranoid-mode / settings gates
    /// from the Tauri command layer are intentionally out of scope for
    /// this self-contained service.
    private func authedGate(
        homepage: String,
        requiredScope: String
    ) throws -> (repo: GithubRepo, token: String) {
        // URL allowlist — authed actions surface a typed error rather
        // than the `nil` collapse stats uses (`github.rs:180-182`).
        guard let repo = Self.parseGithubURL(homepage) else {
            throw GithubError.notAGithubURL
        }
        // Auth + scope gate from the single combined credential read
        // (`github.rs:185-194`) — one Keychain access.
        guard let cred = Self.readCredential(), !cred.token.isEmpty else {
            throw GithubError.authRequired
        }
        guard cred.scopes.contains(requiredScope) else {
            throw GithubError.scopeRequired(requiredScope)
        }
        return (repo, cred.token)
    }

    // MARK: - Latest release helper

    /// Best-effort latest-release lookup. Tries `releases/latest`, falls
    /// back to `tags?per_page=1`. Never throws — a failure just yields
    /// `(nil, nil)`. Mirrors `stats::fetch_latest_release`
    /// (`stats.rs:226-273`).
    private func fetchLatestRelease(
        owner: String, repo: String, token: String?
    ) async -> (String?, String?) {
        let releaseURL = "\(Self.apiBase)/repos/\(owner)/\(repo)/releases/latest"
        if let (data, http) = try? await get(urlString: releaseURL, token: token) {
            if (200...299).contains(http.statusCode) {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tag = json["tag_name"] as? String, !tag.isEmpty {
                    return (tag, json["published_at"] as? String)
                }
                return (nil, nil)
            }
            if http.statusCode == 404 {
                let tagsURL = "\(Self.apiBase)/repos/\(owner)/\(repo)/tags?per_page=1"
                if let (tdata, thttp) = try? await get(urlString: tagsURL, token: token),
                   (200...299).contains(thttp.statusCode),
                   let arr = try? JSONSerialization.jsonObject(with: tdata) as? [[String: Any]],
                   let first = arr.first,
                   let name = first["name"] as? String, !name.isEmpty {
                    return (name, nil)
                }
            }
        }
        return (nil, nil)
    }

    /// Resolve the signed-in user's login via `GET /user`. Mirrors
    /// `auth::fetch_username` (`auth.rs:642-669`).
    private func fetchUsername(token: String) async throws -> String {
        let (data, http) = try await get(urlString: Self.userURL, token: token)
        guard (200...299).contains(http.statusCode) else {
            throw GithubError.http(http.statusCode)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let login = json["login"] as? String, !login.isEmpty
        else {
            throw GithubError.network("/user returned empty login")
        }
        return login
    }

    // MARK: - HTTP plumbing

    private func postForm(
        urlString: String, form: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw GithubError.network("bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.urlEncode(form).data(using: .utf8)
        return try await perform(req, url: urlString)
    }

    private func get(
        urlString: String, token: String?
    ) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "GET", urlString: urlString, token: token)
    }

    /// Send an authed (or anonymous) request with the standard GitHub
    /// API headers. Mirrors the header set used across
    /// `stats.rs:282-291` and `actions.rs:322-328`.
    private func send(
        method: String,
        urlString: String,
        token: String?,
        jsonBody: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw GithubError.network("bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        return try await perform(req, url: urlString)
    }

    private func perform(_ req: URLRequest, url: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw GithubError.network("non-HTTP response from \(url)")
            }
            return (data, http)
        } catch let e as GithubError {
            throw e
        } catch {
            throw GithubError.network(error.localizedDescription)
        }
    }

    /// Build a `GithubError` from a 403 response: rate-limited when
    /// `X-RateLimit-Remaining: 0`, otherwise a plain HTTP 403. Mirrors
    /// `maybe_rate_limited` (`stats.rs:301-322`, `actions.rs:381-401`).
    private static func rateLimitedOrHTTP(_ http: HTTPURLResponse) -> GithubError {
        let remaining = (http.value(forHTTPHeaderField: "x-ratelimit-remaining"))
            .flatMap { Int($0) } ?? 0
        if remaining == 0 {
            let resetAt = http.value(forHTTPHeaderField: "x-ratelimit-reset")
            return .rateLimited(resetAt: resetAt)
        }
        return .http(403)
    }

    private static func urlEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: - Scope (de)serialization

    /// Decode a JSON-array scope blob from the Keychain, collapsing a
    /// corrupt blob to `[]` — defensive, matching `auth.rs:335-337` /
    /// `read_scopes_with` (`auth.rs:374-384`).
    private static func decodeScopes(_ raw: String?) -> [String] {
        guard
            let raw,
            let data = raw.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }
        return arr
    }

    private static func encodeScopes(_ scopes: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: scopes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Split GitHub's `scope` string on commas AND whitespace, dropping
    /// empties. Verbatim behaviour from `auth.rs:562-571` (GitHub returns
    /// this comma-separated, contra OAuth 2.0's space-separated form).
    private static func splitScopes(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let separators = CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)
        return raw.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    // MARK: - URL allowlist (parse_github_url)

    /// Validated `(owner, repo)` pair.
    struct GithubRepo: Sendable, Equatable {
        let owner: String
        let repo: String
    }

    /// Strict equivalent of `parse_github_url` (`commands/github.rs` +
    /// `github/url.rs:65-196`): accept ONLY `github.com/<owner>/<repo>`.
    ///
    /// This is a hand-rolled string parser (not `URLComponents`) so the
    /// accept/reject set matches the Rust source byte-for-byte. It honours
    /// the same small suffix set the Rust parser does:
    ///   - a single trailing slash
    ///   - a `/tree/<ref>…` or `/blob/<ref>…` suffix (3rd segment)
    ///   - a `.git` suffix on the repo segment
    ///
    /// Rejects (mirroring the Rust test matrix in `url.rs:423-513`):
    ///   - any scheme other than `http` / `https` (the Rust parser accepts
    ///     both for parity with `parse_http_url`, `url.rs:404-411`)
    ///   - any host other than exactly `github.com` (so `gist.github.com`,
    ///     `raw.githubusercontent.com`, `github.com.evil.com`, and
    ///     `evil.com/github.com/…` are all refused — `url.rs:115-120`)
    ///   - any `?query` or `#fragment` (`url.rs:138-140`)
    ///   - paths that aren't exactly `/owner/repo` after suffix trimming
    ///   - owner/repo failing the lexical rule (`isValidOwnerOrRepo`)
    ///   - any `..` segment (`url.rs:185-190`)
    static func parseGithubURL(_ homepage: String) -> GithubRepo? {
        let trimmed = homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // 1. Scheme — http or https, case-insensitive (`url.rs:76-84`).
        let lower = trimmed.lowercased()
        let schemeLen: Int
        if lower.hasPrefix("https://") {
            schemeLen = 8
        } else if lower.hasPrefix("http://") {
            schemeLen = 7
        } else {
            return nil
        }
        let rest = String(trimmed.dropFirst(schemeLen))
        if rest.isEmpty { return nil }

        // 2. Authority ends at the first `/`, `?`, or `#` (`url.rs:98`).
        let authEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        let authority = authEnd.map { String(rest[rest.startIndex..<$0]) } ?? rest
        if authority.isEmpty { return nil }

        // Strip any `user@` userinfo prefix; never carry credentials
        // (`url.rs:105`).
        let hostWithPort = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? authority
        if hostWithPort.isEmpty { return nil }
        // Bare host without port (`:443`/`:80` tolerated) (`url.rs:113`).
        let host = hostWithPort.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? hostWithPort

        // 3. Exact host match (`url.rs:118`).
        guard host.lowercased() == "github.com" else { return nil }

        // 4. Path remainder. Reject `?`/`#` outright (`url.rs:130-140`).
        let path = authEnd.map { String(rest[$0...]) } ?? ""
        if path.contains("?") || path.contains("#") { return nil }

        // Trim a trailing slash, then a `/tree/<ref>` or `/blob/<ref>`
        // suffix where the 3rd segment is `tree`/`blob` (`url.rs:146-162`).
        let trimmedSlash = path.hasSuffix("/") ? String(path.dropLast()) : path
        var segs = trimmedSlash.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segs.count >= 3 {
            let third = segs[2].lowercased()
            if third == "tree" || third == "blob" {
                segs = [segs[0], segs[1]]
            }
        }

        // Strip a trailing `.git` from the repo segment (`url.rs:164-169`).
        guard segs.count == 2 else { return nil }
        let owner = segs[0]
        var repo = segs[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        // 5. Owner + repo allowlist + `..` belt-and-braces (`url.rs:180-190`).
        guard isValidOwnerOrRepo(owner), isValidOwnerOrRepo(repo) else { return nil }
        if owner == ".." || repo == ".." { return nil }

        return GithubRepo(owner: owner, repo: repo)
    }

    /// Lexical validator for an owner or repo segment. Verbatim port of
    /// `is_valid_owner_or_repo` (`actions.rs:358-377`, identical rule to
    /// `url::is_valid_owner_or_repo`):
    ///   - length 1...39
    ///   - not "." or ".."
    ///   - first char not "." or "-"
    ///   - every char ASCII alphanumeric or one of `- _ .`
    static func isValidOwnerOrRepo(_ name: String) -> Bool {
        if name.isEmpty || name.count > 39 { return false }
        if name == "." || name == ".." { return false }
        let bytes = Array(name.utf8)
        let first = bytes[0]
        if first == UInt8(ascii: ".") || first == UInt8(ascii: "-") { return false }
        for b in bytes {
            let isAlnum = (b >= 0x30 && b <= 0x39)
                || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
            let ok = isAlnum
                || b == UInt8(ascii: "-")
                || b == UInt8(ascii: "_")
                || b == UInt8(ascii: ".")
            if !ok { return false }
        }
        return true
    }

    // MARK: - Issue input sanitisers (§12f caps)

    /// Strip C0 control chars (keep `\t`), trim, enforce the 256-char cap.
    /// Verbatim behaviour from `sanitise_title` (`actions.rs:410-431`).
    static func sanitiseTitle(_ raw: String) throws -> String {
        let cleaned = String(raw.unicodeScalars.filter { $0 == "\t" || $0.value >= 0x20 })
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GithubError.network("issue title must not be empty")
        }
        if trimmed.count > issueTitleMaxChars {
            throw GithubError.network("issue title exceeds \(issueTitleMaxChars)-char cap")
        }
        return trimmed
    }

    /// Strip null bytes only, enforce the 64 KiB byte cap. Markdown
    /// passthrough. Verbatim behaviour from `sanitise_body`
    /// (`actions.rs:435-445`).
    static func sanitiseBody(_ raw: String) throws -> String {
        let cleaned = String(raw.unicodeScalars.filter { $0 != "\0" })
        if cleaned.utf8.count > issueBodyMaxBytes {
            throw GithubError.network("issue body exceeds \(issueBodyMaxBytes)-byte cap")
        }
        return cleaned
    }

    /// Validate the label slugs: ≤10 labels, each 1...50 chars matching
    /// `^[A-Za-z0-9_./-]+$`. Verbatim behaviour from `sanitise_labels`
    /// (`actions.rs:449-480`).
    static func sanitiseLabels(_ raw: [String]) throws -> [String] {
        if raw.count > issueLabelsMaxCount {
            throw GithubError.network("too many labels (\(raw.count) > \(issueLabelsMaxCount))")
        }
        for label in raw {
            let byteLen = label.utf8.count
            if label.isEmpty || byteLen > issueLabelMaxChars {
                throw GithubError.network("label length must be 1...\(issueLabelMaxChars); got \(byteLen)")
            }
            for b in label.utf8 {
                let isAlnum = (b >= 0x30 && b <= 0x39)
                    || (b >= 0x41 && b <= 0x5A)
                    || (b >= 0x61 && b <= 0x7A)
                let ok = isAlnum
                    || b == UInt8(ascii: "-")
                    || b == UInt8(ascii: "_")
                    || b == UInt8(ascii: ".")
                    || b == UInt8(ascii: "/")
                if !ok {
                    throw GithubError.network("label contains invalid character: \(label)")
                }
            }
        }
        return raw
    }

    // MARK: - Keychain (Security.framework)

    /// Read a generic-password value for `account` under
    /// `keychainService`. Returns `nil` for "no entry". Equivalent to
    /// `SystemKeychain::read` (`auth.rs:285-294`).
    private static func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Read the combined credential item (token + username + scopes) — ONE
    /// Keychain access = ONE prompt. If it's absent but the legacy three-item
    /// layout exists, migrate it into the combined item (that one-time migration
    /// reads the three old items, then never again). Returns nil when signed out.
    private static func readCredential() -> (token: String, username: String?, scopes: [String])? {
        if let raw = keychainRead(account: accountCredential),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = obj["token"] as? String, !token.isEmpty {
            return (token, obj["username"] as? String, (obj["scopes"] as? [String]) ?? [])
        }
        // Legacy three-item layout → migrate into the combined item.
        guard let token = keychainRead(account: accountToken), !token.isEmpty else { return nil }
        let username = keychainRead(account: accountUsername)
        let scopes = decodeScopes(keychainRead(account: accountScopes))
        writeCredential(token: token, username: username, scopes: scopes)
        return (token, username, scopes)
    }

    /// Best-effort read of the stored GitHub access token for authenticated
    /// API calls outside the sign-in flow (e.g. GHSA enrichment). nil when
    /// signed out. ONE Keychain access. Mirrors the Tauri
    /// `github::auth::read_token` used by `vulns::enrich`.
    static func storedToken() -> String? {
        readCredential()?.token
    }

    /// Persist the combined credential item (token + username + scopes) as one
    /// JSON blob — one Keychain item so every later read is a single prompt.
    private static func writeCredential(token: String, username: String?, scopes: [String]) {
        var obj: [String: Any] = ["token": token, "scopes": scopes]
        if let username { obj["username"] = username }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = keychainWrite(account: accountCredential, value: json)
    }

    /// Upsert a generic-password value. Equivalent to
    /// `SystemKeychain::write` (`auth.rs:296-303`).
    @discardableResult
    private static func keychainWrite(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        // Update if present, else add.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Delete a generic-password entry, treating "no such entry" as
    /// success. Equivalent to `SystemKeychain::delete` (`auth.rs:305-314`).
    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
