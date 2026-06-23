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

/// Категории анализа.
/// SEO/Производительность/Удобство/Соцсети/Безопасность — классический аудит (как SEOptimer),
/// AEO и GEO — оптимизация под ответные и генеративные (AI) поисковые системы.
enum SEOCategory: String, CaseIterable, Codable, Identifiable {
    case seo         = "SEO"
    case aeo         = "AEO"
    case geo         = "GEO"
    case performance = "Производительность"
    case usability   = "Удобство"
    case security    = "Безопасность"
    case social      = "Соцсети"

    var id: String { rawValue }

    /// Подробное название для отчётов.
    var fullName: String {
        switch self {
        case .seo:         return "SEO — классическая поисковая оптимизация"
        case .aeo:         return "AEO — оптимизация под ответные системы (сниппеты, голосовой поиск)"
        case .geo:         return "GEO — оптимизация под генеративные ИИ-поисковики"
        case .performance: return "Производительность"
        case .usability:   return "Удобство использования"
        case .security:    return "Безопасность"
        case .social:      return "Социальные сети"
        }
    }

    /// Вес категории в итоговом балле (в сумме 1.0).
    var weight: Double {
        switch self {
        case .seo:         return 0.30
        case .aeo:         return 0.14
        case .geo:         return 0.14
        case .performance: return 0.15
        case .usability:   return 0.10
        case .security:    return 0.10
        case .social:      return 0.07
        }
    }

    var iconName: String {
        switch self {
        case .seo:         return "magnifyingglass"
        case .aeo:         return "questionmark.bubble"
        case .geo:         return "sparkles"
        case .performance: return "speedometer"
        case .usability:   return "hand.tap"
        case .security:    return "lock.shield"
        case .social:      return "person.2"
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
