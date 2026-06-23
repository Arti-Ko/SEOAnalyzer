import Foundation

/// Лёгкий разбор HTML на основе регулярных выражений.
/// Не претендует на полноценный DOM, но достаточен для SEO-анализа:
/// извлекает теги, атрибуты и текстовое содержимое.
struct HTMLDocument {

    let raw: String
    private let lowercased: String

    init(html: String) {
        self.raw = html
        self.lowercased = html.lowercased()
    }

    // MARK: - Базовые помощники

    /// Все совпадения по регулярному выражению (без учёта регистра, dotMatchesLineSeparators).
    func matches(_ pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.matches(in: raw, options: [], range: range)
    }

    /// Возвращает строку из группы захвата.
    func group(_ result: NSTextCheckingResult, _ index: Int) -> String? {
        guard index < result.numberOfRanges,
              let range = Range(result.range(at: index), in: raw) else { return nil }
        return String(raw[range])
    }

    /// Первое значение группы захвата по шаблону.
    func firstGroup(_ pattern: String, group idx: Int = 1) -> String? {
        guard let m = matches(pattern).first else { return nil }
        return group(m, idx)
    }

    // MARK: - Извлечение тегов

    var title: String? {
        firstGroup("<title[^>]*>(.*?)</title>")?.decodedHTML.trimmed
    }

