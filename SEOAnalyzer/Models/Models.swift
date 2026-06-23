import Foundation

// MARK: - Оценка (буквенная)

/// Буквенная оценка в стиле SEOptimer: от A+ до F.
enum Grade: String, Codable {
    case aPlus = "A+"
    case a  = "A"
    case b  = "B"
    case c  = "C"
    case d  = "D"
    case e  = "E"
    case f  = "F"

    /// Преобразует числовой балл (0–100) в буквенную оценку.
    static func from(score: Int) -> Grade {
        switch score {
        case 95...100: return .aPlus
        case 85..<95:  return .a
        case 70..<85:  return .b
        case 55..<70:  return .c
        case 40..<55:  return .d
        case 25..<40:  return .e
        default:       return .f
        }
    }

    /// Человекочитаемое описание оценки на русском.
    var summary: String {
        switch self {
        case .aPlus: return "Отлично"
        case .a:     return "Очень хорошо"
        case .b:     return "Хорошо"
        case .c:     return "Удовлетворительно"
        case .d:     return "Ниже среднего"
        case .e:     return "Плохо"
        case .f:     return "Критично"
        }
    }
}

// MARK: - Статус проверки

/// Результат отдельной проверки.
enum CheckStatus: String, Codable {
    case passed   // пройдено
    case warning  // есть замечания
    case failed   // не пройдено
    case info     // информационно

    var label: String {
        switch self {
        case .passed:  return "Пройдено"
        case .warning: return "Замечание"
        case .failed:  return "Ошибка"
        case .info:    return "Инфо"
        }
    }

    var symbol: String {
        switch self {
        case .passed:  return "✓"
        case .warning: return "!"
        case .failed:  return "✕"
        case .info:    return "i"
        }
    }
}

// MARK: - Категории анализа

/// Категории анализа — соответствуют разделам SEOptimer.
enum SEOCategory: String, CaseIterable, Codable, Identifiable {
    case seo         = "SEO"
    case performance = "Производительность"
    case usability   = "Удобство"
    case social      = "Соцсети"
    case security    = "Безопасность"

    var id: String { rawValue }

    /// Вес категории в итоговом балле (в сумме 100).
    var weight: Double {
        switch self {
        case .seo:         return 0.40
        case .performance: return 0.20
        case .usability:   return 0.15
        case .social:      return 0.10
        case .security:    return 0.15
        }
    }

    var iconName: String {
        switch self {
        case .seo:         return "magnifyingglass"
        case .performance: return "speedometer"
        case .usability:   return "hand.tap"
        case .social:      return "person.2"
        case .security:    return "lock.shield"
        }
    }
}

// MARK: - Элемент проверки

struct CheckItem: Identifiable, Codable {
    var id = UUID()
    let title: String
    let status: CheckStatus
    /// Что обнаружено фактически.
    let detail: String
    /// Рекомендация по исправлению (если требуется).
    let recommendation: String?

    init(_ title: String,
         status: CheckStatus,
         detail: String,
         recommendation: String? = nil) {
        self.title = title
        self.status = status
        self.detail = detail
        self.recommendation = recommendation
    }
}

// MARK: - Результат по категории

struct CategoryResult: Identifiable, Codable {
    var id = UUID()
    let category: SEOCategory
    var score: Int
    var checks: [CheckItem]

    var grade: Grade { Grade.from(score: score) }

    var passedCount: Int  { checks.filter { $0.status == .passed }.count }
    var warningCount: Int { checks.filter { $0.status == .warning }.count }
    var failedCount: Int  { checks.filter { $0.status == .failed }.count }
}

// MARK: - Полный отчёт

struct AnalysisReport: Identifiable, Codable {
    var id = UUID()
    let requestedURL: String
    let finalURL: String
    let date: Date

    var categories: [CategoryResult]
    var overallScore: Int
    var overallGrade: Grade { Grade.from(score: overallScore) }

    // Сырые данные, собранные при анализе (для отчёта/экспорта)
    var pageTitle: String?
    var metaDescription: String?
    var h1Texts: [String]
    var wordCount: Int
    var pageSizeBytes: Int
    var responseTimeMs: Int
    var serverHeader: String?
    var ipInfo: String?

    /// Удобный доступ к категории.
    func result(for category: SEOCategory) -> CategoryResult? {
        categories.first { $0.category == category }
    }
}
