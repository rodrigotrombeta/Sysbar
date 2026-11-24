// Fetches the Claude limits straight from Anthropic, like Claude Code's
// `/usage` command: GET api.anthropic.com/api/oauth/usage with Claude Code's
// own login (its OAuth access token in the "Claude Code-credentials"
// Keychain item; macOS asks once whether Sysbar may read it). Works whether
// Claude Code runs in a terminal, an editor or another app.
//
// The token is only read from the Keychain for each request and sent to
// api.anthropic.com; it is never stored, logged or refreshed by Sysbar
// (Claude Code renews it itself). This endpoint is internal to Claude Code and
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
            let result = await Self.request()
            await MainActor.run {
                switch result {
                case .success(let entry):
                    ClaudeUsageStore.append(entry)
                    self.status = .ok(Date())
                case .failure(let error):
                    self.status = .failed(error.message)
                }
            }
        }
    }

    struct FetchError: Error { let message: String }

    nonisolated private static func request() async -> Result<[String: Any], FetchError> {
        guard let token = accessToken() else {
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
        guard code == 200 else {
            return .failure(FetchError(message: code == 401
                ? tr("Login expired: open Claude Code once to renew it.", "Login expirado: abra o Claude Code uma vez para renová-lo.")
                : tr("Anthropic answered HTTP \(code).", "A Anthropic respondeu HTTP \(code).")))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(FetchError(message: tr("Unexpected answer from Anthropic.", "Resposta inesperada da Anthropic.")))
        }
        var entry: [String: Any] = ["t": Date().timeIntervalSince1970]
        for (key, name) in [("five_hour", "five"), ("seven_day", "seven")] {
            guard let w = obj[key] as? [String: Any],
                  let p = (w["utilization"] as? NSNumber)?.doubleValue, p >= 0, p <= 1000 else { continue }
            let reset: Double? = (w["resets_at"] as? String).flatMap(parseDate)?.timeIntervalSince1970
                ?? (w["resets_at"] as? NSNumber)?.doubleValue
            guard let reset else { continue }
            entry[name] = ["p": p, "r": reset]
        }
        guard entry.count > 1 else {
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

    /// Claude Code's OAuth access token, read from the Keychain each time.
    nonisolated private static func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}