    /// Значение meta по имени (name=...).
    func metaName(_ name: String) -> String? {
        // Порядок атрибутов может быть любым — пробуем оба варианта.
        let patterns = [
            "<meta[^>]*name=[\"']\(name)[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "<meta[^>]*content=[\"'](.*?)[\"'][^>]*name=[\"']\(name)[\"'][^>]*>"
        ]
        for p in patterns {
            if let v = firstGroup(p) { return v.decodedHTML.trimmed }
        }
        return nil
    }

    /// Значение meta по property (Open Graph и т.п.).
    func metaProperty(_ property: String) -> String? {
        let patterns = [
            "<meta[^>]*property=[\"']\(property)[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
            "<meta[^>]*content=[\"'](.*?)[\"'][^>]*property=[\"']\(property)[\"'][^>]*>"
        ]
        for p in patterns {
            if let v = firstGroup(p) { return v.decodedHTML.trimmed }
        }
        return nil
    }

    var metaDescription: String? { metaName("description") }
    var metaKeywords: String?    { metaName("keywords") }
    var metaRobots: String?      { metaName("robots") }
    var metaViewport: String?    { metaName("viewport") }
    var charset: String? {
        firstGroup("<meta[^>]*charset=[\"']?([a-z0-9\\-]+)")
    }

    /// Тексты заголовков уровня (h1…h6).
    func headings(level: Int) -> [String] {
        matches("<h\(level)[^>]*>(.*?)</h\(level)>")
            .compactMap { group($0, 1)?.strippedTags.decodedHTML.trimmed }
            .filter { !$0.isEmpty }
    }

    /// Все теги <img ...> целиком.
    var imageTags: [String] {
        matches("<img[^>]*>").compactMap { group($0, 0) }
    }

    /// Изображения без атрибута alt (или с пустым alt).
    var imagesWithoutAlt: [String] {
        imageTags.filter { tag in
            let lower = tag.lowercased()
            guard lower.contains("alt=") else { return true }
            // alt присутствует — проверим, не пустой ли
            if let r = lower.range(of: "alt=[\"'](.*?)[\"']", options: .regularExpression) {
                let value = String(lower[r])
                    .replacingOccurrences(of: "alt=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return value.isEmpty
            }
            return true
        }
    }

    var hasViewport: Bool { metaViewport != nil }

    var canonical: String? {
        firstGroup("<link[^>]*rel=[\"']canonical[\"'][^>]*href=[\"'](.*?)[\"']")
            ?? firstGroup("<link[^>]*href=[\"'](.*?)[\"'][^>]*rel=[\"']canonical[\"']")
    }

    var hasFavicon: Bool {
        lowercased.contains("rel=\"icon\"")
            || lowercased.contains("rel='icon'")
            || lowercased.contains("rel=\"shortcut icon\"")
            || lowercased.contains("apple-touch-icon")
    }

    var hasAppleTouchIcon: Bool {
        lowercased.contains("apple-touch-icon")
    }

    var langAttribute: String? {
        firstGroup("<html[^>]*lang=[\"'](.*?)[\"']")
    }

    var hasDoctype: Bool {
        lowercased.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!doctype")
    }

    // MARK: - Ресурсы (для оценки производительности)

    var scriptTags: [String]     { matches("<script[^>]*src=[\"'].*?[\"'][^>]*>").compactMap { group($0, 0) } }
    var stylesheetLinks: [String] { matches("<link[^>]*rel=[\"']stylesheet[\"'][^>]*>").compactMap { group($0, 0) } }
    var inlineStyleCount: Int    { matches("style=[\"']").count }
    var inlineScriptCount: Int   { matches("<script(?![^>]*src)[^>]*>").count }

    // MARK: - Социальные сети

    var hasOpenGraph: Bool {
        metaProperty("og:title") != nil
            || metaProperty("og:description") != nil
            || metaProperty("og:image") != nil
    }

    var hasTwitterCard: Bool {
        metaName("twitter:card") != nil || metaName("twitter:title") != nil
    }

    /// Поиск ссылок на популярные соцсети.
    var socialLinks: [String: Bool] {
        let networks: [String: [String]] = [
            "Facebook":  ["facebook.com"],
            "Twitter/X": ["twitter.com", "x.com"],
            "Instagram": ["instagram.com"],
            "LinkedIn":  ["linkedin.com"],
            "YouTube":   ["youtube.com", "youtu.be"],
            "VK":        ["vk.com"],
            "Telegram":  ["t.me", "telegram.me"]
        ]
        var found: [String: Bool] = [:]
        for (name, domains) in networks {
            found[name] = domains.contains { lowercased.contains($0) }
        }
        return found
    }

    // MARK: - Контент

    /// Грубый подсчёт слов в видимом тексте.
    var wordCount: Int {
        let noScripts = raw.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: " ",
            options: [.regularExpression, .caseInsensitive])
        let noStyles = noScripts.replacingOccurrences(
            of: "<style[^>]*>.*?</style>",
            with: " ",
            options: [.regularExpression, .caseInsensitive])
        let text = noStyles.strippedTags.decodedHTML
        let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        return words.filter { $0.count > 1 }.count
    }

    /// Частотность слов для оценки консистентности ключевых слов.
    func keywordFrequencies(top: Int = 10) -> [(word: String, count: Int)] {
        let noScripts = raw.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: " ", options: [.regularExpression, .caseInsensitive])
        let text = noScripts.strippedTags.decodedHTML.lowercased()
        let tokens = text.split { !$0.isLetter && $0 != "-" }.map(String.init)
        var counts: [String: Int] = [:]
        for token in tokens where token.count >= 4 && !Self.stopWords.contains(token) {
            counts[token, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(top)
            .map { (word: $0.key, count: $0.value) }
    }

    private static let stopWords: Set<String> = [
        "this", "that", "with", "from", "your", "have", "will", "they", "what",
        "когда", "после", "очень", "также", "более", "если", "этом", "этого",
        "который", "которые", "может", "быть", "была", "было", "есть", "https", "http", "www"
    ]
}

// MARK: - Сигналы AEO / GEO (ответные и генеративные системы)

extension HTMLDocument {

    /// Содержимое блоков JSON-LD (структурированные данные Schema.org).
    var jsonLDBlocks: [String] {
        matches("<script[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>")
            .compactMap { group($0, 1)?.trimmed }
            .filter { !$0.isEmpty }
    }

    var hasJSONLD: Bool { !jsonLDBlocks.isEmpty }
    var hasMicrodata: Bool { lowercased.contains("itemtype=") }
    var hasStructuredData: Bool { hasJSONLD || hasMicrodata }

    private var jsonLDText: String { jsonLDBlocks.joined(separator: " ").lowercased() }

    /// Есть ли в разметке указанный тип Schema.org (JSON-LD или микроразметка).
    func hasSchemaType(_ type: String) -> Bool {
        let t = type.lowercased()
        if jsonLDText.contains("\"\(t)\"") { return true }
        if lowercased.contains("itemtype=\"https://schema.org/\(t)\"") { return true }
        if lowercased.contains("itemtype=\"http://schema.org/\(t)\"") { return true }
        return false
    }

    /// Семантические теги HTML5, присутствующие на странице.
    var semanticTags: [String] {
        ["article", "section", "main", "nav", "header", "footer", "aside", "figure", "time"]
            .filter { lowercased.contains("<\($0)") }
    }

    /// Заголовки H2/H3, сформулированные как вопросы (важно для AEO).
    func questionHeadings() -> [String] {
        (headings(level: 2) + headings(level: 3)).filter { isQuestion($0) }
    }

    private func isQuestion(_ s: String) -> Bool {
        if s.contains("?") { return true }
        let lower = s.lowercased()
        let qwords = ["как ", "что ", "почему", "зачем", "где ", "когда", "какой", "какая",
                      "какие", "сколько", "можно ли", "нужно ли", "чем ",
                      "what ", "how ", "why ", "when ", "where ", "who ", "which ",
                      "can ", "does ", "is ", "are "]
        return qwords.contains { lower.hasPrefix($0) }
    }

    var listCount: Int  { matches("<(ul|ol)[ >]").count }
    var tableCount: Int { matches("<table[ >]").count }

    /// Все значения href у ссылок (без якорей #...).
    var anchorHrefs: [String] {
        matches("<a[^>]*href=[\"']([^\"'#]+)[\"']")
            .compactMap { group($0, 1) }
            .filter { !$0.hasPrefix("javascript:") && !$0.hasPrefix("mailto:") && !$0.hasPrefix("tel:") }
    }

    /// Количество внешних ссылок (на другие домены) — сигнал цитирования источников.
    func externalLinkCount(host: String?) -> Int {
        guard let host = host?.lowercased() else { return 0 }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let hrefs = matches("<a[^>]*href=[\"'](https?://[^\"']+)[\"']").compactMap { group($0, 1)?.lowercased() }
        return hrefs.filter { href in
            guard let h = URL(string: href)?.host?.lowercased() else { return false }
            let hb = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            return hb != bare
        }.count
    }

    /// Сигналы фактуры: проценты и числовые данные (генеративные системы любят цифры/статистику).
    var percentSignals: Int { matches("[0-9]+\\s*%").count }
    var numberSignals: Int  { matches("[0-9][0-9 .,]{2,}[0-9]").count }

    /// Признаки авторства / экспертности (E-E-A-T).
    var hasAuthorSignal: Bool {
        metaName("author") != nil
            || lowercased.contains("rel=\"author\"")
            || lowercased.contains("itemprop=\"author\"")
            || jsonLDText.contains("\"author\"")
            || hasSchemaType("Person")
    }

    /// Признаки даты публикации/обновления.
    var hasDateSignal: Bool {
        metaProperty("article:published_time") != nil
            || jsonLDText.contains("datepublished") || jsonLDText.contains("datemodified")
            || lowercased.contains("itemprop=\"datepublished\"")
            || !matches("<time[^>]*datetime=").isEmpty
    }

    /// Привязка к авторитетным сущностям (sameAs, Wikipedia, Wikidata).
    var hasEntityAuthority: Bool {
        jsonLDText.contains("sameas")
            || lowercased.contains("wikipedia.org")
            || lowercased.contains("wikidata.org")
    }

    /// Разметка speakable (голосовые ассистенты).
    var hasSpeakable: Bool { jsonLDText.contains("speakable") }
}

// MARK: - Разбор robots.txt

/// Упрощённый разбор robots.txt для проверки доступа поисковых и ИИ-роботов.
struct RobotsTxt {
    /// user-agent (в нижнем регистре) -> список Disallow-путей.
    private var groups: [String: [String]] = [:]
    let isEmpty: Bool

    init(_ text: String) {
        isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var currentUAs: [String] = []
        var lastWasUA = false
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let noComment = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            let line = noComment.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if field == "user-agent" {
                if !lastWasUA { currentUAs = [] }      // началась новая группа
                currentUAs.append(value.lowercased())
                if groups[value.lowercased()] == nil { groups[value.lowercased()] = [] }
                lastWasUA = true
            } else if field == "disallow" {
                for ua in currentUAs { groups[ua, default: []].append(value) }
                lastWasUA = false
            } else {
                lastWasUA = false
            }
        }
    }

    /// Упоминается ли user-agent явно.
    func mentions(_ ua: String) -> Bool { groups[ua.lowercased()] != nil }

    /// Полностью ли заблокирован сайт для данного робота (Disallow: /).
    func blocksEntirely(_ ua: String) -> Bool {
        let dis = groups[ua.lowercased()] ?? []
        return dis.contains("/")
    }

    /// Заблокирован ли весь сайт для всех роботов (User-agent: * → Disallow: /).
    var blocksEveryone: Bool { (groups["*"] ?? []).contains("/") }
}

// MARK: - Строковые помощники

extension String {

    /// Удаляет HTML-теги.
    var strippedTags: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// Декодирует основные HTML-сущности.
    var decodedHTML: String {
        var s = self
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
            "&ndash;": "–", "&laquo;": "«", "&raquo;": "»", "&copy;": "©",
            "&hellip;": "…"
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
