import Foundation

/// Ошибки анализа.
enum AnalyzerError: LocalizedError {
    case invalidURL
    case requestFailed(String)
    case noData
    case notHTML

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Некорректный адрес сайта. Проверьте URL."
        case .requestFailed(let m): return "Не удалось загрузить страницу: \(m)"
        case .noData:               return "Сервер вернул пустой ответ."
        case .notHTML:              return "По указанному адресу нет HTML-страницы."
        }
    }
}

/// Сетевой ответ страницы со всеми метаданными, необходимыми для анализа.
private struct FetchedPage {
    let finalURL: URL
    let html: String
    let headers: [String: String]
    let statusCode: Int
    let byteCount: Int
    let responseTimeMs: Int
}

/// Главный движок SEO-анализа.
/// Загружает страницу, заголовки, robots.txt и sitemap.xml,
/// выполняет проверки и формирует отчёт.
final class Analyzer {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "SEOAnalyzer/1.0 (Macintosh; SEO Audit Bot)",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru,en;q=0.8"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Публичный API

    func analyze(urlString: String) async throws -> AnalysisReport {
        guard let url = Self.normalizeURL(urlString) else {
            throw AnalyzerError.invalidURL
        }

        let page = try await fetch(url: url)
        let doc = HTMLDocument(html: page.html)

        // Параллельно проверяем robots.txt и sitemap.xml.
        async let robotsExists = resourceExists(at: "/robots.txt", base: page.finalURL)
        async let sitemapExists = sitemapPresent(base: page.finalURL, robotsHTML: nil)

        let hasRobots = await robotsExists
        let hasSitemap = await sitemapExists

        let seo         = analyzeSEO(doc: doc, page: page, hasRobots: hasRobots, hasSitemap: hasSitemap)
        let performance = analyzePerformance(doc: doc, page: page)
        let usability   = analyzeUsability(doc: doc, page: page)
        let social      = analyzeSocial(doc: doc)
        let security    = analyzeSecurity(page: page)

        let categories = [seo, performance, usability, social, security]
        let overall = Self.weightedScore(categories)

        return AnalysisReport(
            requestedURL: urlString,
            finalURL: page.finalURL.absoluteString,
            date: Date(),
            categories: categories,
            overallScore: overall,
            pageTitle: doc.title,
            metaDescription: doc.metaDescription,
            h1Texts: doc.headings(level: 1),
            wordCount: doc.wordCount,
            pageSizeBytes: page.byteCount,
            responseTimeMs: page.responseTimeMs,
            serverHeader: page.headers["server"],
            ipInfo: page.finalURL.host
        )
    }

    // MARK: - Загрузка

