import Foundation

extension LibraryMutationClient {
    /// action是一次确认的意图，id为该次选择中的单个UUID；复用现有鉴权/取消/精确状态校验。
    /// 串行调用便于保留各项真实回执；任一未知结果由上层停止后续发送，不宣称整组原子成功。
    func applyBatchAction(_ action: BatchAssetAction, to id: String) async throws {
        switch action {
        case let .favorite(value): try await update(id, favorite: value)
        case let .archived(value): try await update(id, visibility: value ? "archive" : "timeline")
        case .trash: try await trash(id)
        case .restore: try await restore(id)
        case let .addToAlbum(album): try await performAlbumManagement(.add(id: album.id, assetID: id))
        case let .removeFromAlbum(album): try await performAlbumManagement(.remove(id: album.id, assetID: id))
        case let .albumCover(album): try await performAlbumManagement(.cover(id: album.id, assetID: id))
        }
    }
}

/// 只把服务器明确拒绝归为失败；取消/断网/异常成功响应可能发生在写入之后，需要停止并重载。
nonisolated struct BatchAssetFailure: Sendable {
    let state: BatchAssetItemState
    let stopsBatch: Bool

    /// error来自单个真实写请求；返回逐项状态和是否必须停止发送后续项，不自动重试。
    init(error: Error) {
        if case LibraryWriteError.invalidID = error {
            state = .rejected(.invalidInput)
            stopsBatch = false
        } else if case let LibraryWriteError.http(status) = error, (400 ... 499).contains(status), status != 408 {
            let rejection: BatchAssetRejection = switch status {
            case 400, 422: .invalidInput
            case 401: .unauthorized
            case 403: .forbidden
            case 404: .notFound
            case 409: .conflict
            case 429: .rateLimited
            default: .serverStatus(status)
            }
            state = .rejected(rejection)
            stopsBatch = status == 401 || status == 429
        } else {
            state = .unconfirmed
            stopsBatch = true
        }
    }
}
