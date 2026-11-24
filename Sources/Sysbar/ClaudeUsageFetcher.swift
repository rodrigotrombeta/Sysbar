// Fetches the Claude limits straight from Anthropic, like Claude Code's
// `/usage` command: GET api.anthropic.com/api/oauth/usage with Claude Code's
// own login (its OAuth access token in the "Claude Code-credentials"
// Keychain item; macOS asks once whether Sysbar may read it). Works whether
// Claude Code runs in a terminal, an editor or another app.
//
// The token is read from the Keychain once per launch (kept in memory only,
// read again if Anthropic answers 401) and sent only to api.anthropic.com;
// it is never written to disk, logged or refreshed by Sysbar (Claude Code
// renews it itself). This endpoint is internal to Claude Code and
// undocumented, so it may change.

import Foundation
import Security

@MainActor
final class ClaudeUsageFetcher {
    enum Status: Equatable { case idle, fetching, ok(Date), failed(String) }

    private(set) var status: Status = .idle { didSet { onChange(status) } }
    var onChange: (Status) -> Void = { _ in }
    private var lastAttempt = Date.distantPast
    /// Automatic fetches; the refresh button fetches at any time.
    static let interval: TimeInterval = 300

    /// Called every tick; fetches when due.
    func tick() {
        guard Settings.claudeFetch, Date().timeIntervalSince(lastAttempt) >= Self.interval else { return }
        fetch()
    }

    func fetch() {
        guard status != .fetching else { return }
        lastAttempt = Date()
        status = .fetching
        Task.detached(priority: .utility) {
            let accounts = Self.loginServices()
            var results: [(String, Result<[String: Any], FetchError>)] = []
            for (service, account) in accounts {
                results.append((account, await Self.request(service: service)))
            }
            await MainActor.run {
                var failures: [String] = []
                for (account, result) in results {
                    switch result {
                    case .success(let entry): ClaudeUsageStore.append(entry, account: account)
                    case .failure(let error):
                        failures.append(accounts.count > 1
                            ? "\(account.isEmpty ? tr("Main account", "Conta principal") : account): \(error.message)"
                            : error.message)
                    }
                }
                if accounts.isEmpty {
                    self.status = .failed(tr("No Claude Code login found in the Keychain.",
                                             "Nenhum login do Claude Code encontrado no Chaves."))
                } else {
                    self.status = failures.isEmpty ? .ok(Date()) : .failed(failures.joined(separator: "\n"))
                }
            }
        }
    }

    /// Claude Code's logins: its Keychain items "Claude Code-credentials"
    /// (default) and "Claude Code-credentials-<id>" (other config dirs).
    /// Listing reads only names, so it doesn't prompt.
    nonisolated static func loginServices() -> [(service: String, account: String)] {
        let base = "Claude Code-credentials"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        let services = Set(list.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0 == base || $0.hasPrefix(base + "-") })
        return services.sorted().map { service in
            let id = service == base ? "" : String(service.dropFirst(base.count + 1))
            return (service, id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    struct FetchError: Error { let message: String }

    nonisolated private static func request(service: String) async -> Result<[String: Any], FetchError> {
        guard let (token, plan) = cachedLogin(service: service) else {
            return .failure(FetchError(message: tr("Claude Code login not found or not allowed in the Keychain.",
                                                   "Login do Claude Code não encontrado ou não permitido no Chaves.")))
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sysbar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure(FetchError(message: tr("No connection to Anthropic.", "Sem conexão com a Anthropic.")))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { forgetLogin(service: service) }  // renewed by Claude Code: read it again next time
        guard code == 200 else {
            return .failure(FetchError(message: code == 401
                ? tr("Login expired: open Claude Code once to renew it.", "Login expirado: abra o Claude Code uma vez para renová-lo.")
                : tr("Anthropic answered HTTP \(code).", "A Anthropic respondeu HTTP \(code).")))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(FetchError(message: tr("Unexpected answer from Anthropic.", "Resposta inesperada da Anthropic.")))
        }
        var entry: [String: Any] = ["t": Date().timeIntervalSince1970]
        if let plan { entry["plan"] = plan }
        for (key, name) in [("five_hour", "five"), ("seven_day", "seven")] {
            guard let w = obj[key] as? [String: Any],
                  let p = (w["utilization"] as? NSNumber)?.doubleValue, p >= 0, p <= 1000 else { continue }
            let reset: Double? = (w["resets_at"] as? String).flatMap(parseDate)?.timeIntervalSince1970
                ?? (w["resets_at"] as? NSNumber)?.doubleValue
            guard let reset else { continue }
            entry[name] = ["p": p, "r": reset]
        }
        guard entry["five"] != nil || entry["seven"] != nil else {
            return .failure(FetchError(message: tr("No limits in Anthropic's answer (fields: \(obj.keys.sorted().joined(separator: ", "))).",
                                                   "Sem limites na resposta da Anthropic (campos: \(obj.keys.sorted().joined(separator: ", ")))).")))
        }
        return .success(entry)
    }

    nonisolated private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Logins read this session, so the Keychain (and its password prompt)
    /// is used once per account per launch, and again only after a 401.
    nonisolated(unsafe) private static var logins: [String: (token: String, plan: String?)] = [:]
    nonisolated private static let loginsLock = NSLock()

    nonisolated private static func cachedLogin(service: String) -> (token: String, plan: String?)? {
        if let cached = loginsLock.withLock({ logins[service] }) { return cached }
        guard let fresh = login(service: service) else { return nil }
        loginsLock.withLock { logins[service] = fresh }
        return fresh
    }

    nonisolated private static func forgetLogin(service: String) {
        loginsLock.withLock { _ = logins.removeValue(forKey: service) }
    }

    /// A login's OAuth access token (and plan), read from the Keychain.
    nonisolated private static func login(service: String) -> (token: String, plan: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }
}
