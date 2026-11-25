import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Photos
import Synchronization
import UIKit
import UniformTypeIdentifiers
@testable import Remmich

/// 真实资源重建实验的可复查收据；UUID/像素/摘要都只属于本例合成文件，不含图库或设备身份。
nonisolated struct LocalLivePhotoFixtureReceipt: Codable, Sendable {
    let contentIdentifier: String
    let jpegIdentifier: String
    let movieIdentifier: String
    let markerValue: Int
    let markerTime: Double
    let movieDuration: Double
    let videoFrameDecoded: Bool
    let resourceTypes: [Int]
    let pixelWidth: Int
    let pixelHeight: Int
    let stillSHA1Hex: String
    let motionSHA1Hex: String
    let stillByteCount: Int64
    let motionByteCount: Int64
    let stillSHA256: String
    let motionSHA256: String
    let systemVersion: String
}

/// 实验失败保留阶段及临时文件位置；真正native对象未返回前不能被称为正例，不自动skip或mock成功。
nonisolated enum LocalLivePhotoFixtureError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case let .failed(message): "Native Live Photo fixture failed: \(message)" }
    }
}

/// 仅合成fixture使用的单轨供给端口；ready只表示本轮能前进，不能阻止其他轨获得供给机会。
@MainActor struct SyntheticLivePhotoWriterTrack {
    enum Kind: String, Hashable, Sendable { case audio, metadata, video }
    let kind: Kind
    let sampleCount: Int
    let isReady: @MainActor () -> Bool
    let append: @MainActor (Int) throws -> Void
    let finish: @MainActor () -> Void

    /// kind用于诊断，sampleCount为实际样本数；append接收当前零基样本下标，finish在本轨全部写入后只调用一次。
    /// 所有闭包留在同一MainActor，真实AVFoundation对象不跨Sendable/队列边界。
    init(kind: Kind, sampleCount: Int, isReady: @escaping @MainActor () -> Bool,
         append: @escaping @MainActor (Int) throws -> Void, finish: @escaping @MainActor () -> Void)
    {
        self.kind = kind; self.sampleCount = sampleCount; self.isReady = isReady; self.append = append; self.finish = finish
    }
}

/// 公开PhotoKit实际验证过的native对象及其临时资源lease；只供Tests，close后不得继续使用对象/文件。
/// JPEG17映射和合成pair被Simulator接受属于实验推断，make的真实返回才证明本次对象有效。
@MainActor final class SyntheticLivePhotoFixture {
    let native: PHLivePhoto
    let stillURL: URL
    let motionURL: URL
    let identifier: String
    let pixels: MediaPixelSize
    let stillDigest: LocalPhotoByteDigest
    let motionDigest: LocalPhotoByteDigest
    let receipt: LocalLivePhotoFixtureReceipt
    let directory: URL
    private var closed = false
    private static let width = 320
    private static let height = 240
    private static let fps: Int32 = 30
    private static let seconds = 3
    private static let stillFrame = 45
    private static let markerIdentifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")

    /// native已由真实request返回；URL/directory为本例独占文件，identifier/pixels/摘要与已回读的receipt一致。
    /// 返回的lease由调用方close；不把底层资源可经PHAssetResourceManager再次读取当作重建对象的先决条件。
    private init(native: PHLivePhoto, stillURL: URL, motionURL: URL, stillDigest: LocalPhotoByteDigest, motionDigest: LocalPhotoByteDigest,
                 receipt: LocalLivePhotoFixtureReceipt, directory: URL)
    {
        self.native = native; self.stillURL = stillURL; self.motionURL = motionURL
        identifier = receipt.contentIdentifier; pixels = .init(width: Self.width, height: Self.height)
        self.stillDigest = stillDigest; self.motionDigest = motionDigest; self.receipt = receipt; self.directory = directory
    }