    private func fetch(url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnalyzerError.requestFailed(error.localizedDescription)
        }
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw AnalyzerError.requestFailed("неизвестный ответ сервера")
        }
        guard !data.isEmpty else { throw AnalyzerError.noData }

        // Кодировку определяем по заголовку или по charset из HTML, иначе UTF-8.
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else { throw AnalyzerError.notHTML }

        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let val = v as? String {
                headers[key.lowercased()] = val
            }
        }

        return FetchedPage(
            finalURL: http.url ?? url,
            html: html,
            headers: headers,
            statusCode: http.statusCode,
            byteCount: data.count,
            responseTimeMs: elapsed
        )
    }

    private func resourceExists(at path: String, base: URL) async -> Bool {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return false }
        comps.path = path
        comps.query = nil
        guard let url = comps.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 200 && !data.isEmpty
            }
            return false
        } catch {
            return false
        }
    }

    private func sitemapPresent(base: URL, robotsHTML: String?) async -> Bool {
        // Проверяем стандартные расположения.
        for path in ["/sitemap.xml", "/sitemap_index.xml", "/sitemap-index.xml"] {
            if await resourceExists(at: path, base: base) { return true }
        }
        return false
    }

    // MARK: - SEO

    private func analyzeSEO(doc: HTMLDocument, page: FetchedPage,
                            hasRobots: Bool, hasSitemap: Bool) -> CategoryResult {
        var checks: [CheckItem] = []
        var points = 0
        var maxPoints = 0

        // Title
        maxPoints += 15
        if let title = doc.title, !title.isEmpty {
            let len = title.count
            if (10...70).contains(len) {
                points += 15
                checks.append(CheckItem("Тег Title", status: .passed,
                    detail: "«\(title)» (\(len) симв.)"))
            } else {
                points += 8
                checks.append(CheckItem("Тег Title", status: .warning,
                    detail: "«\(title)» (\(len) симв.)",
                    recommendation: "Оптимальная длина — 10–70 символов. Скорректируйте заголовок."))
            }
        } else {
            checks.append(CheckItem("Тег Title", status: .failed,
                detail: "Тег <title> отсутствует.",
                recommendation: "Добавьте уникальный заголовок страницы длиной 10–70 символов."))
        }

        // Meta description
        maxPoints += 12
        if let desc = doc.metaDescription, !desc.isEmpty {
            let len = desc.count
            if (70...160).contains(len) {
                points += 12
                checks.append(CheckItem("Meta Description", status: .passed,
                    detail: "«\(desc)» (\(len) симв.)"))
            } else {
                points += 6
                checks.append(CheckItem("Meta Description", status: .warning,
                    detail: "«\(desc)» (\(len) симв.)",
                    recommendation: "Рекомендуемая длина описания — 70–160 символов."))
            }
        } else {
            checks.append(CheckItem("Meta Description", status: .failed,
                detail: "Мета-описание отсутствует.",
                recommendation: "Добавьте мета-описание длиной 70–160 символов с ключевыми словами."))
        }

        // H1
        maxPoints += 12
        let h1 = doc.headings(level: 1)
        if h1.count == 1 {
            points += 12
            checks.append(CheckItem("Заголовок H1", status: .passed,
                detail: "Найден один H1: «\(h1[0])»"))
        } else if h1.count > 1 {
            points += 6
            checks.append(CheckItem("Заголовок H1", status: .warning,
                detail: "Найдено H1-заголовков: \(h1.count).",
                recommendation: "На странице желательно использовать ровно один H1."))
        } else {
            checks.append(CheckItem("Заголовок H1", status: .failed,
                detail: "H1 не найден.",
                recommendation: "Добавьте основной заголовок H1 с ключевой фразой."))
        }

        // Структура заголовков
        maxPoints += 8
        let h2 = doc.headings(level: 2).count
        let h3 = doc.headings(level: 3).count
        if h2 + h3 > 0 {
            points += 8
            checks.append(CheckItem("Структура заголовков", status: .passed,
                detail: "H2: \(h2), H3: \(h3). Иерархия присутствует."))
        } else {
            points += 2
            checks.append(CheckItem("Структура заголовков", status: .warning,
                detail: "Подзаголовки H2/H3 отсутствуют.",
                recommendation: "Структурируйте текст подзаголовками H2–H3."))
        }

        // Alt у изображений
        maxPoints += 10
        let imgs = doc.imageTags.count
        let noAlt = doc.imagesWithoutAlt.count
        if imgs == 0 {
            points += 6
            checks.append(CheckItem("Атрибуты ALT", status: .info,
                detail: "Изображений на странице не найдено."))
        } else if noAlt == 0 {
            points += 10
            checks.append(CheckItem("Атрибуты ALT", status: .passed,
                detail: "У всех \(imgs) изображений заполнен ALT."))
        } else {
            points += max(0, 10 - Int(Double(noAlt) / Double(imgs) * 10))
            checks.append(CheckItem("Атрибуты ALT", status: .warning,
                detail: "Без ALT: \(noAlt) из \(imgs) изображений.",
                recommendation: "Заполните атрибут alt у всех значимых изображений."))
        }

        // Объём контента
        maxPoints += 8
        let words = doc.wordCount
        if words >= 300 {
            points += 8
            checks.append(CheckItem("Объём контента", status: .passed,
                detail: "На странице ~\(words) слов."))
        } else {
            points += 3
            checks.append(CheckItem("Объём контента", status: .warning,
                detail: "На странице ~\(words) слов.",
                recommendation: "Поисковики предпочитают страницы от 300 слов содержательного текста."))
        }

        // Канонический URL
        maxPoints += 6
        if let canon = doc.canonical {
            points += 6
            checks.append(CheckItem("Канонический URL", status: .passed,
                detail: canon))
        } else {
            points += 2
            checks.append(CheckItem("Канонический URL", status: .warning,
                detail: "Тег rel=canonical не задан.",
                recommendation: "Добавьте <link rel=\"canonical\"> для защиты от дублей."))
        }

        // robots.txt
        maxPoints += 5
        if hasRobots {
            points += 5
            checks.append(CheckItem("Файл robots.txt", status: .passed,
                detail: "Файл robots.txt найден."))
        } else {
            checks.append(CheckItem("Файл robots.txt", status: .failed,
                detail: "robots.txt не найден.",
                recommendation: "Создайте robots.txt в корне сайта."))
        }

        // sitemap.xml
        maxPoints += 5
        if hasSitemap {
            points += 5
            checks.append(CheckItem("Карта сайта XML", status: .passed,
                detail: "Файл sitemap.xml найден."))
        } else {
            checks.append(CheckItem("Карта сайта XML", status: .failed,
                detail: "sitemap.xml не найден.",
                recommendation: "Сгенерируйте и разместите XML-карту сайта."))
        }

        // Индексация (robots meta)
        maxPoints += 5
        if let robots = doc.metaRobots, robots.lowercased().contains("noindex") {
            checks.append(CheckItem("Индексация", status: .failed,
                detail: "Страница закрыта от индексации (noindex).",
                recommendation: "Уберите noindex, если страница должна индексироваться."))
        } else {
            points += 5
            checks.append(CheckItem("Индексация", status: .passed,
                detail: "Страница открыта для индексации."))
        }

        // Атрибут языка
        maxPoints += 4
        if let lang = doc.langAttribute, !lang.isEmpty {
            points += 4
            checks.append(CheckItem("Язык страницы", status: .passed,
                detail: "lang=\"\(lang)\""))
        } else {
            checks.append(CheckItem("Язык страницы", status: .warning,
                detail: "Атрибут lang не указан в <html>.",
                recommendation: "Добавьте lang в тег <html> (например, lang=\"ru\")."))
        }

        let score = Self.percentage(points, of: maxPoints)
        return CategoryResult(category: .seo, score: score, checks: checks)
    }

    // MARK: - Производительность

    private func analyzePerformance(doc: HTMLDocument, page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var points = 0
        var maxPoints = 0

        // Время ответа
        maxPoints += 20
        let ms = page.responseTimeMs
        if ms < 600 {
            points += 20
            checks.append(CheckItem("Время ответа сервера", status: .passed,
                detail: "\(ms) мс — быстро."))
        } else if ms < 1500 {
            points += 12
            checks.append(CheckItem("Время ответа сервера", status: .warning,
                detail: "\(ms) мс.",
                recommendation: "Стремитесь к времени ответа менее 600 мс."))
        } else {
            points += 4
            checks.append(CheckItem("Время ответа сервера", status: .failed,
                detail: "\(ms) мс — медленно.",
                recommendation: "Оптимизируйте сервер, кэширование и БД."))
        }

        // Размер страницы (HTML)
        maxPoints += 15
        let kb = page.byteCount / 1024
        if kb < 100 {
            points += 15
            checks.append(CheckItem("Размер HTML", status: .passed,
                detail: "\(kb) КБ."))
        } else if kb < 300 {
            points += 9
            checks.append(CheckItem("Размер HTML", status: .warning,
                detail: "\(kb) КБ.",
                recommendation: "Желательно держать HTML до 100 КБ."))
        } else {
            points += 3
            checks.append(CheckItem("Размер HTML", status: .failed,
                detail: "\(kb) КБ — велик.",
                recommendation: "Сократите разметку и вынесите inline-данные."))
        }

        // Gzip / сжатие
        maxPoints += 12
        let encoding = page.headers["content-encoding"]?.lowercased() ?? ""
        if encoding.contains("gzip") || encoding.contains("br") || encoding.contains("deflate") {
            points += 12
            checks.append(CheckItem("Сжатие ответа", status: .passed,
                detail: "Включено: \(encoding)."))
        } else {
            checks.append(CheckItem("Сжатие ответа", status: .failed,
                detail: "Сжатие (gzip/brotli) не обнаружено.",
                recommendation: "Включите gzip или brotli на сервере."))
        }

        // Количество JS
        maxPoints += 10
        let scripts = doc.scriptTags.count
        if scripts <= 10 {
            points += 10
            checks.append(CheckItem("Внешние JS-файлы", status: .passed,
                detail: "Подключено скриптов: \(scripts)."))
        } else {
            points += 4
            checks.append(CheckItem("Внешние JS-файлы", status: .warning,
                detail: "Подключено скриптов: \(scripts).",
                recommendation: "Объединяйте и откладывайте загрузку скриптов."))
        }

        // Количество CSS
        maxPoints += 8
        let css = doc.stylesheetLinks.count
        if css <= 6 {
            points += 8
            checks.append(CheckItem("Внешние CSS-файлы", status: .passed,
                detail: "Подключено таблиц стилей: \(css)."))
        } else {
            points += 3
            checks.append(CheckItem("Внешние CSS-файлы", status: .warning,
                detail: "Подключено таблиц стилей: \(css).",
                recommendation: "Объединяйте CSS-файлы для сокращения запросов."))
        }

        // Inline-стили
        maxPoints += 7
        let inline = doc.inlineStyleCount
        if inline <= 5 {
            points += 7
            checks.append(CheckItem("Инлайн-стили", status: .passed,
                detail: "Инлайн-стилей: \(inline)."))
        } else {
            points += 2
            checks.append(CheckItem("Инлайн-стили", status: .warning,
                detail: "Инлайн-стилей: \(inline).",
                recommendation: "Выносите стили в отдельные CSS-файлы."))
        }

        // Кэширование
        maxPoints += 8
        if let cache = page.headers["cache-control"], !cache.isEmpty {
            points += 8
            checks.append(CheckItem("Кэширование", status: .passed,
                detail: "Cache-Control: \(cache)"))
        } else {
            checks.append(CheckItem("Кэширование", status: .warning,
                detail: "Заголовок Cache-Control не задан.",
                recommendation: "Настройте кэширование статических ресурсов."))
        }

        // DOCTYPE
        maxPoints += 5
        if doc.hasDoctype {
            points += 5
            checks.append(CheckItem("DOCTYPE", status: .passed,
                detail: "Объявление <!DOCTYPE> присутствует."))
        } else {
            checks.append(CheckItem("DOCTYPE", status: .warning,
                detail: "DOCTYPE не объявлен.",
                recommendation: "Добавьте <!DOCTYPE html> в начало документа."))
        }

        let score = Self.percentage(points, of: maxPoints)
        return CategoryResult(category: .performance, score: score, checks: checks)
    }

    // MARK: - Удобство использования

    private func analyzeUsability(doc: HTMLDocument, page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var points = 0
        var maxPoints = 0

        // Viewport (адаптивность)
        maxPoints += 25
        if let vp = doc.metaViewport {
            points += 25
            checks.append(CheckItem("Мобильная адаптация (viewport)", status: .passed,
                detail: "viewport: \(vp)"))
        } else {
            checks.append(CheckItem("Мобильная адаптация (viewport)", status: .failed,
                detail: "Мета-тег viewport отсутствует.",
                recommendation: "Добавьте <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">."))
        }

        // Favicon
        maxPoints += 15
        if doc.hasFavicon {
            points += 15
            checks.append(CheckItem("Иконка сайта (favicon)", status: .passed,
                detail: "Favicon подключён."))
        } else {
            checks.append(CheckItem("Иконка сайта (favicon)", status: .warning,
                detail: "Favicon не найден.",
                recommendation: "Добавьте favicon для узнаваемости во вкладках."))
        }

        // Apple touch icon
        maxPoints += 10
        if doc.hasAppleTouchIcon {
            points += 10
            checks.append(CheckItem("Иконка для iOS", status: .passed,
                detail: "apple-touch-icon подключён."))
        } else {
            points += 3
            checks.append(CheckItem("Иконка для iOS", status: .warning,
                detail: "apple-touch-icon не найден.",
                recommendation: "Добавьте apple-touch-icon для добавления на домашний экран."))
        }

        // Кодировка
        maxPoints += 15
        if let charset = doc.charset {
            points += 15
            checks.append(CheckItem("Кодировка символов", status: .passed,
                detail: "charset: \(charset)"))
        } else {
            points += 5
            checks.append(CheckItem("Кодировка символов", status: .warning,
                detail: "Кодировка явно не указана.",
                recommendation: "Укажите <meta charset=\"utf-8\">."))
        }

        // Заголовок страницы для пользователя
        maxPoints += 15
        if let title = doc.title, !title.isEmpty {
            points += 15
            checks.append(CheckItem("Понятный заголовок", status: .passed,
                detail: "Заголовок присутствует."))
        } else {
            checks.append(CheckItem("Понятный заголовок", status: .failed,
                detail: "Заголовок страницы отсутствует.",
                recommendation: "Добавьте информативный <title>."))
        }

        // Печатаемость/доступность контента
        maxPoints += 20
        let words = doc.wordCount
        if words > 150 {
            points += 20
            checks.append(CheckItem("Читаемость контента", status: .passed,
                detail: "Содержимое доступно для чтения (~\(words) слов)."))
        } else {
            points += 8
            checks.append(CheckItem("Читаемость контента", status: .warning,
                detail: "Текстового контента мало (~\(words) слов).",
                recommendation: "Добавьте больше полезного текстового содержимого."))
        }

        let score = Self.percentage(points, of: maxPoints)
        return CategoryResult(category: .usability, score: score, checks: checks)
    }

    // MARK: - Социальные сети

    private func analyzeSocial(doc: HTMLDocument) -> CategoryResult {
        var checks: [CheckItem] = []
        var points = 0
        var maxPoints = 0

        // Open Graph
        maxPoints += 35
        if doc.hasOpenGraph {
            points += 35
            let title = doc.metaProperty("og:title") ?? "—"
            checks.append(CheckItem("Open Graph", status: .passed,
                detail: "Разметка Open Graph найдена. og:title: «\(title)»"))
        } else {
            checks.append(CheckItem("Open Graph", status: .failed,
                detail: "Разметка Open Graph отсутствует.",
                recommendation: "Добавьте og:title, og:description, og:image для красивых превью."))
        }

        // Twitter Card
        maxPoints += 25
        if doc.hasTwitterCard {
            points += 25
            checks.append(CheckItem("Twitter Card", status: .passed,
                detail: "Разметка Twitter Card найдена."))
        } else {
            checks.append(CheckItem("Twitter Card", status: .warning,
                detail: "Разметка Twitter Card отсутствует.",
                recommendation: "Добавьте twitter:card, twitter:title, twitter:image."))
        }

        // Ссылки на соцсети
        maxPoints += 40
        let social = doc.socialLinks
        let present = social.filter { $0.value }.map { $0.key }.sorted()
        if !present.isEmpty {
            points += min(40, 10 + present.count * 8)
            checks.append(CheckItem("Присутствие в соцсетях", status: .passed,
                detail: "Найдены ссылки: \(present.joined(separator: ", "))."))
        } else {
            checks.append(CheckItem("Присутствие в соцсетях", status: .warning,
                detail: "Ссылки на соцсети не найдены.",
                recommendation: "Добавьте ссылки на ваши профили в соцсетях."))
        }

        let score = Self.percentage(points, of: maxPoints)
        return CategoryResult(category: .social, score: score, checks: checks)
    }

    // MARK: - Безопасность

    private func analyzeSecurity(page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var points = 0
        var maxPoints = 0

        // HTTPS
        maxPoints += 30
        if page.finalURL.scheme?.lowercased() == "https" {
            points += 30
            checks.append(CheckItem("Шифрование HTTPS (SSL)", status: .passed,
                detail: "Сайт работает по защищённому протоколу HTTPS."))
        } else {
            checks.append(CheckItem("Шифрование HTTPS (SSL)", status: .failed,
                detail: "Сайт работает по незащищённому HTTP.",
                recommendation: "Установите SSL-сертификат и переведите сайт на HTTPS."))
        }

        // HSTS
        maxPoints += 15
        if page.headers["strict-transport-security"] != nil {
            points += 15
            checks.append(CheckItem("HSTS", status: .passed,
                detail: "Заголовок Strict-Transport-Security присутствует."))
        } else {
            checks.append(CheckItem("HSTS", status: .warning,
                detail: "Заголовок HSTS не задан.",
                recommendation: "Добавьте Strict-Transport-Security для защиты от downgrade-атак."))
        }

        // X-Content-Type-Options
        maxPoints += 12
        if let v = page.headers["x-content-type-options"], v.lowercased().contains("nosniff") {
            points += 12
            checks.append(CheckItem("X-Content-Type-Options", status: .passed,
                detail: "nosniff установлен."))
        } else {
            checks.append(CheckItem("X-Content-Type-Options", status: .warning,
                detail: "Заголовок не задан.",
                recommendation: "Добавьте X-Content-Type-Options: nosniff."))
        }

        // X-Frame-Options
        maxPoints += 12
        if page.headers["x-frame-options"] != nil
            || (page.headers["content-security-policy"]?.lowercased().contains("frame-ancestors") ?? false) {
            points += 12
            checks.append(CheckItem("Защита от кликджекинга", status: .passed,
                detail: "X-Frame-Options или CSP frame-ancestors заданы."))
        } else {
            checks.append(CheckItem("Защита от кликджекинга", status: .warning,
                detail: "X-Frame-Options не задан.",
                recommendation: "Добавьте X-Frame-Options: SAMEORIGIN."))
        }

        // Content-Security-Policy
        maxPoints += 16
        if page.headers["content-security-policy"] != nil {
            points += 16
            checks.append(CheckItem("Content-Security-Policy", status: .passed,
                detail: "Политика безопасности контента задана."))
        } else {
            checks.append(CheckItem("Content-Security-Policy", status: .warning,
                detail: "CSP не настроена.",
                recommendation: "Настройте Content-Security-Policy для защиты от XSS."))
        }

        // Раскрытие сервера
        maxPoints += 15
        if let server = page.headers["server"], server.rangeOfCharacter(from: .decimalDigits) != nil {
            points += 5
            checks.append(CheckItem("Раскрытие версии сервера", status: .warning,
                detail: "Server: \(server)",
                recommendation: "Скройте версию ПО сервера в заголовке Server."))
        } else {
            points += 15
            checks.append(CheckItem("Раскрытие версии сервера", status: .passed,
                detail: "Версия серверного ПО не раскрывается."))
        }

        let score = Self.percentage(points, of: maxPoints)
        return CategoryResult(category: .security, score: score, checks: checks)
    }

    // MARK: - Вспомогательное

    private static func percentage(_ value: Int, of max: Int) -> Int {
        guard max > 0 else { return 0 }
        return Int((Double(value) / Double(max) * 100).rounded())
    }

    private static func weightedScore(_ categories: [CategoryResult]) -> Int {
        var sum = 0.0
        for c in categories {
            sum += Double(c.score) * c.category.weight
        }
        return Int(sum.rounded())
    }

    /// Приводит пользовательский ввод к корректному URL (добавляет https:// при необходимости).
    static func normalizeURL(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}
