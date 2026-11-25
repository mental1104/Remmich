import CryptoKit
import Foundation
import Photos
import Synchronization

/// PhotoKit分块SHA1与取消状态；只保留哈希内部状态和计数，不累计完整图片/视频，也不写临时原片。
/// Photos的serial callback队列与Task取消可并行；所有完成权、request ID安装及字节更新都在Mutex内。
final nonisolated class LocalPhotoResourceSHA1Stream: @unchecked Sendable {
    /// false为唯一允许的网络选项；start在主Actor安装系统请求，返回可取消ID。
    typealias Start = @MainActor (Bool, @escaping @Sendable (Data) -> Void, @escaping @Sendable ((any Error)?) -> Void) -> PHAssetResourceDataRequestID
    typealias Cancel = @Sendable (PHAssetResourceDataRequestID) -> Void

    /// continuation只恢复一次；failureComplete使同步错误发生在ID返回前也能取消真实请求。
    private struct State {
        var hash = Insecure.SHA1()
        var count: Int64 = 0
        var continuation: CheckedContinuation<LocalPhotoByteDigest, any Error>?
        var requestID: PHAssetResourceDataRequestID?
        var cancelRequest: Cancel?
        var finished = false
        var cancelled = false
        var failureComplete = false
    }

    private let state = Mutex(State())

    /// start/cancel只替换系统传输边界，真实摘要/计数/取消规则不被替换；错误或取消不返回部分摘要。
    @MainActor func read(start: Start, cancel: @escaping Cancel) async throws -> LocalPhotoByteDigest {
        try Task.checkCancellation()
        let result: LocalPhotoByteDigest = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LocalPhotoByteDigest, any Error>) in
                let mayStart = state.withLock { value in
                    guard !value.cancelled, !value.finished, value.continuation == nil else { return false }
                    value.cancelRequest = cancel; value.continuation = continuation
                    return true
                }
                guard mayStart else { continuation.resume(throwing: CancellationError()); return }
                // 即使资源在iCloud中，传输工厂也只收到false；生产适配同样硬编码Photos选项false。
                let id = start(false, { [self] bytes in consume(bytes) }, { [self] error in finish(error) })
                let mustCancel = state.withLock { value in
                    value.requestID = id
                    return value.cancelled || value.failureComplete
                }
                if mustCancel {
                    cancel(id)
                }
            }
        } onCancel: { [self] in cancelReading() }
        try Task.checkCancellation()
        return result
    }

    /// bytes是一个Photos块；锁内更新真实SHA1与正字节数，溢出只失败，不生成不完整proof。
    private func consume(_ bytes: Data) {
        let overflow = state.withLock { value in
            guard !value.finished else { return false }
            let total = value.count.addingReportingOverflow(Int64(bytes.count))
            guard !total.overflow else { return true }
            value.hash.update(data: bytes); value.count = total.partialValue
            return false
        }
        if overflow {
            finish(LocalPhotoChecksumError.readFailed)
        }
    }

    /// error来自实际系统读取，成功只在非空完整流后生成摘要；保留networkRequired和取消的明确语义。
    private func finish(_ error: (any Error)?) {
        let outcome: (CheckedContinuation<LocalPhotoByteDigest, any Error>?, Result<LocalPhotoByteDigest, any Error>?, Cancel?, PHAssetResourceDataRequestID?) = state.withLock { value in
            guard !value.finished else { return (nil, nil, nil, nil) }
            value.finished = true
            let result: Result<LocalPhotoByteDigest, any Error>
            if value.cancelled {
                result = .failure(CancellationError())
            } else if let error {
                result = .failure(Self.safeFailure(error))
            } else if value.count <= 0 {
                result = .failure(LocalPhotoChecksumError.emptyResource)
            } else {
                do {
                    let digest = value.hash.finalize().map { String(format: "%02x", $0) }.joined()
                    result = try .success(LocalPhotoByteDigest(sha1Hex: digest, byteCount: value.count))
                } catch { result = .failure(LocalPhotoChecksumError.readFailed) }
            }
            if case .failure = result {
                value.failureComplete = true
            }
            let continuation = value.continuation; value.continuation = nil
            let cancellation = value.cancelRequest; value.cancelRequest = nil
            return (continuation, result, value.failureComplete ? cancellation : nil, value.requestID)
        }
        if let result = outcome.1 {
            outcome.0?.resume(with: result)
        }
        if let cancel = outcome.2, let id = outcome.3 {
            cancel(id)
        }
    }

    /// 取消可早于continuation/ID安装；先标记再完成，read拿到迟到ID后必须补做系统取消。
    private func cancelReading() {
        state.withLock { $0.cancelled = true }
        finish(CancellationError())
        // 已成功完成后才取消时finish不会再次发布；若请求尚在安装窗口，read仍观察cancelled。
    }

    /// error只映射公开Photos错误/取消，不透传系统路径或正文；其他失败不足以证明资源本地可读。
    private static func safeFailure(_ error: any Error) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? LocalPhotoChecksumError {
            return error
        }
        let error = error as NSError
        if error.domain == PHPhotosErrorDomain, error.code == PHPhotosError.Code.networkAccessRequired.rawValue {
            return LocalPhotoChecksumError.networkRequired
        }
        return LocalPhotoChecksumError.readFailed
    }
}

/// 仅生产PhotoKit请求器；资源只在主Actor使用，取消通过线程安全系统manager执行，不把PHAsset跨Actor传递。
final nonisolated class PhotoKitLocalResourceRequests: @unchecked Sendable {
    private let manager = PHAssetResourceManager.default()

    /// resource是已选且重验的公开资源；所有读取固定network=false，不提供开启云下载的参数。
    @MainActor func read(_ resource: PHAssetResource) async throws -> LocalPhotoByteDigest {
        let stream = LocalPhotoResourceSHA1Stream()
        return try await stream.read(start: { _, receive, complete in
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            return self.manager.requestData(for: resource, options: options, dataReceivedHandler: receive, completionHandler: complete)
        }, cancel: { [self] id in manager.cancelDataRequest(id) })
    }
}
