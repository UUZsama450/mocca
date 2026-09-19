import CryptoKit
import Darwin
import Foundation

enum PastedTextAttachmentError: Error, LocalizedError, Equatable, Sendable {
    case invalidAttachment
    case missingFile
    case invalidUTF8
    case contentChanged
    case unableToSave
    case unableToRead

    var errorDescription: String? {
        switch self {
        case .invalidAttachment:
            ErrorLocalization.lookup("粘贴文本附件的信息不完整，请重新粘贴后再发送。")
        case .missingFile:
            ErrorLocalization.lookup("粘贴文本附件已丢失，无法发送其内容，请重新粘贴。")
        case .invalidUTF8:
            ErrorLocalization.lookup("粘贴文本附件的编码已损坏，无法完整读取，请重新粘贴。")
        case .contentChanged:
            ErrorLocalization.lookup("粘贴文本附件的内容已改变，无法确认内容完整，请重新粘贴。")
        case .unableToSave:
            ErrorLocalization.lookup("粘贴文本保存为 TXT 失败，原文尚未转换，请稍后重试。")
        case .unableToRead:
            ErrorLocalization.lookup("无法完整读取粘贴文本附件，请稍后重试或重新粘贴。")
        }
    }
}

/// File IO is independent from the composer. The caller publishes the returned
/// attachment only after checking that the original paste still owns its draft.
enum PastedTextAttachmentIO {
    struct SavedText: Sendable {
        let id: UUID
        let url: URL
        let byteCount: Int64
        let sha256: String
    }

    static func save(
        _ text: String,
        directory: @escaping @Sendable () throws -> URL
    ) async throws -> SavedText {
        let task = Task.detached(priority: .userInitiated) {
            var ownedDestination: URL?
            var succeeded = false
            defer {
                if !succeeded, let ownedDestination {
                    try? FileManager.default.removeItem(at: ownedDestination)
                }
            }
            do {
                try Task.checkCancellation()
                let root = try directory()
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let data = Data(text.utf8)
                try Task.checkCancellation()
                let destination = try reserveDestination(in: root)
                ownedDestination = destination.url
                // The destination was exclusively created by this operation.
                // Atomic replacement can never overwrite a previous attachment.
                try data.write(to: destination.url, options: .atomic)
                try Task.checkCancellation()
                let result = SavedText(
                    id: destination.id,
                    url: destination.url,
                    byteCount: Int64(data.count),
                    sha256: digest(data)
                )
                try Task.checkCancellation()
                succeeded = true
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PastedTextAttachmentError {
                throw error
            } catch {
                throw PastedTextAttachmentError.unableToSave
            }
        }
        return try await withTaskCancellationHandler {
            let saved = try await task.value
            if Task.isCancelled {
                // Cancellation may arrive just after the worker returns. This
                // path still owns only the new file, never a reused attachment.
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: saved.url)
                }.value
                throw CancellationError()
            }
            return saved
        } onCancel: {
            task.cancel()
        }
    }

    static func read(
        from url: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) async throws -> String {
        guard expectedByteCount >= 0,
              let byteCount = Int(exactly: expectedByteCount),
              expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              url.isFileURL else {
            throw PastedTextAttachmentError.invalidAttachment
        }
        let task = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PastedTextAttachmentError.missingFile
                }
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw PastedTextAttachmentError.invalidAttachment
                }
                guard values.fileSize == byteCount else {
                    throw PastedTextAttachmentError.contentChanged
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                while data.count < byteCount {
                    try Task.checkCancellation()
                    let size = min(1_048_576, byteCount - data.count)
                    guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                let extra = try handle.read(upToCount: 1)
                guard data.count == byteCount, extra?.isEmpty != false else {
                    throw PastedTextAttachmentError.contentChanged
                }
                // The UTF-8 decoder preserves BOMs, CRLF and all original scalar
                // sequences. Round-trip validation rejects replacement decoding.
                let text = String(decoding: data, as: UTF8.self)
                guard Data(text.utf8) == data else {
                    throw PastedTextAttachmentError.invalidUTF8
                }
                guard digest(data) == expectedSHA256 else {
                    throw PastedTextAttachmentError.contentChanged
                }
                try Task.checkCancellation()
                return text
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PastedTextAttachmentError {
                throw error
            } catch {
                throw PastedTextAttachmentError.unableToRead
            }
        }
        return try await withTaskCancellationHandler {
            let text = try await task.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            task.cancel()
        }
    }

    private static func reserveDestination(in directory: URL) throws -> (id: UUID, url: URL) {
        while true {
            try Task.checkCancellation()
            let id = UUID()
            let url = directory.appendingPathComponent("\(id.uuidString)_pasted.txt")
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if descriptor >= 0 {
                close(descriptor)
                return (id, url)
            }
            guard errno == EEXIST else { throw PastedTextAttachmentError.unableToSave }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
