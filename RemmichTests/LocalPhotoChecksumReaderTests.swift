import Foundation
import Photos
import Synchronization
import Testing
@testable import Remmich

/// 真实选择政策/reader/分块SHA1与取消，只有Photos系统来源用纯合成夹具替换；没有iCloud/服务媒体请求。
@Suite("Local current resource checksums")
@MainActor struct LocalPhotoChecksumReaderTests {
    /// NAS已有照片不必具备mobile-app/cloud ID；当前无调整图片/视频的本地字节可直接形成同一SHA1证明。
    @Test(arguments: [false, true]) func provesUnadjustedBytesWithoutCloudMetadata(_ video: Bool) async throws {
        let source = checksumAsset(video: video)
        let script = ChecksumSourceScript([source, source])
        let producer = ChecksumByteProducer()
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in
            let stream = LocalPhotoResourceSHA1Stream()
            return try await stream.read(start: { allowed, receive, complete in
                producer.install(allowed, receive: receive, complete: complete)
                producer.emit(Data(checksumBytes.prefix(7))); producer.emit(Data(checksumBytes.dropFirst(7)))
                producer.complete(nil); return 71
            }, cancel: producer.cancel)
        }, authorization: { .limited })
        let outcome = try await reader.checksum(for: source.snapshot, validateContext: {})
        guard case let .verified(proof) = outcome else { Issue.record("Expected a current resource byte proof"); return }
        #expect(proof.source.identity == source.snapshot.identity && proof.source.cloudIdentity == .unavailable)
        #expect(proof.resource == source.resources[0])
        #expect(proof.digest.sha1Hex == "c4502db68c24556654ccd8993abc2d2e578ad286" && proof.digest.byteCount == 37)
        #expect(proof.digest.sha1Base64 == "xFAttowkVWZUzNiZOrwtLleK0oY=")
        #expect(script.requests.count == 2 && producer.allowedValues == [false] && producer.cancelledIDs.isEmpty)
    }

    /// 不受支持的资源绝不读取原片来猜current；raw/复合、编辑fullsize、LivePhoto和未知版本明确不足。
    @Test(arguments: ["edited", "fullsize", "adjustment-data", "raw", "raw-jpeg", "duplicate", "unknown-format", "live", "no-version"])
    func unsupportedRepresentationsNeverReadBytes(_ kind: String) async throws {
        var source = checksumAsset()
        var expected: LocalPhotoChecksumInsufficiency = .currentRepresentationUnproven
        switch kind {
        case "edited": source = checksumAsset(adjusted: true)
        case "fullsize": source = checksumAsset(resources: [checksumResource(role: .adjusted, type: 5)])
        case "adjustment-data": source = checksumAsset(resources: [checksumResource(), checksumResource(role: .adjustmentData, type: 7)])
        case "raw": source = checksumAsset(resources: [checksumResource(format: .raw)]); expected = .rawOrCompound
        case "raw-jpeg": source = checksumAsset(resources: [checksumResource(format: .raw), checksumResource(role: .alternatePhoto, type: 4)]); expected = .rawOrCompound
        case "duplicate": source = checksumAsset(resources: [checksumResource(), checksumResource()]); expected = .ambiguousResources
        case "unknown-format": source = checksumAsset(resources: [checksumResource(format: .unsupported)]); expected = .unsupportedResource
        case "live": source = checksumAsset(live: true); expected = .unsupportedMedia
        default: source = checksumAsset(modified: nil); expected = .versionUnavailable
        }
        let script = ChecksumSourceScript([source])
        var reads = 0
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in reads += 1; throw LocalPhotoChecksumError.readFailed }, authorization: { .authorized })
        let result = try await reader.checksum(for: source.snapshot, validateContext: {})
        #expect(result == .insufficient(expected) && reads == 0 && script.requests.count == 1)
    }

    /// Task/账户/授权/资源变化都不能把旧摘要变成新版本proof；测试不把系统读取失败规范化成可用空值。
    @Test(arguments: ["expected-version", "after-version", "removed", "after-resource", "permission-before", "permission-after", "context-after"])
    func rejectsStaleSourceOrAuthority(_ kind: String) async throws {
        let initial = checksumAsset()
        let changed = kind == "after-resource" ? checksumAsset(resources: [checksumResource(name: "changed.jpg")]) : checksumAsset(modified: Date(timeIntervalSince1970: 20))
        let script = ChecksumSourceScript(kind == "expected-version" ? [changed] : [initial, kind == "removed" ? nil : changed])
        let context = ChecksumReadContext()
        var reads = 0
        var permission: PHAuthorizationStatus = kind == "permission-before" ? .denied : .authorized
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in
            reads += 1
            if kind == "permission-after" {
                permission = .limited
            }
            if kind == "context-after" {
                context.active = false
            }
            return try .init(sha1Hex: "c4502db68c24556654ccd8993abc2d2e578ad286", byteCount: 37)
        }, authorization: { permission })
        do { _ = try await reader.checksum(for: initial.snapshot, validateContext: context.validate); Issue.record("Expected stale source or authority to fail") }
        catch {
            if kind.hasPrefix("permission") {
                #expect(error as? LocalPhotoChecksumError == .permission)
            } else if kind == "context-after" {
                #expect(error as? LocalPhotoChecksumError == .sourceChanged)
            } else {
                #expect(error as? LocalPhotoChecksumError == .sourceChanged)
            }
        }
        #expect(reads == (["expected-version", "permission-before"].contains(kind) ? 0 : 1))
    }

    /// 资源不可见、cloud-only、空流、系统读取失败分别不足；没有任何路径把网络选项改成true或返回部分摘要。
    @Test(arguments: ["missing", "cloud-only", "empty", "failure"])
    func returnsExplicitInsufficientReasons(_ kind: String) async throws {
        let source = checksumAsset()
        let script = ChecksumSourceScript(kind == "missing" ? [nil] : [source])
        let producer = ChecksumByteProducer()
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in
            let stream = LocalPhotoResourceSHA1Stream()
            return try await stream.read(start: { allowed, receive, complete in
                producer.install(allowed, receive: receive, complete: complete)
                if kind == "cloud-only" {
                    producer.complete(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.networkAccessRequired.rawValue))
                } else if kind == "failure" {
                    producer.emit(checksumBytes); producer.complete(NSError(domain: "synthetic", code: 1))
                } else {
                    producer.complete(nil)
                }
                return 71
            }, cancel: producer.cancel)
        }, authorization: { .authorized })
        let outcome = try await reader.checksum(for: source.snapshot, validateContext: {})
        let expected: LocalPhotoChecksumInsufficiency = kind == "missing" ? .sourceUnavailable : kind == "cloud-only" ? .notLocallyAvailable : kind == "empty" ? .emptyResource : .readFailed
        #expect(outcome == .insufficient(expected))
        #expect(producer.allowedValues == (kind == "missing" ? [] : [false]))
        #expect(script.requests.count == 1)
    }

    /// 已安装请求和ID尚未返回两种取消窗口，均终止实际producer；晚到数据/完成不生成证明，等待门失败也唤醒。
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationReleasesBothRequestIDWindows(_ beforeID: Bool) async throws {
        let source = checksumAsset(); let script = ChecksumSourceScript([source, source])
        let producer = ChecksumByteProducer(); let box = ChecksumTaskBox()
        defer { producer.stop() }
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in
            let stream = LocalPhotoResourceSHA1Stream()
            return try await stream.read(start: { allowed, receive, complete in
                producer.install(allowed, receive: receive, complete: complete)
                producer.emit(Data(checksumBytes.prefix(7)))
                if beforeID {
                    box.cancel()
                }
                return 71
            }, cancel: producer.cancel)
        }, authorization: { .authorized })
        try await withTaskCancellationHandler {
            let operation = Task { try await reader.checksum(for: source.snapshot, validateContext: {}) }
            box.set(operation)
            let completion = Task { let result = await operation.result; producer.operationFinished(); return result }
            #expect(await producer.waitForStart())
            if !beforeID {
                operation.cancel()
            }
            let result = await completion.value
            if case let .failure(error) = result {
                #expect(error is CancellationError)
            } else {
                Issue.record("Cancelled read must not return a checksum proof")
            }
            producer.emit(checksumBytes); producer.complete(nil)
            #expect(producer.allowedValues == [false] && producer.cancelledIDs == [71] && script.requests.count == 1)
        } onCancel: { box.cancel(); producer.stop() }
    }

    /// 取消尚未开始的工作必须在系统枚举/哈希前失败；没有只取消UI等待却继续读取全部本机资源。
    @Test func alreadyCancelledNeverStartsSourceReads() async {
        let source = checksumAsset(); let script = ChecksumSourceScript([source])
        let reader = PhotoKitCurrentResourceChecksumReader(source: script.read, bytes: { _, _ in throw LocalPhotoChecksumError.readFailed }, authorization: { .authorized })
        let operation = Task { try await reader.checksum(for: source.snapshot, validateContext: {}) }; operation.cancel()
        let result = await operation.result
        if case let .failure(error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Already cancelled read must fail")
        }
        #expect(script.requests.isEmpty)
    }

    /// 非40位小写SHA1或空字节数在构造边界失败，不能进入只读服务查询。
    @Test func rejectsInvalidDigestValues() {
        for value in ["", "ABC", String(repeating: "A", count: 40), String(repeating: "g", count: 40)] {
            #expect(throws: LocalPhotoChecksumError.invalidDigest) { try LocalPhotoByteDigest(sha1Hex: value, byteCount: 1) }
        }
        #expect(throws: LocalPhotoChecksumError.invalidDigest) { try LocalPhotoByteDigest(sha1Hex: "c4502db68c24556654ccd8993abc2d2e578ad286", byteCount: 0) }
    }
}

