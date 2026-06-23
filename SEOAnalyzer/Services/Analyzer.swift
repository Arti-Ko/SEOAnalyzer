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

/// Накопитель честной оценки.
/// Каждая проверка вносит вес в знаменатель; «пройдено» — полный балл,
/// «замечание» — частичный (по умолчанию треть), «ошибка» — ноль.
/// «Информационные» проверки не учитываются вовсе (не завышают и не занижают балл).
private struct Scorer {
    private(set) var earned = 0.0
    private(set) var possible = 0.0

    mutating func add(_ weight: Double, _ status: CheckStatus, credit: Double = 0.33) {
        switch status {
        case .info:    break
        case .passed:  earned += weight;          possible += weight
        case .warning: earned += weight * credit; possible += weight
        case .failed:                              possible += weight
        }
    }

    var score: Int { possible > 0 ? Int((earned / possible * 100).rounded()) : 0 }
}

/// Главный движок анализа: SEO, AEO, GEO, производительность, удобство, безопасность, соцсети.
/// Загружает страницу, заголовки, robots.txt, sitemap.xml и llms.txt; разбирает HTML;
/// выставляет строгие, не завышенные оценки.
final class Analyzer {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "SEOAnalyzer/1.1 (Macintosh; SEO/AEO/GEO Audit Bot)",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "ru,en;q=0.8"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Публичный API

    func analyze(urlString: String, crawlLimit: Int = 50) async throws -> AnalysisReport {
        guard let url = Self.normalizeURL(urlString) else { throw AnalyzerError.invalidURL }

        let page = try await fetch(url: url)
        let doc = HTMLDocument(html: page.html)

        // Параллельно подтягиваем служебные ресурсы.
        async let robotsTextTask  = fetchText(at: "/robots.txt", base: page.finalURL)
        async let sitemapTextTask = fetchText(at: "/sitemap.xml", base: page.finalURL)
        async let llmsTask        = resourceExists(at: "/llms.txt", base: page.finalURL)

        let robotsText  = await robotsTextTask
        let sitemapText = await sitemapTextTask
        let hasLLMs     = await llmsTask
        let hasRobots   = robotsText != nil
        let hasSitemap  = sitemapText != nil
        let robots      = RobotsTxt(robotsText ?? "")

        // Глубокий обход сайта: засеваем ссылками из sitemap.
        let seeds = sitemapText.map { SiteCrawler.parseSitemap($0) } ?? []
        let crawler = SiteCrawler(session: session, maxPages: crawlLimit)
        let scans = await crawler.crawl(start: page.finalURL, seeds: seeds)

        let seo         = analyzeSEO(doc: doc, hasRobots: hasRobots, hasSitemap: hasSitemap)
        let aeo         = analyzeAEO(doc: doc)
        let geo         = analyzeGEO(doc: doc, page: page, robots: robots, hasRobots: hasRobots, hasLLMs: hasLLMs)
        let crawl       = analyzeCrawl(scans: scans, hasSitemap: hasSitemap)
        let performance = analyzePerformance(doc: doc, page: page)
        let usability   = analyzeUsability(doc: doc, page: page)
        let security    = analyzeSecurity(page: page)
        let social      = analyzeSocial(doc: doc)

        // Порядок — как в SEOCategory.allCases.
        let categories = [seo, aeo, geo, crawl, performance, usability, security, social]
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
            ipInfo: page.finalURL.host,
            pagesScanned: max(1, scans.count)
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

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else { throw AnalyzerError.notHTML }

        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, let val = v as? String { headers[key.lowercased()] = val }
        }