    /// 仅在唯一temp目录生成JPEG+MOV，不读/写Photos库；任何格式/native/身份失败都抛错并保留失败文件和收据。
    static func make() async throws -> SyntheticLivePhotoFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeLiveFixture-\(UUID())", isDirectory: true)
        let still = directory.appendingPathComponent("still.jpg"); let motion = directory.appendingPathComponent("motion.mov")
        let identifier = UUID().uuidString
        var stage = "directory"
        var nativeReturned = false
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stage = "jpeg"; try writeJPEG(still, identifier: identifier)
            stage = "movie"; try await writeMovie(motion, identifier: identifier)
            stage = "independent-file-validation"
            let inspection = try await inspectFiles(still: still, motion: motion, identifier: identifier)
            let stillDigest = try fileDigest(still); let motionDigest = try fileDigest(motion)
            stage = "native-request"
            let native = try await requestNative(still: still, motion: motion)
            nativeReturned = true
            try Task.checkCancellation()
            stage = "native-resource-identity"
            let types = try resourceTypes(native)
            let receipt = try LocalLivePhotoFixtureReceipt(contentIdentifier: identifier, jpegIdentifier: inspection.jpegIdentifier,
                                                           movieIdentifier: inspection.movieIdentifier, markerValue: inspection.markerValue,
                                                           markerTime: inspection.markerTime, movieDuration: inspection.duration, videoFrameDecoded: true,
                                                           resourceTypes: types, pixelWidth: width, pixelHeight: height,
                                                           stillSHA1Hex: stillDigest.sha1Hex, motionSHA1Hex: motionDigest.sha1Hex,
                                                           stillByteCount: stillDigest.byteCount, motionByteCount: motionDigest.byteCount,
                                                           stillSHA256: sha256(still), motionSHA256: sha256(motion),
                                                           systemVersion: UIDevice.current.systemVersion)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
            return .init(native: native, stillURL: still, motionURL: motion, stillDigest: stillDigest, motionDigest: motionDigest,
                         receipt: receipt, directory: directory)
        } catch {
            let errorValue = error as NSError
            // 自有ASCII诊断包含精确nil/error/timeout原因；系统正文只写合成文件收据，不依赖CI能下载temp才看见失败阶段。
            let summary = (error as? LocalLivePhotoFixtureError)?.errorDescription ?? "\(errorValue.domain):\(errorValue.code)"
            let failure: [String: Any] = ["stage": stage, "contentIdentifier": identifier, "errorDomain": errorValue.domain, "errorCode": errorValue.code,
                                          "reason": error.localizedDescription, "systemVersion": UIDevice.current.systemVersion,
                                          "nativeReturned": nativeReturned, "fixtureSuccess": false]
            if let bytes = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: directory.appendingPathComponent("failure.json"), options: .atomic)
            }
            print("NativeLivePhotoFixture retained stage=\(stage) directory=\(directory.path) error=\(summary)")
            if error is CancellationError {
                throw error
            }
            throw LocalLivePhotoFixtureError.failed("\(stage), files=\(directory.path), error=\(summary)")
        }
    }

    /// 仅删除此lease创建的唯一目录，可重复关闭；显式调用会报告真实清理错误，不操作图库或外部路径。
    func close() throws {
        guard !closed else { return }
        try FileManager.default.removeItem(at: directory); closed = true
    }

    /// URL只属于本例；ImageIO实际编码JPEG，MakerApple17对应ContentIdentifier是ExifTool主证支持的实验映射。
    private static func writeJPEG(_ url: URL, identifier: String) throws {
        // 明确scale=1，避免Simulator屏幕scale把JPEG变成640/960像素而MOV仍是320像素。
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format)
        let image = renderer.image { drawFrame($0.cgContext, frame: stillFrame) }
        guard let image = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw LocalLivePhotoFixtureError.failed("JPEG destination") }
        let properties: [CFString: Any] = [kCGImagePropertyMakerAppleDictionary: ["17": identifier], kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LocalLivePhotoFixtureError.failed("JPEG finalize") }
    }

    /// context/frame生成纯几何运动；still与movie中点共用同一画面，不使用相机、真实照片或随机噪声。
    private static func drawFrame(_ context: CGContext, frame: Int) {
        context.setFillColor(red: 0.15, green: 0.35, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(red: 0.95, green: 0.5, blue: 0.15, alpha: 1)
        // 垂直居中使UIGraphics与bitmap CGContext的坐标翻转不改变still对应帧。
        context.fill(CGRect(x: CGFloat(20 + frame * 2), y: 85, width: 50, height: 70))
    }

    /// URL/identifier限定本例MOV；公开writer生成H264帧、静音PCM和SInt8(-1) timed轨，写入失败不降级为假视频。
    private static func writeMovie(_ url: URL, identifier: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }
        let global = AVMutableMetadataItem(); global.identifier = .quickTimeMetadataContentIdentifier
        global.dataType = kCMMetadataBaseDataType_UTF8 as String; global.value = identifier as NSString
        writer.metadata = [global]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                                                                           AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000]])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                         kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: attributes)
        let (audio, audioSample) = try silentAudio()
        let metadata = try AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: markerDescription())
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        for input in [video, audio, metadata] {
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LocalLivePhotoFixtureError.failed("Writer input unavailable") }
            writer.add(input)
        }
        guard writer.startWriting() else { throw LocalLivePhotoFixtureError.failed("Writer start") }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let marker = AVMutableMetadataItem(); marker.identifier = markerIdentifier
        marker.dataType = kCMMetadataBaseDataType_SInt8 as String; marker.value = NSNumber(value: Int8(-1))
        let time = CMTime(value: Int64(stillFrame), timescale: fps)
        // 各轨独立询问真实ready；一轨等其他轨先输入时，不能在它上面await而饿死已ready的轨。
        let tracks: [SyntheticLivePhotoWriterTrack] = [
            .init(kind: .audio, sampleCount: 1, isReady: { audio.isReadyForMoreMediaData }, append: { _ in
                guard audio.append(audioSample) else { throw LocalLivePhotoFixtureError.failed("Audio append") }
            }, finish: { audio.markAsFinished() }),
            .init(kind: .metadata, sampleCount: 1, isReady: { metadata.isReadyForMoreMediaData }, append: { _ in
                guard timed.append(.init(items: [marker], timeRange: .init(start: time, duration: CMTime(value: 1, timescale: fps)))) else {
                    throw LocalLivePhotoFixtureError.failed("Marker append")
                }
            }, finish: { metadata.markAsFinished() }),
            .init(kind: .video, sampleCount: Int(fps) * seconds, isReady: { video.isReadyForMoreMediaData }, append: { frame in
                guard let pool = pixels.pixelBufferPool else { throw LocalLivePhotoFixtureError.failed("Pixel buffer pool") }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw LocalLivePhotoFixtureError.failed("Pixel allocation")
                }
                try drawPixel(buffer, frame: frame)
                guard pixels.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                    throw LocalLivePhotoFixtureError.failed("Video append")
                }
            }, finish: { video.markAsFinished() }),
        ]
        try await feedMovieTracks(tracks, deadline: deadline, status: { writer.status }, failure: { writer.error })
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        try await finish(writer)
    }

    /// tracks每轮各获得一次前进机会，只有全部没有进展才让出执行器；不按轨顺序阻塞等待。
    /// deadline沿用同一movie的30s预算；status/failure是实时writer状态，错误含每轨已提交数，取消仍抛CancellationError。
    static func feedMovieTracks(_ tracks: [SyntheticLivePhotoWriterTrack], deadline: ContinuousClock.Instant,
                                status: @MainActor () -> AVAssetWriter.Status, failure: @MainActor () -> (any Error)?) async throws
    {
        guard tracks.count == 3, Set(tracks.map(\.kind)) == [.audio, .metadata, .video], tracks.allSatisfy({ $0.sampleCount > 0 }) else {
            throw LocalLivePhotoFixtureError.failed("Writer track configuration")
        }
        var submitted = Array(repeating: 0, count: tracks.count)
        while tracks.indices.contains(where: { submitted[$0] < tracks[$0].sampleCount }) {
            try Task.checkCancellation()
            guard status() == .writing else { throw writerFeedError("Writer stopped", tracks: tracks, submitted: submitted, status: status(), failure: failure()) }
            guard ContinuousClock.now < deadline else { throw writerFeedError("Writer readiness timeout", tracks: tracks, submitted: submitted, status: status(), failure: failure()) }
            var progressed = false
            for index in tracks.indices where submitted[index] < tracks[index].sampleCount {
                let track = tracks[index]
                guard track.isReady() else { continue }
                try Task.checkCancellation()
                guard status() == .writing else { throw writerFeedError("Writer stopped", tracks: tracks, submitted: submitted, status: status(), failure: failure()) }
                do { try track.append(submitted[index]) }
                catch {
                    if error is CancellationError {
                        throw error
                    }
                    throw writerFeedError("Writer append input=\(track.kind.rawValue)", tracks: tracks, submitted: submitted, status: status(), failure: failure() ?? error)
                }
                submitted[index] += 1; progressed = true
                if submitted[index] == track.sampleCount {
                    track.finish()
                }
            }
            if !progressed {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try Task.checkCancellation()
    }

    /// 只记录合成writer状态/轨道进度和NSError类别；非writing与真正超时分开，避免再把失败状态误报成等待超时。
    private static func writerFeedError(_ reason: String, tracks: [SyntheticLivePhotoWriterTrack], submitted: [Int],
                                        status: AVAssetWriter.Status, failure: (any Error)?) -> LocalLivePhotoFixtureError
    {
        let progress = tracks.indices.map { "\(tracks[$0].kind.rawValue)=\(submitted[$0])/\(tracks[$0].sampleCount)" }.joined(separator: ",")
        let cause = failure.map { let value = $0 as NSError; return "\(value.domain):\(value.code)" } ?? "none"
        return .failed("\(reason); status=\(status.rawValue); submitted=\(progress); error=\(cause)")
    }

    /// buffer由当前writer pool创建；BGRA与CG bitmap字节序一致，frame只决定几何位置。
    private static func drawPixel(_ buffer: CVPixelBuffer, frame: Int) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw LocalLivePhotoFixtureError.failed("Pixel lock") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw LocalLivePhotoFixtureError.failed("Pixel context") }
        drawFrame(context, frame: frame)
    }

    /// 全部静音的3s/44.1kHz/16-bit mono PCM；sourceFormatHint和实际sample均由公开CoreMedia生成。
    private static func silentAudio() throws -> (AVAssetWriterInput, CMSampleBuffer) {
        var description: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr, let description
        else { throw LocalLivePhotoFixtureError.failed("Audio format") }
        let count = 44100 * seconds; var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 2, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) == kCMBlockBufferNoErr
        else { throw LocalLivePhotoFixtureError.failed("Audio data") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2; var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: count,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { throw LocalLivePhotoFixtureError.failed("Audio sample") }
        return (AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description), sample)
    }

    /// Boxed mdta标识/类型来自ExifTool的实读格式，值-1的实际时间由该sample的CMTimeRange携带。
    private static func markerDescription() throws -> CMMetadataFormatDescription {
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: markerIdentifier.rawValue,
                                            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        var description: CMMetadataFormatDescription?
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                                                                          metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description) == noErr,
            let description else { throw LocalLivePhotoFixtureError.failed("Marker format") }
        return description
    }

    /// writer完成回调只触Sendable gate；Task取消/10s无终态也能唤醒等待并在主Actor取消实际writer。
    private static func finish(_ writer: AVAssetWriter) async throws {
        let gate = PhotoResourceRead<Bool>()
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled else { return }; writer.cancelWriting(); gate.cancel()
        }
        defer { timer.cancel() }
        let value: Bool? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.begin(continuation)
                guard !Task.isCancelled else { gate.cancel(); return }
                writer.finishWriting { gate.finish(true) }
            }
        } onCancel: { gate.cancel() }
        if Task.isCancelled {
            writer.cancelWriting(); throw CancellationError()
        }
        guard value == true, writer.status == .completed else { throw LocalLivePhotoFixtureError.failed("Writer finish") }
    }

    /// 独立读取结果，不拿writer内存中的metadata当成落盘已成功；必须能解码JPEG、movie帧及timed轨。
    private static func inspectFiles(still: URL, motion: URL, identifier: String) async throws -> LocalLiveFileInspection {
        guard let source = CGImageSourceCreateWithURL(still as CFURL, nil), let stillImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              stillImage.width == width, stillImage.height == height,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any], let jpegIdentifier = maker["17"] as? String,
              jpegIdentifier == identifier else { throw LocalLivePhotoFixtureError.failed("JPEG content identifier round trip") }
        let asset = AVURLAsset(url: motion)
        let metadata = try await asset.load(.metadata)
        guard let content = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }),
              let movieIdentifier = try await content.load(.stringValue), movieIdentifier == identifier else { throw LocalLivePhotoFixtureError.failed("MOV content identifier round trip") }
        let movieTime = try await asset.load(.duration); let duration = movieTime.seconds
        guard duration.isFinite, abs(duration - Double(seconds)) < 0.01 else { throw LocalLivePhotoFixtureError.failed("Movie duration") }
        let videos = try await asset.loadTracks(withMediaType: .video); let audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == 1 else { throw LocalLivePhotoFixtureError.failed("Movie audio/video tracks") }
        let generator = AVAssetImageGenerator(asset: asset); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: Int64(stillFrame), timescale: fps))
        try Task.checkCancellation()
        guard frame.image.width == width, frame.image.height == height,
              abs(frame.actualTime.seconds - Double(stillFrame) / Double(fps)) < 0.001 else { throw LocalLivePhotoFixtureError.failed("Decoded video frame") }
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard tracks.count == 1, let track = tracks.first else { throw LocalLivePhotoFixtureError.failed("Timed metadata track") }
        let reader = try AVAssetReader(asset: asset); let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw LocalLivePhotoFixtureError.failed("Metadata reader input") }; reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.startReading() else { throw LocalLivePhotoFixtureError.failed("Metadata reader start") }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }
        var groups: [AVTimedMetadataGroup] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            groups.append(group); guard groups.count <= 2 else { throw LocalLivePhotoFixtureError.failed("Unexpected timed samples") }
        }
        guard reader.status == .completed, groups.count == 1, let group = groups.first,
              group.items.count == 1, let marker = group.items.first, marker.identifier == markerIdentifier,
              marker.dataType == kCMMetadataBaseDataType_SInt8 as String,
              abs(group.timeRange.start.seconds - Double(stillFrame) / Double(fps)) < 0.001
        else { throw LocalLivePhotoFixtureError.failed("Timed still marker round trip") }
        let markerNumber = try await marker.load(.numberValue)
        guard markerNumber?.intValue == -1 else { throw LocalLivePhotoFixtureError.failed("Timed still marker value") }
        return .init(jpegIdentifier: jpegIdentifier, movieIdentifier: movieIdentifier, markerValue: -1, markerTime: group.timeRange.start.seconds, duration: duration)
    }

    /// 文件API的ID/结果键与PHImageManager不同；仅完整native结果可返回，10s、Task取消及ID安装竞态共用真实gate。
    private static func requestNative(still: URL, motion: URL) async throws -> PHLivePhoto {
        try Task.checkCancellation()
        let gate = PhotoResourceRead<PHLivePhoto>(); let diagnostic = LocalLiveNativeDiagnostic()
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled else { return }; diagnostic.record("timeout"); gate.cancel()
        }
        defer { timer.cancel() }
        let value: PHLivePhoto? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.begin(continuation)
                guard !Task.isCancelled else { gate.cancel(); return }
                let id = PHLivePhoto.request(withResourceFileURLs: [still, motion], placeholderImage: nil,
                                             targetSize: CGSize(width: CGFloat(width), height: CGFloat(height)), contentMode: .aspectFit)
                { photo, info in
                    if let error = info[PHLivePhotoInfoErrorKey] as? NSError {
                        diagnostic.record("native-error:\(error.domain):\(error.code)"); gate.finish(nil)
                    } else if info[PHLivePhotoInfoCancelledKey] as? Bool == true {
                        diagnostic.record("native-cancelled"); gate.finish(nil)
                    } else if info[PHLivePhotoInfoIsDegradedKey] as? Bool != true {
                        if photo == nil {
                            diagnostic.record("nil-native")
                        }; gate.finish(photo)
                    }
                }
                gate.install { PHLivePhoto.cancelRequest(withRequestID: id) }
            }
        } onCancel: { gate.cancel() }
        try Task.checkCancellation()
        guard let value else { throw LocalLivePhotoFixtureError.failed(diagnostic.value) }
        return value
    }

    /// native必须来自真实request；只核公开资源成员类型，不假设未入库对象可由ResourceManager取回字节。
    /// 返回真实资源类型列表，形状不符抛错；摘要验证独立读取本例原始输入文件。
    private static func resourceTypes(_ native: PHLivePhoto) throws -> [Int] {
        let resources = PHAssetResource.assetResources(for: native)
        let photos = resources.filter { $0.type == .photo || $0.type == .fullSizePhoto }
        let videos = resources.filter { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
        guard resources.count == 2, photos.count == 1, videos.count == 1 else { throw LocalLivePhotoFixtureError.failed("Native resource shape") }
        return resources.map(\.type.rawValue).sorted()
    }

    /// url必须指向本例合成输入；返回真实非空SHA1及字节数，供后续本机proof测试使用，不代表已上传或备份。
    private static func fileDigest(_ url: URL) throws -> LocalPhotoByteDigest {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw LocalLivePhotoFixtureError.failed("Synthetic resource size") }
        return try .init(sha1Hex: Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(data.count))
    }

    /// url为合成原文件；收据额外保留独立SHA256便于失败/后续CI复查，不作为服务器备份凭据。
    private static func sha256(_ url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 文件重新读取的窄结果，和writer中待写metadata分开，不把内存输入当成落盘证明。
private nonisolated struct LocalLiveFileInspection: Sendable {
    let jpegIdentifier: String
    let movieIdentifier: String
    let markerValue: Int
    let markerTime: Double
    let duration: Double
}

/// 任意Photos callback线程只记录固定诊断值；裸Any字典在当次回调内消费，不跨actor。
private final nonisolated class LocalLiveNativeDiagnostic: Sendable {
    private let state = Mutex("native-incomplete")
    var value: String {
        state.withLock { $0 }
    }

    /// message只含失败类别或系统错误domain/code；首个诊断保留，取消回调不能覆盖先发生的timeout。
    func record(_ message: String) {
        state.withLock {
            if $0 == "native-incomplete" {
                $0 = message
            }
        }
    }
}
