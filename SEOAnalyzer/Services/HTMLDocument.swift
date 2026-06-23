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