/// 参考摘要由独立Node crypto计算，数据不来自照片库或生产哈希器。
nonisolated let checksumBytes = Data("synthetic local Photos current bytes\n".utf8)

/// role/type/format/name为独立合成公开描述，不用文件名推断资源是current。
nonisolated func checksumResource(role: LocalPhotoResourceDescriptor.Role = .originalPhoto, type: Int = 1,
                                  format: LocalPhotoChecksumFormat = .image, name: String = "synthetic.jpg") -> LocalPhotoChecksumResource
{
    .init(descriptor: .init(type: type, role: role, originalFilename: name, uniformTypeIdentifier: format == .video ? "com.apple.quicktime-movie" : "public.jpeg", pixelWidth: 64, pixelHeight: 48), format: format)
}

/// 所有时间、身份、媒体形态是固定合成值；cloudIdentity明确unavailable，以证明fallback不依赖mobile-app。
nonisolated func checksumAsset(video: Bool = false, live: Bool = false, adjusted: Bool = false, modified: Date? = Date(timeIntervalSince1970: 10),
                               resources: [LocalPhotoChecksumResource]? = nil) -> LocalPhotoChecksumAsset
{
    let resources = resources ?? [checksumResource(role: video ? .originalVideo : .originalPhoto, type: video ? 2 : 1, format: video ? .video : .image)]
    return .init(snapshot: .init(identity: .init(localIdentifier: "synthetic-local", modificationDate: modified, mediaKind: live ? .livePhoto : video ? .video : .image),
                                 creationDate: Date(timeIntervalSince1970: 1), adjustmentTime: adjusted ? Date(timeIntervalSince1970: 5) : nil, hasAdjustments: adjusted,
                                 latitude: nil, longitude: nil, pixelWidth: 64, pixelHeight: 48, duration: video ? 2 : 0, mediaSubtypes: 0, resources: resources.map(\.descriptor), cloudIdentity: .unavailable), resources: resources)
}

