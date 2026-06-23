import Foundation

/// Скачивает файл по URL с реальным побайтовым прогрессом — нужен для процентов
/// и оценки оставшегося времени при установке обновления (вместо фиксированных
/// контрольных точек прогресса).
final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = (
        _ fraction: Double, _ written: Int64, _ total: Int64, _ elapsed: TimeInterval
    ) -> Void

    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: ProgressHandler
    private let startDate = Date()
    private var session: URLSession?

    init(onProgress: @escaping ProgressHandler) {
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                     didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                     totalBytesExpectedToWrite: Int64) {
        let elapsed = Date().timeIntervalSince(startDate)
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite, elapsed)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                     didFinishDownloadingTo location: URL) {
        // location удаляется системой сразу после возврата делегата — переносим синхронно.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
