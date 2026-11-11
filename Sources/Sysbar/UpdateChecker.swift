// "Check for updates": asks GitHub for the latest Sysbar release and, if
// it is newer than the running version, offers to download its DMG.
// No auto-install: the app is ad-hoc signed, so the user installs the new
// DMG the same way as the first one.

import AppKit

@MainActor
final class UpdateChecker {
    static let repository = "rodrigotrombeta/Sysbar"
    private static let autoInterval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var checking = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Checks shortly after launch, then once a day (when enabled).
    func startAutomaticChecks() {
        timer?.invalidate()
        let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Settings.autoCheckUpdates else { return }
        let last = Settings.lastUpdateCheck ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.autoInterval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sysbar/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        Task { [weak self] in
            let result: Result<Release, Error>
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw URLError(.badServerResponse)
                }
                result = .success(try JSONDecoder().decode(Release.self, from: data))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.checking = false
            self.handle(result, userInitiated: userInitiated)
        }
    }

    private func handle(_ result: Result<Release, Error>, userInitiated: Bool) {
        switch result {
        case .failure(let error):
            // Automatic checks fail silently (offline, rate limit…).
            guard userInitiated else { return }
            showAlert(title: tr("Couldn't check for updates", "Não foi possível verificar atualizações"),
                      text: error.localizedDescription, buttons: ["OK"])
        case .success(let release):
            Settings.lastUpdateCheck = Date()
            let latest = Self.normalized(release.tag_name)
            let isNewer = Self.compare(latest, Self.currentVersion) == .orderedDescending
            let skipped = !userInitiated && Settings.skippedVersion == latest
            guard isNewer, release.draft != true, release.prerelease != true, !skipped else {
                if userInitiated {
                    showAlert(title: tr("Sysbar is up to date", "O Sysbar está atualizado"),
                              text: tr("You have the latest version (\(Self.currentVersion)).",
                                       "Você tem a versão mais recente (\(Self.currentVersion))."),
                              buttons: ["OK"])
                }
                return
            }
            offer(release, version: latest, userInitiated: userInitiated)
        }
    }

    private func offer(_ release: Release, version: String, userInitiated: Bool) {
        var text = tr("You have \(Self.currentVersion). Download the new DMG, quit Sysbar and drag the new app to Applications.",
                      "Você tem a \(Self.currentVersion). Baixe o novo DMG, saia do Sysbar e arraste o novo app para Aplicativos.")
        if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            let short = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
            text += "\n\n" + short
        }
        var buttons = [tr("Download", "Baixar"), tr("Later", "Depois")]
        if !userInitiated { buttons.append(tr("Skip This Version", "Ignorar esta versão")) }
        let response = showAlert(
            title: tr("Sysbar \(version) is available", "Sysbar \(version) está disponível"),
            text: text, buttons: buttons)
        switch response {
        case .alertFirstButtonReturn:
            let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            NSWorkspace.shared.open(dmg?.browser_download_url ?? release.html_url)
        case .alertThirdButtonReturn:
            Settings.skippedVersion = version
        default:
            break
        }
    }

    @discardableResult
    private func showAlert(title: String, text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.window.appearance = Settings.appearance.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // MARK: Versions

    static func normalized(_ tag: String) -> String {
        var v = tag.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// Numeric dotted comparison: 1.10.0 > 1.9.2, 1.1 == 1.1.0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