/// 主Actor控制的有限元数据序列；缺项是源消失，不用最后旧快照掩盖写后变化。
@MainActor private final class ChecksumSourceScript {
    private var values: [LocalPhotoChecksumAsset?]
    private(set) var requests: [String] = []
    /// values为每次实际source读取的独立结果。
    init(_ values: [LocalPhotoChecksumAsset?]) {
        self.values = values
    }

    /// id记录实际调用；多余读取直接失败，不能偷偷复用前一次源。
    func read(_ id: String) throws -> LocalPhotoChecksumAsset? {
        requests.append(id); guard !values.isEmpty else { throw LocalPhotoChecksumError.sourceChanged }; return values.removeFirst()
    }
}

/// 模拟账号/页面代际撤销，不更改生产reader的校验路径。
@MainActor private final class ChecksumReadContext {
    var active = true
    /// 失效后抛固定安全错误，不发布旧版本证明。
    func validate() throws {
        if !active {
            throw LocalPhotoChecksumError.sourceChanged
        }
    }
}

/// Task句柄用于在requestID返回前同步触发真实取消，不靠sleep制造竞态。
private final nonisolated class ChecksumTaskBox: @unchecked Sendable {
    private let task = Mutex<Task<LocalPhotoChecksumOutcome, any Error>?>(nil)
    /// value为真实reader任务，安装后start回调才可以取消它。
    func set(_ value: Task<LocalPhotoChecksumOutcome, any Error>) {
        task.withLock { $0 = value }
    }

    /// 可从取消处理器或同步请求工厂调用，取消真实Task。
    func cancel() {
        task.withLock { $0 }?.cancel()
    }
}

