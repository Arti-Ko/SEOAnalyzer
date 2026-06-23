import Foundation
import AppKit

/// Релиз GitHub (минимально необходимые поля).
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case assets
    }
}

/// Сервис проверки и установки обновлений из GitHub Releases.
///
/// Логика установки: скачиваем zip-ассет релиза, распаковываем его,
/// затем запускаем вспомогательный скрипт, который дожидается выхода
/// текущего процесса, заменяет бандл приложения новым и перезапускает его.
@MainActor
final class UpdateService: ObservableObject {

    static let shared = UpdateService()
    static let repo = "Arti-Ko/SEOAnalyzer"

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing, failed
    }

    @Published var phase: Phase = .idle
    @Published var latest: GitHubRelease?
    @Published var message: String?
    @Published var downloadProgress: Double = 0
    @Published var showSheet = false

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var latestVersion: String? {
        latest.map { Self.normalize($0.tagName) }
    }

    // MARK: - Проверка

    func check(silent: Bool) async {
        phase = .checking
        message = nil
        if !silent { showSheet = true }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            fail("Некорректный адрес репозитория.", silent: silent); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SEOAnalyzer", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                phase = .upToDate
                message = "Опубликованных релизов пока нет. У вас версия \(currentVersion)."
                if !silent { showSheet = true }
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latest = release

            if let lv = latestVersion, Self.isNewer(lv, than: currentVersion) {
                phase = .available
                message = nil
                showSheet = true
            } else {
                phase = .upToDate
                message = "У вас установлена актуальная версия (\(currentVersion))."
                if !silent { showSheet = true }
            }
        } catch {
            fail("Не удалось проверить обновления: \(error.localizedDescription)", silent: silent)
        }
    }

    // MARK: - Установка

    func install() async {
        guard let release = latest else { return }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
              let url = URL(string: asset.browserDownloadURL) else {
            fail("В релизе нет zip-архива приложения для установки.", silent: false); return
        }

        phase = .downloading
        downloadProgress = 0.1
        let fm = FileManager.default

        do {
            let (tempFile, _) = try await URLSession.shared.download(from: url)
            downloadProgress = 0.6

            let workDir = fm.temporaryDirectory
                .appendingPathComponent("SEOAnalyzerUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            let zipPath = workDir.appendingPathComponent("update.zip")
            try fm.moveItem(at: tempFile, to: zipPath)

            phase = .installing
            downloadProgress = 0.8

            let extractDir = workDir.appendingPathComponent("extracted")
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try runProcess("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])

            guard let newApp = findApp(in: extractDir) else {
                fail("В архиве обновления не найдено приложение (.app).", silent: false); return
            }

            downloadProgress = 1.0
            try relaunch(replacing: Bundle.main.bundleURL, with: newApp)
            // После запуска скрипта приложение завершится — см. relaunch().
        } catch {
            fail("Ошибка установки обновления: \(error.localizedDescription)", silent: false)
        }
    }

    func openReleasePage() {
        if let urlString = latest?.htmlURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Внутреннее

    private func fail(_ msg: String, silent: Bool) {
        phase = .failed
        message = msg
        if !silent { showSheet = true }
    }

    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        // Иногда .app лежит на уровень глубже.
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let nested = findApp(in: sub) { return nested }
        }
        return nil
    }

    private func runProcess(_ launchPath: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "UpdateService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(launchPath) завершился с кодом \(process.terminationStatus)"])
        }
    }

    /// Готовит и запускает скрипт замены бандла, затем завершает приложение.
    private func relaunch(replacing current: URL, with newApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let cur = current.path
        let new = newApp.path

        let script = """
        #!/bin/bash
        # Ждём, пока завершится текущий экземпляр приложения.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        /usr/bin/ditto "\(new)" "\(cur).new" || exit 1
        /bin/rm -rf "\(cur)"
        /bin/mv "\(cur).new" "\(cur)"
        /usr/bin/xattr -dr com.apple.quarantine "\(cur)" 2>/dev/null
        /usr/bin/open "\(cur)"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seo-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()

        // Завершаем приложение, чтобы скрипт мог заменить бандл.
        NSApp.terminate(nil)
    }

    // MARK: - Сравнение версий

    static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    /// Сравнивает версии вида «1.2.3» — true, если a строго новее b.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
