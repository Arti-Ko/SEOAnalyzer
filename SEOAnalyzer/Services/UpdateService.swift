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
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var estimatedSecondsRemaining: Double?
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
        // Предпочитаем DMG-установщик, при его отсутствии — zip-архив.
        let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
        guard let asset, let url = URL(string: asset.browserDownloadURL) else {
            fail("В релизе нет установщика (.dmg или .zip).", silent: false); return
        }

        let isDMG = asset.name.lowercased().hasSuffix(".dmg")
        phase = .downloading
        downloadProgress = 0
        downloadedBytes = 0
        totalBytes = 0
        estimatedSecondsRemaining = nil
        let fm = FileManager.default

        do {
            let downloader = ProgressDownloader { [weak self] fraction, written, total, elapsed in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = fraction
                    self.downloadedBytes = written
                    self.totalBytes = total
                    // Оценка по средней скорости с начала закачки — простая, но
                    // достаточно точная для пользовательского ETA.
                    if elapsed > 0.3, written > 0, total > 0 {
                        let bytesPerSecond = Double(written) / elapsed
                        let remaining = Double(total - written)
                        self.estimatedSecondsRemaining = bytesPerSecond > 0 ? remaining / bytesPerSecond : nil
                    }
                }
            }
            let tempFile = try await downloader.download(url)
            estimatedSecondsRemaining = nil

            let workDir = fm.temporaryDirectory
                .appendingPathComponent("SEOAnalyzerUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            let downloaded = workDir.appendingPathComponent(isDMG ? "update.dmg" : "update.zip")
            try fm.moveItem(at: tempFile, to: downloaded)

            // Дальше — монтирование/распаковка без побайтового прогресса,
            // показываем неопределённый индикатор (UpdateView сам решает по фазе).
            phase = .installing

            let newApp: URL?
            if isDMG {
                newApp = try await extractAppFromDMG(downloaded, workDir: workDir)
            } else {
                let extractDir = workDir.appendingPathComponent("extracted")
                try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
                try await runProcessAsync("/usr/bin/ditto", ["-x", "-k", downloaded.path, extractDir.path])
                newApp = findApp(in: extractDir)
            }

            guard let newApp else {
                fail("В установщике не найдено приложение (.app).", silent: false); return
            }

            downloadProgress = 1.0
            try relaunch(replacing: Bundle.main.bundleURL, with: newApp)
            // После запуска скрипта приложение завершится — см. relaunch().
        } catch {
            fail("Ошибка установки обновления: \(error.localizedDescription)", silent: false)
        }
    }

    /// Монтирует DMG, копирует из него .app во временную папку и размонтирует образ.
    private func extractAppFromDMG(_ dmgPath: URL, workDir: URL) async throws -> URL {
        let fm = FileManager.default
        let mountPoint = workDir.appendingPathComponent("mnt")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try await runProcessAsync("/usr/bin/hdiutil",
                                  ["attach", dmgPath.path, "-nobrowse", "-noautoopen",
                                   "-mountpoint", mountPoint.path])

        func detach() async {
            _ = try? await runProcessAsync("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }

        guard let app = findApp(in: mountPoint) else {
            await detach()
            throw NSError(domain: "UpdateService", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "В образе DMG не найдено приложение."])
        }
        // Копируем приложение из тома наружу, прежде чем размонтировать.
        let dest = workDir.appendingPathComponent(app.lastPathComponent)
        do {
            try await runProcessAsync("/usr/bin/ditto", [app.path, dest.path])
        } catch {
            await detach()
            throw error
        }
        await detach()
        return dest
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

    /// Запускает внешний процесс в фоне (не блокируя главный поток UI).
    nonisolated private func runProcessAsync(_ launchPath: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        cont.resume(throwing: NSError(domain: "UpdateService",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey:
                                "\(launchPath) завершился с кодом \(process.terminationStatus)"]))
                    } else {
                        cont.resume()
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Готовит и запускает скрипт замены бандла, затем завершает приложение.
    /// Скрипт стартует мгновенно и работает в фоне — главный поток не блокируется.
    private func relaunch(replacing current: URL, with newApp: URL) throws {
        let cur = current.path

        // Защита от App Translocation: macOS запускает скачанные приложения из
        // временной read-only копии. Заменить такой бандл нельзя — просим перенести.
        if cur.contains("/AppTranslocation/") {
            throw NSError(domain: "UpdateService", code: -20, userInfo: [NSLocalizedDescriptionKey:
                "Приложение запущено из временной карантинной копии. Перенесите SEO-Анализатор в «Программы» и выполните в Терминале: xattr -cr /Applications/SEOAnalyzer.app, затем повторите обновление."])
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let new = newApp.path
        let logPath = NSTemporaryDirectory() + "seo-update.log"

        let script = """
        #!/bin/bash
        exec > "\(logPath)" 2>&1
        set -x
        # Ждём завершения текущего экземпляра приложения (не дольше ~10 c).
        for i in $(seq 1 50); do
            /bin/kill -0 \(pid) 2>/dev/null || break
            sleep 0.2
        done
        # На всякий случай добиваем процесс, если он ещё жив, чтобы не было двух копий.
        /bin/kill -9 \(pid) 2>/dev/null
        sleep 0.3
        /usr/bin/ditto "\(new)" "\(cur).new" || exit 1
        /bin/rm -rf "\(cur)"
        /bin/mv "\(cur).new" "\(cur)" || exit 1
        /usr/bin/xattr -dr com.apple.quarantine "\(cur)" 2>/dev/null
        sleep 0.4
        # Открываем заменённый бандл (без -n: старый уже завершён, дубля не будет).
        /usr/bin/open "\(cur)"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seo-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()  // стартует мгновенно, дальше работает сам

        // Завершаем приложение, чтобы скрипт мог заменить бандл и перезапустить его.
        // Штатное завершение + жёсткий фолбэк: если terminate не сработает,
        // старый экземпляр остался бы висеть с открытым окном обновления.
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exit(0) }
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
