import SwiftUI

/// Содержимое модального окна обновления (показывается из ContentView).
struct UpdatePromptView: View {
    @ObservedObject private var updater = UpdateService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            switch updater.phase {
            case .checking:
                progress("Проверяем обновления…")
            case .downloading:
                progress("Скачиваем обновление…",
                         value: updater.totalBytes > 0 ? updater.downloadProgress : nil,
                         detail: downloadDetail)
            case .installing:
                progress("Устанавливаем обновление…")
            case .available:
                available
            case .upToDate:
                info(icon: "checkmark.circle.fill", color: .green,
                     title: "Установлена последняя версия",
                     text: updater.message ?? "Обновлений не найдено.")
            case .failed:
                info(icon: "exclamationmark.triangle.fill", color: .orange,
                     title: "Не удалось проверить обновления",
                     text: updater.message ?? "Произошла ошибка.")
            case .idle:
                EmptyView()
            }
        }
        .padding(26)
        .frame(width: 440)
    }

    private var available: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Доступна новая версия")
                .font(.system(size: 18, weight: .bold))
            Text("Текущая: \(updater.currentVersion)  →  Новая: \(updater.latestVersion ?? "—")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let notes = updater.latest?.body, !notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
            }

            HStack(spacing: 10) {
                Button("Позже") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Открыть на GitHub") { updater.openReleasePage() }
                Spacer()
                Button("Обновить") {
                    Task { await updater.install() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func progress(_ title: String, value: Double? = nil, detail: String? = nil) -> some View {
        VStack(spacing: 14) {
            if let value {
                ProgressView(value: value).progressViewStyle(.linear)
            } else {
                ProgressView().scaleEffect(1.2)
            }
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let value {
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Приложение перезапустится автоматически после установки.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.3), value: value)
    }

    private var downloadDetail: String? { updateDownloadDetail(updater) }

    private func info(icon: String, color: Color, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(color)
            Text(title).font(.system(size: 17, weight: .bold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Размер загруженного/общего и оценка оставшегося времени, например
/// «4,2 из 9,8 МБ · осталось ~6 с». Общая для модального окна и настроек.
@MainActor
func updateDownloadDetail(_ updater: UpdateService) -> String? {
    guard updater.totalBytes > 0 else { return nil }
    let bf = ByteCountFormatter()
    bf.countStyle = .file
    let sizePart = "\(bf.string(fromByteCount: updater.downloadedBytes)) из \(bf.string(fromByteCount: updater.totalBytes))"
    guard let eta = updater.estimatedSecondsRemaining, eta.isFinite, eta > 0 else { return sizePart }
    return "\(sizePart) · осталось ~\(formatETA(eta))"
}

func formatETA(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(1, s)) с" }
    let minutes = s / 60, secs = s % 60
    return secs == 0 ? "\(minutes) мин" : "\(minutes) мин \(secs) с"
}

/// Окно настроек (доступно через меню «SEO-Анализатор → Настройки…», ⌘,).
struct SettingsView: View {
    @AppStorage("autoCheckUpdates") private var autoCheck = true
    @AppStorage("crawlLimit") private var crawlLimit = 50
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        Form {
            Section("Глубина сканирования") {
                Stepper(value: $crawlLimit, in: 5...300, step: 5) {
                    LabeledContent("Максимум страниц для обхода", value: "\(crawlLimit)")
                }
                Text("Анализатор обходит сайт по внутренним ссылкам и sitemap. Чем больше страниц — тем точнее и честнее картина по всему сайту, но дольше анализ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Обновления") {
                Toggle("Проверять обновления автоматически при запуске", isOn: $autoCheck)

                LabeledContent("Текущая версия", value: updater.currentVersion)
                if let lv = updater.latestVersion {
                    LabeledContent("Последняя на GitHub", value: lv)
                }

                HStack {
                    Button {
                        Task { await updater.check(silent: false) }
                    } label: {
                        if updater.phase == .checking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Проверяем…")
                            }
                        } else {
                            Text("Проверить сейчас")
                        }
                    }
                    .disabled(updater.phase == .checking)

                    if updater.phase == .available {
                        Button("Обновить") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if updater.phase == .downloading || updater.phase == .installing {
                    VStack(alignment: .leading, spacing: 4) {
                        if updater.totalBytes > 0 {
                            ProgressView(value: updater.downloadProgress).progressViewStyle(.linear)
                            HStack {
                                Text(updater.phase == .downloading ? "Скачивание…" : "Установка…")
                                Spacer()
                                Text("\(Int((updater.downloadProgress * 100).rounded()))%")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(updater.phase == .downloading ? "Скачивание…" : "Установка…")
                                    .font(.caption)
                            }
                        }
                        if let detail = updateDownloadDetail(updater) {
                            Text(detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let m = updater.message {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("О приложении") {
                Text("SEO-Анализатор — комплексный SEO-аудит сайта с экспортом в PDF и Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Репозиторий на GitHub",
                     destination: URL(string: "https://github.com/\(UpdateService.repo)")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 440)
    }
}
