import SwiftUI

struct ContentView: View {
    @StateObject private var vm = AnalysisViewModel()
    @ObservedObject private var updater = UpdateService.shared
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if vm.isAnalyzing {
                loadingView
            } else if let report = vm.report {
                ReportView(report: report,
                           onExportPDF: vm.exportPDF,
                           onExportMarkdown: vm.exportMarkdown)
            } else {
                welcomeView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowConfigurator())
        .sheet(isPresented: $updater.showSheet) {
            UpdatePromptView()
        }
        .task {
            // Тихая проверка обновлений при запуске (если включено в настройках).
            if autoCheckUpdates {
                await updater.check(silent: true)
            }
        }
    }

    // MARK: - Шапка с полем ввода

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)

            Text("SEO-Анализатор")
                .font(.system(size: 16, weight: .bold))

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("Введите адрес сайта, например example.com", text: $vm.urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { if vm.canAnalyze { vm.runAnalysis() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .softSurface(Capsule())
            .frame(maxWidth: 440)

            if vm.isAnalyzing {
                Button(role: .destructive, action: vm.cancelAnalysis) {
                    Text("Отменить")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button(action: vm.runAnalysis) {
                    Text("Анализировать")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canAnalyze)
                .keyboardShortcut(.return, modifiers: [])
            }

            Button {
                Task { await updater.check(silent: false) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
            }
            .help("Проверить обновления")
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Состояния

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            if vm.pagesScanned > 0 {
                ProgressView(value: Double(vm.pagesScanned), total: Double(max(vm.pagesTotal, vm.pagesScanned)))
                    .progressViewStyle(.linear)
                    .frame(width: 240)
            } else {
                ProgressView().controlSize(.large)
            }

            Text("Глубоко сканируем сайт…")
                .font(.system(size: 15, weight: .semibold))

            if vm.pagesScanned > 0 {
                Text(scanStatusDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
            }

            Text("Обходим страницы по внутренним ссылкам и sitemap,\nпроверяем SEO, AEO, GEO, скорость, безопасность и доступность.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: vm.pagesScanned)
    }

    /// Например: «32% · 16 из 50 страниц · осталось ~12 с».
    private var scanStatusDetail: String {
        let percent = vm.pagesTotal > 0
            ? Int((Double(vm.pagesScanned) / Double(vm.pagesTotal) * 100).rounded()) : 0
        var text = "\(percent)% · \(vm.pagesScanned) из \(vm.pagesTotal) страниц"
        if let eta = vm.scanEstimatedSecondsRemaining, eta.isFinite, eta > 0 {
            text += " · осталось ~\(formatETA(eta))"
        }
        return text
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint.opacity(0.8))
            Text("Комплексный SEO-аудит сайта")
                .font(.system(size: 20, weight: .bold))
            Text("Введите адрес сайта вверху и нажмите «Анализировать».\nПриложение проверит SEO, производительность, удобство, соцсети и безопасность,\nа затем позволит выгрузить отчёт в PDF или Markdown.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                    .padding(.top, 8)
            }

            categoriesLegend
                .padding(.top, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var categoriesLegend: some View {
        HStack(spacing: 10) {
            ForEach(SEOCategory.allCases) { cat in
                VStack(spacing: 7) {
                    Image(systemName: cat.iconName)
                        .font(.system(size: 19))
                        .foregroundStyle(.tint)
                    Text(cat.rawValue)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                }
                .frame(width: 82, height: 64)
                .softSurface(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
