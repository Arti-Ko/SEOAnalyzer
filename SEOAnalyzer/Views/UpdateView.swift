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
                progress("Скачиваем обновление…", value: updater.downloadProgress)
            case .installing:
                progress("Устанавливаем обновление…", value: updater.downloadProgress)
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

    private func progress(_ title: String, value: Double? = nil) -> some View {
        VStack(spacing: 14) {
            if let value {
                ProgressView(value: value).progressViewStyle(.linear)
            } else {
                ProgressView().scaleEffect(1.2)
            }
            Text(title).font(.system(size: 14, weight: .medium))
            Text("Приложение перезапустится автоматически после установки.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

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

/// Окно настроек (доступно через меню «SEO-Анализатор → Настройки…», ⌘,).
struct SettingsView: View {
    @AppStorage("autoCheckUpdates") private var autoCheck = true
    @ObservedObject private var updater = UpdateService.shared

    var body: some View {
        Form {
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
        .frame(width: 480, height: 320)
    }
}