        return FetchedPage(finalURL: http.url ?? url, html: html, headers: headers,
                           statusCode: http.statusCode, byteCount: data.count, responseTimeMs: elapsed)
    }

    /// Загружает текстовый ресурс (robots.txt и т.п.); nil — если недоступен или пуст.
    private func fetchText(at path: String, base: URL) async -> String? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = path; comps.query = nil
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    private func resourceExists(at path: String, base: URL) async -> Bool {
        await fetchText(at: path, base: base) != nil
    }

    private func sitemapPresent(base: URL) async -> Bool {
        for path in ["/sitemap.xml", "/sitemap_index.xml", "/sitemap-index.xml"] {
            if await resourceExists(at: path, base: base) { return true }
        }
        return false
    }

    // MARK: - SEO

    private func analyzeSEO(doc: HTMLDocument, hasRobots: Bool, hasSitemap: Bool) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Title (оптимум 30–60, допустимо 10–70)
        if let title = doc.title, !title.isEmpty {
            let len = title.count
            if (10...70).contains(len) {
                record(15, CheckItem("Тег Title", status: .passed, detail: "«\(title)» (\(len) симв.)"))
            } else {
                record(15, CheckItem("Тег Title", status: .warning,
                    detail: "«\(title)» (\(len) симв.) — вне диапазона 10–70.",
                    recommendation: "Сделайте заголовок 10–70 символов (оптимум 30–60)."), credit: 0.5)
            }
        } else {
            record(15, CheckItem("Тег Title", status: .failed, detail: "Тег <title> отсутствует.",
                recommendation: "Добавьте уникальный заголовок страницы 10–70 символов."))
        }

        // Meta description
        if let desc = doc.metaDescription, !desc.isEmpty {
            let len = desc.count
            if (70...160).contains(len) {
                record(12, CheckItem("Meta Description", status: .passed, detail: "«\(desc)» (\(len) симв.)"))
            } else {
                record(12, CheckItem("Meta Description", status: .warning,
                    detail: "«\(desc)» (\(len) симв.) — вне диапазона 70–160.",
                    recommendation: "Сделайте описание 70–160 символов."), credit: 0.5)
            }
        } else {
            record(12, CheckItem("Meta Description", status: .failed, detail: "Мета-описание отсутствует.",
                recommendation: "Добавьте мета-описание 70–160 символов с ключевыми словами."))
        }

        // H1
        let h1 = doc.headings(level: 1)
        if h1.count == 1 {
            record(10, CheckItem("Заголовок H1", status: .passed, detail: "Один H1: «\(h1[0])»"))
        } else if h1.count > 1 {
            record(10, CheckItem("Заголовок H1", status: .warning,
                detail: "H1-заголовков: \(h1.count) (должен быть один).",
                recommendation: "Оставьте ровно один H1 на странице."), credit: 0.4)
        } else {
            record(10, CheckItem("Заголовок H1", status: .failed, detail: "H1 не найден.",
                recommendation: "Добавьте основной заголовок H1 с ключевой фразой."))
        }

        // Структура подзаголовков
        let h2 = doc.headings(level: 2).count, h3 = doc.headings(level: 3).count
        if h2 > 0 {
            record(6, CheckItem("Структура заголовков", status: .passed, detail: "H2: \(h2), H3: \(h3)."))
        } else {
            record(6, CheckItem("Структура заголовков", status: .warning,
                detail: "Подзаголовки H2 отсутствуют.",
                recommendation: "Структурируйте текст подзаголовками H2–H3."), credit: 0.3)
        }

        // ALT у изображений
        let imgs = doc.imageTags.count, noAlt = doc.imagesWithoutAlt.count
        if imgs == 0 {
            record(8, CheckItem("Атрибуты ALT", status: .info, detail: "Изображений на странице нет."))
        } else if noAlt == 0 {
            record(8, CheckItem("Атрибуты ALT", status: .passed, detail: "У всех \(imgs) изображений заполнен ALT."))
        } else {
            let credit = Double(imgs - noAlt) / Double(imgs)
            record(8, CheckItem("Атрибуты ALT", status: .warning,
                detail: "Без ALT: \(noAlt) из \(imgs).",
                recommendation: "Заполните alt у всех значимых изображений."), credit: credit)
        }

        // Объём контента (строго: < 300 слов — тонкий контент)
        let words = doc.wordCount
        if words >= 600 {
            record(8, CheckItem("Объём контента", status: .passed, detail: "~\(words) слов."))
        } else if words >= 300 {
            record(8, CheckItem("Объём контента", status: .warning, detail: "~\(words) слов (желательно 600+).",
                recommendation: "Наращивайте содержательный текст до 600+ слов."), credit: 0.5)
        } else {
            record(8, CheckItem("Объём контента", status: .failed, detail: "~\(words) слов — тонкий контент.",
                recommendation: "Тонкие страницы (<300 слов) плохо ранжируются. Добавьте полезный текст."))
        }

        // Канонический URL
        if let canon = doc.canonical {
            record(5, CheckItem("Канонический URL", status: .passed, detail: canon))
        } else {
            record(5, CheckItem("Канонический URL", status: .failed, detail: "rel=canonical не задан.",
                recommendation: "Добавьте <link rel=\"canonical\"> против дублей."))
        }

        // robots.txt
        record(5, hasRobots
            ? CheckItem("Файл robots.txt", status: .passed, detail: "robots.txt найден.")
            : CheckItem("Файл robots.txt", status: .failed, detail: "robots.txt не найден.",
                recommendation: "Создайте robots.txt в корне сайта."))

        // sitemap.xml
        record(5, hasSitemap
            ? CheckItem("Карта сайта XML", status: .passed, detail: "sitemap.xml найден.")
            : CheckItem("Карта сайта XML", status: .failed, detail: "sitemap.xml не найден.",
                recommendation: "Сгенерируйте и разместите XML-карту сайта."))

        // Индексация
        if let robots = doc.metaRobots, robots.lowercased().contains("noindex") {
            record(6, CheckItem("Индексация", status: .failed, detail: "Страница закрыта (noindex).",
                recommendation: "Уберите noindex, если страница должна индексироваться."))
        } else {
            record(6, CheckItem("Индексация", status: .passed, detail: "Страница открыта для индексации."))
        }

        // Язык страницы
        if let lang = doc.langAttribute, !lang.isEmpty {
            record(4, CheckItem("Язык страницы", status: .passed, detail: "lang=\"\(lang)\""))
        } else {
            record(4, CheckItem("Язык страницы", status: .failed, detail: "Атрибут lang не указан в <html>.",
                recommendation: "Добавьте lang в тег <html> (например, lang=\"ru\")."))
        }

        return CategoryResult(category: .seo, score: s.score, checks: checks)
    }

    // MARK: - AEO (Answer Engine Optimization)

    private func analyzeAEO(doc: HTMLDocument) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Структурированные данные (основа для ответных систем)
        if doc.hasStructuredData {
            record(22, CheckItem("Структурированные данные (Schema.org)", status: .passed,
                detail: "Найдена разметка: \(doc.hasJSONLD ? "JSON-LD" : "микроразметка")."))
        } else {
            record(22, CheckItem("Структурированные данные (Schema.org)", status: .failed,
                detail: "Разметки Schema.org нет.",
                recommendation: "Добавьте JSON-LD (Article, FAQPage, Organization) — без неё страница почти не попадает в ответы поисковиков."))
        }

        // FAQ / QA схема
        if doc.hasSchemaType("FAQPage") || doc.hasSchemaType("QAPage") {
            record(12, CheckItem("FAQ-разметка", status: .passed, detail: "Найдена схема FAQPage/QAPage."))
        } else {
            record(12, CheckItem("FAQ-разметка", status: .warning, detail: "Схема FAQPage не найдена.",
                recommendation: "Оформите блок вопросов-ответов разметкой FAQPage для расширенных сниппетов."), credit: 0.3)
        }

        // Заголовки-вопросы
        let q = doc.questionHeadings().count
        if q >= 1 {
            record(10, CheckItem("Заголовки-вопросы", status: .passed, detail: "Заголовков в форме вопроса: \(q)."))
        } else {
            record(10, CheckItem("Заголовки-вопросы", status: .warning, detail: "Нет заголовков в форме вопроса.",
                recommendation: "Добавьте подзаголовки-вопросы («Как…?», «Что такое…?») — под них формируются ответы."), credit: 0.3)
        }

        // Списки (дружелюбны к featured snippet)
        record(8, doc.listCount > 0
            ? CheckItem("Списки", status: .passed, detail: "Маркированных/нумерованных списков: \(doc.listCount).")
            : CheckItem("Списки", status: .warning, detail: "Списков (ul/ol) нет.",
                recommendation: "Структурируйте ответы списками — их часто берут в сниппеты."), credit: 0.4)

        // Таблицы
        record(6, doc.tableCount > 0
            ? CheckItem("Таблицы данных", status: .passed, detail: "Таблиц: \(doc.tableCount).")
            : CheckItem("Таблицы данных", status: .warning, detail: "Таблиц нет.",
                recommendation: "Сравнительные данные оформляйте таблицами — удобны для ответов."), credit: 0.5)

        // Article / HowTo
        if doc.hasSchemaType("Article") || doc.hasSchemaType("HowTo") || doc.hasSchemaType("NewsArticle") {
            record(8, CheckItem("Разметка контента (Article/HowTo)", status: .passed, detail: "Найдена схема Article/HowTo."))
        } else {
            record(8, CheckItem("Разметка контента (Article/HowTo)", status: .warning, detail: "Схемы Article/HowTo нет.",
                recommendation: "Размечайте статьи и инструкции схемами Article/HowTo."), credit: 0.3)
        }

        // Хлебные крошки
        if doc.hasSchemaType("BreadcrumbList") {
            record(8, CheckItem("Хлебные крошки (Breadcrumb)", status: .passed, detail: "Найдена схема BreadcrumbList."))
        } else {
            record(8, CheckItem("Хлебные крошки (Breadcrumb)", status: .warning, detail: "Разметки BreadcrumbList нет.",
                recommendation: "Добавьте BreadcrumbList — помогает в навигационных сниппетах."), credit: 0.3)
        }

        // Speakable (голосовой поиск)
        record(6, doc.hasSpeakable
            ? CheckItem("Голосовой поиск (speakable)", status: .passed, detail: "Найдена разметка speakable.")
            : CheckItem("Голосовой поиск (speakable)", status: .warning, detail: "Разметки speakable нет.",
                recommendation: "Для голосовых ассистентов добавьте speakable к ключевым блокам."), credit: 0.25)

        // Краткое описание-ответ
        if let d = doc.metaDescription, !d.isEmpty {
            record(8, CheckItem("Краткий ответ (description)", status: .passed, detail: "Description пригоден как краткий ответ."))
        } else {
            record(8, CheckItem("Краткий ответ (description)", status: .failed, detail: "Нет краткого описания страницы.",
                recommendation: "Добавьте лаконичное description — его используют как готовый ответ."))
        }

        // Сниппеты не запрещены
        let robots = (doc.metaRobots ?? "").lowercased()
        if robots.contains("nosnippet") || robots.contains("max-snippet:0") {
            record(6, CheckItem("Разрешение сниппетов", status: .failed, detail: "Сниппеты запрещены (nosnippet/max-snippet:0).",
                recommendation: "Уберите nosnippet — иначе ответные системы не покажут ваш текст."))
        } else {
            record(6, CheckItem("Разрешение сниппетов", status: .passed, detail: "Сниппеты разрешены."))
        }

        return CategoryResult(category: .aeo, score: s.score, checks: checks)
    }

    // MARK: - GEO (Generative Engine Optimization)

    private func analyzeGEO(doc: HTMLDocument, page: FetchedPage, robots: RobotsTxt,
                            hasRobots: Bool, hasLLMs: Bool) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Структурированные данные (машиночитаемость для ИИ)
        record(16, doc.hasStructuredData
            ? CheckItem("Машиночитаемая разметка", status: .passed, detail: "Schema.org присутствует.")
            : CheckItem("Машиночитаемая разметка", status: .failed, detail: "Schema.org отсутствует.",
                recommendation: "ИИ-поисковики опираются на структурированные данные — добавьте JSON-LD."))

        // Доступ ИИ-роботов (GPTBot, ClaudeBot, PerplexityBot, Google-Extended, CCBot…)
        let aiBots = ["GPTBot", "ClaudeBot", "Claude-Web", "anthropic-ai", "PerplexityBot",
                      "Google-Extended", "CCBot", "Applebot-Extended", "Bytespider", "Amazonbot"]
        if hasRobots && robots.blocksEveryone {
            record(16, CheckItem("Доступ ИИ-роботов", status: .failed,
                detail: "robots.txt закрывает сайт для всех роботов (Disallow: /).",
                recommendation: "Полная блокировка делает сайт невидимым для генеративных систем."))
        } else {
            let blocked = aiBots.filter { robots.mentions($0) && robots.blocksEntirely($0) }
            if blocked.isEmpty {
                record(16, CheckItem("Доступ ИИ-роботов", status: .passed,
                    detail: hasRobots ? "ИИ-роботы не заблокированы в robots.txt." : "robots.txt не ограничивает ИИ-роботов."))
            } else {
                record(16, CheckItem("Доступ ИИ-роботов", status: .warning,
                    detail: "Заблокированы: \(blocked.joined(separator: ", ")).",
                    recommendation: "Эти ИИ-краулеры не смогут цитировать ваш контент. Разблокируйте нужных в robots.txt."), credit: 0.4)
            }
        }

        // llms.txt
        record(8, hasLLMs
            ? CheckItem("Файл llms.txt", status: .passed, detail: "Найден llms.txt (гид для ИИ-моделей).")
            : CheckItem("Файл llms.txt", status: .warning, detail: "llms.txt отсутствует.",
                recommendation: "Добавьте /llms.txt — новый стандарт-подсказка для ИИ о структуре сайта."), credit: 0.25)

        // Авторство / экспертность (E-E-A-T)
        record(12, doc.hasAuthorSignal
            ? CheckItem("Авторство (E-E-A-T)", status: .passed, detail: "Есть сигналы авторства.")
            : CheckItem("Авторство (E-E-A-T)", status: .failed, detail: "Нет указания автора/эксперта.",
                recommendation: "Добавьте автора (мета author, схема Person) — ИИ ценит экспертность источника."))

        // Дата публикации/обновления
        record(10, doc.hasDateSignal
            ? CheckItem("Дата публикации/обновления", status: .passed, detail: "Дата материала размечена.")
            : CheckItem("Дата публикации/обновления", status: .warning, detail: "Даты публикации нет.",
                recommendation: "Указывайте дату (datePublished/<time>) — свежесть важна для ИИ-ответов."), credit: 0.3)

        // Цитирование источников (внешние ссылки)
        let ext = doc.externalLinkCount(host: page.finalURL.host)
        if ext >= 3 {
            record(12, CheckItem("Ссылки на источники", status: .passed, detail: "Внешних ссылок: \(ext)."))
        } else if ext >= 1 {
            record(12, CheckItem("Ссылки на источники", status: .warning, detail: "Внешних ссылок: \(ext).",
                recommendation: "Ссылайтесь на авторитетные источники — это повышает цитируемость в ИИ."), credit: 0.5)
        } else {
            record(12, CheckItem("Ссылки на источники", status: .failed, detail: "Внешних ссылок нет.",
                recommendation: "Добавьте ссылки на источники/исследования — генеративные системы доверяют им."))
        }

        // Фактура: статистика и цифры
        let stats = doc.percentSignals + (doc.numberSignals / 3)
        if stats >= 5 {
            record(8, CheckItem("Статистика и цифры", status: .passed, detail: "Достаточно числовой фактуры."))
        } else {
            record(8, CheckItem("Статистика и цифры", status: .warning, detail: "Мало конкретных данных/цифр.",
                recommendation: "Добавляйте статистику, проценты, конкретику — ИИ охотнее цитирует факты."), credit: 0.4)
        }

        // Семантический HTML5
        let sem = doc.semanticTags
        if sem.count >= 4 {
            record(10, CheckItem("Семантический HTML5", status: .passed, detail: "Теги: \(sem.joined(separator: ", "))."))
        } else if sem.count >= 1 {
            record(10, CheckItem("Семантический HTML5", status: .warning, detail: "Семантических тегов мало: \(sem.joined(separator: ", ")).",
                recommendation: "Используйте <article>, <section>, <main>, <nav> — это помогает ИИ разбирать контент."), credit: 0.5)
        } else {
            record(10, CheckItem("Семантический HTML5", status: .failed, detail: "Нет семантических тегов HTML5.",
                recommendation: "Переходите на семантическую вёрстку (<article>, <section>, <main>)."))
        }

        // Привязка к сущностям
        record(8, doc.hasEntityAuthority
            ? CheckItem("Связь с авторитетными сущностями", status: .passed, detail: "Есть sameAs/ссылки на Wikipedia/Wikidata.")
            : CheckItem("Связь с авторитетными сущностями", status: .warning, detail: "Нет sameAs/привязки к Wikidata.",
                recommendation: "Добавьте sameAs к Wikipedia/Wikidata/соцсетям — ИИ точнее идентифицирует бренд."), credit: 0.3)

        // Глубина контента
        let words = doc.wordCount
        if words >= 800 {
            record(10, CheckItem("Глубина материала", status: .passed, detail: "~\(words) слов."))
        } else if words >= 400 {
            record(10, CheckItem("Глубина материала", status: .warning, detail: "~\(words) слов (для ИИ желательно 800+).",
                recommendation: "Раскрывайте тему глубже — поверхностный текст реже попадает в ИИ-ответы."), credit: 0.5)
        } else {
            record(10, CheckItem("Глубина материала", status: .failed, detail: "~\(words) слов — слишком поверхностно.",
                recommendation: "Генеративные системы предпочитают исчерпывающие материалы."))
        }

        return CategoryResult(category: .geo, score: s.score, checks: checks)
    }

    // MARK: - Сканирование сайта (site-wide)

    private func analyzeCrawl(scans: [PageScan], hasSitemap: Bool) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        let htmlPages = scans.filter { $0.isHTML && $0.status >= 200 && $0.status < 400 }
        let total = htmlPages.count
        let broken = scans.filter { $0.status >= 400 || $0.status < 0 }

        // Сколько страниц обойдено
        record(0, CheckItem("Охват сканирования", status: .info,
            detail: "Просканировано страниц: \(scans.count) (HTML-страниц: \(total))."
                + (hasSitemap ? " Засев из sitemap.xml." : "")))

        guard total > 0 else {
            record(10, CheckItem("Доступность сайта", status: .failed,
                detail: "Не удалось обойти ни одной HTML-страницы.",
                recommendation: "Проверьте доступность сайта и внутренние ссылки."))
            return CategoryResult(category: .crawl, score: s.score, checks: checks)
        }

        // Битые ссылки/страницы
        if broken.isEmpty {
            record(20, CheckItem("Битые страницы (4xx/5xx)", status: .passed,
                detail: "Недоступных страниц не обнаружено."))
        } else {
            let examples = broken.prefix(5).map { scan -> String in
                let code = scan.status == -1 ? "ошибка сети" : String(scan.status)
                return "\(code) — \(scan.url)"
            }
            record(20, CheckItem("Битые страницы (4xx/5xx)", status: .failed,
                detail: "Недоступных страниц: \(broken.count).\n" + examples.joined(separator: "\n"),
                recommendation: "Исправьте или удалите ссылки на недоступные страницы."))
        }

        // Title на всех страницах
        let noTitle = htmlPages.filter { ($0.title?.isEmpty ?? true) }.count
        record(14, ratioCheck("Title на страницах", bad: noTitle, total: total,
            okDetail: "У всех \(total) страниц есть Title.",
            badDetail: "Без Title: \(noTitle) из \(total).",
            rec: "Задайте уникальный Title каждой странице."))

        // Уникальность Title (дубликаты)
        let titles = htmlPages.compactMap { $0.title?.isEmpty == false ? $0.title! : nil }
        var counts: [String: Int] = [:]
        for t in titles { counts[t, default: 0] += 1 }
        let dupGroups = counts.filter { $0.value > 1 }
        let dupPages = dupGroups.values.reduce(0, +)
        if dupGroups.isEmpty {
            record(12, CheckItem("Уникальность Title", status: .passed, detail: "Дубликатов Title нет."))
        } else {
            record(12, CheckItem("Уникальность Title", status: dupPages > total / 3 ? .failed : .warning,
                detail: "Повторяющихся Title: \(dupGroups.count) (затрагивают \(dupPages) страниц).",
                recommendation: "Сделайте Title уникальными — дубликаты конкурируют между собой."),
                credit: 0.3)
        }

        // Meta description
        let noDesc = htmlPages.filter { !$0.hasDescription }.count
        record(12, ratioCheck("Meta Description на страницах", bad: noDesc, total: total,
            okDetail: "Описание есть у всех \(total) страниц.",
            badDetail: "Без описания: \(noDesc) из \(total).",
            rec: "Добавьте мета-описание каждой странице."))

        // H1
        let noH1 = htmlPages.filter { $0.h1Count == 0 }.count
        let multiH1 = htmlPages.filter { $0.h1Count > 1 }.count
        if noH1 == 0 && multiH1 == 0 {
            record(10, CheckItem("Заголовки H1 по сайту", status: .passed, detail: "У всех страниц ровно один H1."))
        } else {
            record(10, CheckItem("Заголовки H1 по сайту",
                status: (noH1 + multiH1) > total / 3 ? .failed : .warning,
                detail: "Без H1: \(noH1), с несколькими H1: \(multiH1) (из \(total)).",
                recommendation: "На каждой странице должен быть один H1."), credit: 0.4)
        }

        // Тонкие страницы
        let thin = htmlPages.filter { $0.wordCount < 300 }.count
        record(8, ratioCheck("Тонкие страницы (<300 слов)", bad: thin, total: total,
            okDetail: "Тонких страниц нет.",
            badDetail: "Тонких страниц: \(thin) из \(total).",
            rec: "Наполните тонкие страницы содержательным текстом."))

        // HTTPS на всех страницах
        let httpPages = htmlPages.filter { !$0.isHTTPS }.count
        record(12, httpPages == 0
            ? CheckItem("HTTPS на всех страницах", status: .passed, detail: "Все страницы по HTTPS.")
            : CheckItem("HTTPS на всех страницах", status: .failed,
                detail: "Страниц по HTTP: \(httpPages) из \(total).",
                recommendation: "Переведите все страницы на HTTPS, уберите смешанный контент."))

        // noindex по сайту
        let noindex = htmlPages.filter { $0.noindex }.count
        record(6, noindex == 0
            ? CheckItem("Индексация страниц", status: .passed, detail: "Закрытых от индексации страниц нет.")
            : CheckItem("Индексация страниц", status: .warning,
                detail: "Закрыто от индексации: \(noindex) из \(total).",
                recommendation: "Проверьте, что важные страницы не закрыты noindex."), credit: 0.4)

        // Средняя скорость по сайту
        let avg = htmlPages.map { $0.responseMs }.reduce(0, +) / max(1, total)
        if avg < 800 {
            record(6, CheckItem("Средняя скорость по сайту", status: .passed, detail: "~\(avg) мс на страницу."))
        } else {
            record(6, CheckItem("Средняя скорость по сайту", status: .warning, detail: "~\(avg) мс на страницу.",
                recommendation: "Оптимизируйте медленные страницы."), credit: 0.4)
        }

        return CategoryResult(category: .crawl, score: s.score, checks: checks)
    }

    /// Помощник: проверка по доле «плохих» страниц.
    private func ratioCheck(_ title: String, bad: Int, total: Int,
                            okDetail: String, badDetail: String, rec: String) -> CheckItem {
        if bad == 0 { return CheckItem(title, status: .passed, detail: okDetail) }
        let status: CheckStatus = Double(bad) / Double(total) < 0.3 ? .warning : .failed
        return CheckItem(title, status: status, detail: badDetail, recommendation: rec)
    }

    // MARK: - Производительность

    private func analyzePerformance(doc: HTMLDocument, page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Время ответа
        let ms = page.responseTimeMs
        if ms < 600 {
            record(20, CheckItem("Время ответа сервера", status: .passed, detail: "\(ms) мс — быстро."))
        } else if ms < 1500 {
            record(20, CheckItem("Время ответа сервера", status: .warning, detail: "\(ms) мс.",
                recommendation: "Стремитесь к ответу < 600 мс."), credit: 0.5)
        } else {
            record(20, CheckItem("Время ответа сервера", status: .failed, detail: "\(ms) мс — медленно.",
                recommendation: "Оптимизируйте сервер, кэш и БД."))
        }

        // Размер HTML
        let kb = page.byteCount / 1024
        if kb < 100 {
            record(14, CheckItem("Размер HTML", status: .passed, detail: "\(kb) КБ."))
        } else if kb < 300 {
            record(14, CheckItem("Размер HTML", status: .warning, detail: "\(kb) КБ.",
                recommendation: "Держите HTML до 100 КБ."), credit: 0.5)
        } else {
            record(14, CheckItem("Размер HTML", status: .failed, detail: "\(kb) КБ — велик.",
                recommendation: "Сократите разметку и вынесите inline-данные."))
        }

        // Сжатие
        let enc = page.headers["content-encoding"]?.lowercased() ?? ""
        record(12, (enc.contains("gzip") || enc.contains("br") || enc.contains("deflate"))
            ? CheckItem("Сжатие ответа", status: .passed, detail: "Включено: \(enc).")
            : CheckItem("Сжатие ответа", status: .failed, detail: "Сжатие (gzip/brotli) не обнаружено.",
                recommendation: "Включите gzip или brotli на сервере."))

        // JS
        let scripts = doc.scriptTags.count
        if scripts <= 10 {
            record(9, CheckItem("Внешние JS-файлы", status: .passed, detail: "Скриптов: \(scripts)."))
        } else if scripts <= 25 {
            record(9, CheckItem("Внешние JS-файлы", status: .warning, detail: "Скриптов: \(scripts).",
                recommendation: "Объединяйте и откладывайте загрузку скриптов."), credit: 0.4)
        } else {
            record(9, CheckItem("Внешние JS-файлы", status: .failed, detail: "Скриптов: \(scripts) — слишком много.",
                recommendation: "Сократите число подключаемых скриптов."))
        }

        // CSS
        let css = doc.stylesheetLinks.count
        if css <= 6 {
            record(7, CheckItem("Внешние CSS-файлы", status: .passed, detail: "Таблиц стилей: \(css)."))
        } else if css <= 15 {
            record(7, CheckItem("Внешние CSS-файлы", status: .warning, detail: "Таблиц стилей: \(css).",
                recommendation: "Объединяйте CSS-файлы."), credit: 0.4)
        } else {
            record(7, CheckItem("Внешние CSS-файлы", status: .failed, detail: "Таблиц стилей: \(css) — слишком много.",
                recommendation: "Сократите число подключаемых стилей."))
        }

        // Инлайн-стили
        let inline = doc.inlineStyleCount
        if inline <= 5 {
            record(6, CheckItem("Инлайн-стили", status: .passed, detail: "Инлайн-стилей: \(inline)."))
        } else if inline <= 30 {
            record(6, CheckItem("Инлайн-стили", status: .warning, detail: "Инлайн-стилей: \(inline).",
                recommendation: "Выносите стили в CSS-файлы."), credit: 0.4)
        } else {
            record(6, CheckItem("Инлайн-стили", status: .failed, detail: "Инлайн-стилей: \(inline) — слишком много."))
        }

        // Кэширование
        record(8, (page.headers["cache-control"]?.isEmpty == false)
            ? CheckItem("Кэширование", status: .passed, detail: "Cache-Control: \(page.headers["cache-control"]!)")
            : CheckItem("Кэширование", status: .failed, detail: "Заголовок Cache-Control не задан.",
                recommendation: "Настройте кэширование статических ресурсов."))

        // DOCTYPE
        record(4, doc.hasDoctype
            ? CheckItem("DOCTYPE", status: .passed, detail: "Объявление <!DOCTYPE> присутствует.")
            : CheckItem("DOCTYPE", status: .failed, detail: "DOCTYPE не объявлен.",
                recommendation: "Добавьте <!DOCTYPE html> в начало документа."))

        return CategoryResult(category: .performance, score: s.score, checks: checks)
    }

    // MARK: - Удобство использования

    private func analyzeUsability(doc: HTMLDocument, page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Адаптивность (viewport)
        if let vp = doc.metaViewport {
            record(25, CheckItem("Мобильная адаптация (viewport)", status: .passed, detail: "viewport: \(vp)"))
        } else {
            record(25, CheckItem("Мобильная адаптация (viewport)", status: .failed, detail: "Мета-тег viewport отсутствует.",
                recommendation: "Добавьте <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">."))
        }

        // Favicon
        record(12, doc.hasFavicon
            ? CheckItem("Иконка сайта (favicon)", status: .passed, detail: "Favicon подключён.")
            : CheckItem("Иконка сайта (favicon)", status: .failed, detail: "Favicon не найден.",
                recommendation: "Добавьте favicon."))

        // Apple touch icon
        record(8, doc.hasAppleTouchIcon
            ? CheckItem("Иконка для iOS", status: .passed, detail: "apple-touch-icon подключён.")
            : CheckItem("Иконка для iOS", status: .warning, detail: "apple-touch-icon не найден.",
                recommendation: "Добавьте apple-touch-icon."), credit: 0.3)

        // Кодировка
        record(12, doc.charset != nil
            ? CheckItem("Кодировка символов", status: .passed, detail: "charset: \(doc.charset!)")
            : CheckItem("Кодировка символов", status: .failed, detail: "Кодировка явно не указана.",
                recommendation: "Укажите <meta charset=\"utf-8\">."))

        // Заголовок для пользователя
        record(10, (doc.title?.isEmpty == false)
            ? CheckItem("Понятный заголовок", status: .passed, detail: "Заголовок присутствует.")
            : CheckItem("Понятный заголовок", status: .failed, detail: "Заголовок страницы отсутствует.",
                recommendation: "Добавьте информативный <title>."))

        // Читаемость
        let words = doc.wordCount
        if words > 150 {
            record(13, CheckItem("Читаемость контента", status: .passed, detail: "Контент доступен (~\(words) слов)."))
        } else {
            record(13, CheckItem("Читаемость контента", status: .warning, detail: "Текстового контента мало (~\(words) слов).",
                recommendation: "Добавьте больше полезного текста."), credit: 0.4)
        }

        return CategoryResult(category: .usability, score: s.score, checks: checks)
    }

    // MARK: - Безопасность

    private func analyzeSecurity(page: FetchedPage) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // HTTPS
        record(30, (page.finalURL.scheme?.lowercased() == "https")
            ? CheckItem("Шифрование HTTPS (SSL)", status: .passed, detail: "Сайт работает по HTTPS.")
            : CheckItem("Шифрование HTTPS (SSL)", status: .failed, detail: "Сайт работает по незащищённому HTTP.",
                recommendation: "Установите SSL-сертификат и переведите сайт на HTTPS."))

        // HSTS
        record(14, page.headers["strict-transport-security"] != nil
            ? CheckItem("HSTS", status: .passed, detail: "Strict-Transport-Security присутствует.")
            : CheckItem("HSTS", status: .warning, detail: "Заголовок HSTS не задан.",
                recommendation: "Добавьте Strict-Transport-Security."), credit: 0.3)

        // X-Content-Type-Options
        record(12, (page.headers["x-content-type-options"]?.lowercased().contains("nosniff") == true)
            ? CheckItem("X-Content-Type-Options", status: .passed, detail: "nosniff установлен.")
            : CheckItem("X-Content-Type-Options", status: .warning, detail: "Заголовок не задан.",
                recommendation: "Добавьте X-Content-Type-Options: nosniff."), credit: 0.3)

        // Защита от кликджекинга
        let frameGuard = page.headers["x-frame-options"] != nil
            || (page.headers["content-security-policy"]?.lowercased().contains("frame-ancestors") ?? false)
        record(12, frameGuard
            ? CheckItem("Защита от кликджекинга", status: .passed, detail: "X-Frame-Options или CSP frame-ancestors заданы.")
            : CheckItem("Защита от кликджекинга", status: .warning, detail: "X-Frame-Options не задан.",
                recommendation: "Добавьте X-Frame-Options: SAMEORIGIN."), credit: 0.3)

        // CSP
        record(16, page.headers["content-security-policy"] != nil
            ? CheckItem("Content-Security-Policy", status: .passed, detail: "CSP задана.")
            : CheckItem("Content-Security-Policy", status: .warning, detail: "CSP не настроена.",
                recommendation: "Настройте Content-Security-Policy против XSS."), credit: 0.3)

        // Раскрытие версии сервера
        if let server = page.headers["server"], server.rangeOfCharacter(from: .decimalDigits) != nil {
            record(10, CheckItem("Раскрытие версии сервера", status: .warning, detail: "Server: \(server)",
                recommendation: "Скройте версию ПО сервера в заголовке Server."), credit: 0.3)
        } else {
            record(10, CheckItem("Раскрытие версии сервера", status: .passed, detail: "Версия серверного ПО не раскрывается."))
        }

        return CategoryResult(category: .security, score: s.score, checks: checks)
    }

    // MARK: - Социальные сети

    private func analyzeSocial(doc: HTMLDocument) -> CategoryResult {
        var checks: [CheckItem] = []
        var s = Scorer()
        func record(_ w: Double, _ item: CheckItem, credit: Double = 0.33) {
            checks.append(item); s.add(w, item.status, credit: credit)
        }

        // Open Graph
        if doc.hasOpenGraph {
            let title = doc.metaProperty("og:title") ?? "—"
            record(35, CheckItem("Open Graph", status: .passed, detail: "Найдено. og:title: «\(title)»"))
        } else {
            record(35, CheckItem("Open Graph", status: .failed, detail: "Разметка Open Graph отсутствует.",
                recommendation: "Добавьте og:title, og:description, og:image."))
        }

        // Twitter Card
        record(20, doc.hasTwitterCard
            ? CheckItem("Twitter Card", status: .passed, detail: "Разметка Twitter Card найдена.")
            : CheckItem("Twitter Card", status: .warning, detail: "Разметка Twitter Card отсутствует.",
                recommendation: "Добавьте twitter:card, twitter:title, twitter:image."), credit: 0.3)

        // Ссылки на соцсети
        let present = doc.socialLinks.filter { $0.value }.map { $0.key }.sorted()
        if !present.isEmpty {
            let credit = min(1.0, 0.4 + Double(present.count) * 0.2)
            record(25, CheckItem("Присутствие в соцсетях", status: present.count >= 3 ? .passed : .warning,
                detail: "Найдены ссылки: \(present.joined(separator: ", ")).",
                recommendation: present.count >= 3 ? nil : "Добавьте больше ссылок на ваши профили."), credit: credit)
        } else {
            record(25, CheckItem("Присутствие в соцсетях", status: .failed, detail: "Ссылки на соцсети не найдены.",
                recommendation: "Добавьте ссылки на профили в соцсетях."))
        }

        return CategoryResult(category: .social, score: s.score, checks: checks)
    }

    // MARK: - Вспомогательное

    private static func weightedScore(_ categories: [CategoryResult]) -> Int {
        var sum = 0.0
        for c in categories { sum += Double(c.score) * c.category.weight }
        return Int(sum.rounded())
    }

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