/// 合成PhotoKit producer；记录network=false与cancel ID，允许主动晚回调；全部共享字段受Mutex保护。
private final nonisolated class ChecksumByteProducer: @unchecked Sendable {
    private struct State {
        var allowed: [Bool] = []
        var cancellations: [PHAssetResourceDataRequestID] = []
        var receive: (@Sendable (Data) -> Void)?
        var complete: (@Sendable ((any Error)?) -> Void)?
        var waiter: CheckedContinuation<Bool, Never>?
        var started = false
        var ended = false
    }

    private let state = Mutex(State())
    var allowedValues: [Bool] {
        state.withLock { $0.allowed }
    }

    var cancelledIDs: [PHAssetResourceDataRequestID] {
        state.withLock { $0.cancellations }
    }

    /// allowed/receive/complete是生产stream真实传入；仅保存时序，不代替真实SHA1计算。
    func install(_ allowed: Bool, receive: @escaping @Sendable (Data) -> Void, complete: @escaping @Sendable ((any Error)?) -> Void) {
        let waiter = state.withLock { value in value.allowed.append(allowed); value.receive = receive; value.complete = complete; value.started = true; let waiter = value.waiter; value.waiter = nil; return waiter }
        waiter?.resume(returning: true)
    }

    /// bytes为合成块；实际stream决定是否更新摘要或忽略取消后的字节。
    func emit(_ bytes: Data) {
        state.withLock { $0.receive }?(bytes)
    }

    /// error模拟真实Photos完成；先移除持有回调再调用，避免测试producer与stream互相保留。
    func complete(_ error: (any Error)?) {
        let complete = state.withLock { value in let callback = value.complete; value.complete = nil; value.receive = nil; return callback }; complete?(error)
    }

    /// id是实际stream补做或即时取消的句柄，单独记录以验证ID安装竞态。
    func cancel(_ id: PHAssetResourceDataRequestID) {
        state.withLock { $0.cancellations.append(id) }
    }

    /// 实际进入请求后才继续测试；业务若先结束则返回false，不遗留永远等不到的门。
    func waitForStart() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = state.withLock {
                value in if value.started {
                    return true
                }; if value.ended {
                    return false
                }; value.waiter = continuation; return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// 完成真实Task的观察者调用，提前失败也唤醒门。
    func operationFinished() {
        let waiter = state.withLock { value in value.ended = true; let waiter = value.waiter; value.waiter = nil; return waiter }; waiter?.resume(returning: false)
    }

    /// 失败/超时清理释放所有回调和等待，不调用任何真实Photos或网络。
    func stop() {
        complete(CancellationError()); operationFinished()
    }
}
