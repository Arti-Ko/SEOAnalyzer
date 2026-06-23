import Foundation

/// Сигналы страницы для агрегации AEO/GEO по всему сайту (а не только по главной).
struct PageSignals {
    let hasStructuredData: Bool
    let hasFAQ: Bool
    let hasBreadcrumb: Bool
    let hasArticleHowTo: Bool
    let hasSpeakable: Bool
    let questionHeadings: Int
    let lists: Int
    let tables: Int
    let hasAuthor: Bool
    let hasDate: Bool
    let hasWikiAuthority: Bool
    let isSPA: Bool

    static let empty = PageSignals(hasStructuredData: false, hasFAQ: false, hasBreadcrumb: false,
                                   hasArticleHowTo: false, hasSpeakable: false, questionHeadings: 0,
                                   lists: 0, tables: 0, hasAuthor: false, hasDate: false,
                                   hasWikiAuthority: false, isSPA: false)
}

/// Результат сканирования одной страницы сайта.
struct PageScan {
    let url: String
    let status: Int
    let responseMs: Int
    let title: String?
    let hasDescription: Bool
    let h1Count: Int
    let wordCount: Int
    let noindex: Bool
    let isHTTPS: Bool
    let internalLinks: [URL]
    let isHTML: Bool
    let signals: PageSignals
}

/// Глубокий обход сайта: ходит по внутренним ссылкам и страницам из sitemap,
/// собирая статистику по всему сайту (а не только по одной странице).
final class SiteCrawler: @unchecked Sendable {

    private let session: URLSession
    let maxPages: Int
    private let concurrency = 6

    init(session: URLSession, maxPages: Int) {
        self.session = session
        self.maxPages = max(1, maxPages)
    }

    /// Обходит сайт начиная со стартового URL, используя ссылки из sitemap как засев.
    ///
    /// Воркеры подаются в группу непрерывно: как только один скан завершается,
    /// слот сразу занимает следующий URL из очереди. Старая реализация ждала,
    /// пока вся пачка из `concurrency` догрузится, прежде чем начать следующую —
    /// одна медленная страница в пачке простаивала остальных воркеров впустую.
    func crawl(start: URL, seeds: [URL]) async -> [PageScan] {
        guard let baseHost = Self.baseHost(start) else { return [] }

        var visited = Set<String>()
        var queue: [URL] = []
        var enqueued = Set<String>()

        func enqueue(_ url: URL) {
            let key = Self.normalize(url)
            guard !enqueued.contains(key), Self.baseHost(url) == baseHost else { return }
            enqueued.insert(key)
            queue.append(url)
        }

        enqueue(start)
        for s in seeds { enqueue(s) }

        var results: [PageScan] = []

        // Координирующее замыкание withTaskGroup выполняется последовательно —
        // мутировать queue/visited/enqueued/results здесь безопасно, конкурентны
        // только сами задачи, добавленные через group.addTask.
        await withTaskGroup(of: PageScan?.self) { group in
            var inFlight = 0

            func nextQueued() -> URL? {
                while !queue.isEmpty {
                    let url = queue.removeFirst()
                    let key = Self.normalize(url)
                    if visited.contains(key) { continue }
                    visited.insert(key)
                    return url
                }
                return nil
            }

            func fillSlots() {
                while inFlight < concurrency,
                      results.count + inFlight < maxPages,
                      let url = nextQueued() {
                    group.addTask { await self.scan(url) }
                    inFlight += 1
                }
            }

            fillSlots()
            while inFlight > 0, let scan = await group.next() {
                inFlight -= 1
                if let scan {
                    results.append(scan)
                    // Засеваем новыми внутренними ссылками (с запасом для очереди).
                    if enqueued.count < maxPages * 5 {
                        for link in scan.internalLinks { enqueue(link) }
                    }
                }
                if results.count < maxPages { fillSlots() }
            }
        }

        return results
    }

    // MARK: - Сканирование одной страницы

    private func scan(_ url: URL) async -> PageScan? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else { return nil }

            let contentType = (http.allHeaderFields["Content-Type"] as? String
                ?? http.allHeaderFields["content-type"] as? String ?? "").lowercased()
            let isHTML = contentType.contains("text/html") || contentType.isEmpty

            // Для не-HTML (или ошибок) фиксируем только статус — это важно для «битых» ссылок.
            guard isHTML, http.statusCode < 400 else {
                return PageScan(url: url.absoluteString, status: http.statusCode, responseMs: ms,
                                title: nil, hasDescription: false, h1Count: 0, wordCount: 0,
                                noindex: false, isHTTPS: url.scheme == "https",
                                internalLinks: [], isHTML: isHTML, signals: .empty)
            }

            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let doc = HTMLDocument(html: html)

            // Внутренние ссылки.
            let base = http.url ?? url
            var links: [URL] = []
            for href in doc.anchorHrefs {
                if let resolved = URL(string: href, relativeTo: base)?.absoluteURL,
                   resolved.scheme?.hasPrefix("http") == true {
                    links.append(resolved)
                }
            }

            return PageScan(
                url: url.absoluteString,
                status: http.statusCode,
                responseMs: ms,
                title: doc.title,
                hasDescription: (doc.metaDescription?.isEmpty == false),
                h1Count: doc.headings(level: 1).count,
                wordCount: doc.wordCount,
                noindex: (doc.metaRobots ?? "").lowercased().contains("noindex"),
                isHTTPS: base.scheme == "https",
                internalLinks: links,
                isHTML: true,
                signals: doc.pageSignals()
            )
        } catch {
            // Сетевую ошибку трактуем как недоступную страницу (битую ссылку).
            return PageScan(url: url.absoluteString, status: -1, responseMs: 0,
                            title: nil, hasDescription: false, h1Count: 0, wordCount: 0,
                            noindex: false, isHTTPS: url.scheme == "https",
                            internalLinks: [], isHTML: false, signals: .empty)
        }
    }

    // MARK: - Помощники

    /// Базовый хост без www (для определения «своих» ссылок).
    static func baseHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Канонический ключ URL (без схемы-www-фрагмента, без хвостового слэша).
    static func normalize(_ url: URL) -> String {
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var path = url.path
        if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        if path.isEmpty { path = "/" }
        let query = url.query.map { "?\($0)" } ?? ""
        return host + path + query
    }

    /// Извлекает URL из текста sitemap.xml.
    static func parseSitemap(_ xml: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "<loc>\\s*(.*?)\\s*</loc>",
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return regex.matches(in: xml, options: [], range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: xml) else { return nil }
            return URL(string: String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
