import SwiftUI
import AppKit

/// Делает системный title bar прозрачным и скрывает его текст, чтобы кастомная
/// шапка приложения (иконка, поле ввода, кнопки) сливалась с традиционной
/// тёмной/контрастной полосой вокруг traffic lights, а не выглядела отдельным слоем.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
