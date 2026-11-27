import Nuke
import NukeUI
import SwiftUI
import UIKit

struct ImmichThumbnail: View {
    let descriptor: MediaRequestDescriptor
    let media: MediaLibraryController
    var contentMode: ContentMode = .fill
    var showsBackground = true
    var backgroundOpacity = 1.0
    var imageCornerRadius: CGFloat = 0
    var imageScale: CGFloat = 1
    var priority: ImageRequest.Priority = .normal
    var placeholderImage: UIImage?
    var logoPlaceholderCaption: RemmichCoverPlaceholder.Caption?
    var animatesImageLoading = true
    var didLoad: (ImageResponse) -> Void = { _ in }
    var didFail: () -> Void = {}

    @State private var retryID = 0

    var body: some View {
        let request = media.imageRequest(for: descriptor, priority: priority)
        let isCacheOnly = request?.options.contains(.returnCacheDataDontLoad) == true
        LazyImage(
            request: request,
            transaction: .init(animation: animatesImageLoading ? .easeOut(duration: 0.18) : nil)
        ) { state in
            ZStack {
                if showsBackground {
                    Rectangle()
                        .fill(.quaternary)
                        .opacity(backgroundOpacity)
                }
                if let image = state.image {
                    rendered(image)
                } else if let placeholderImage {
                    rendered(Image(uiImage: placeholderImage))
                } else if state.error != nil, !isCacheOnly {
                    Button {
                        retryID += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry image")
                } else if state.error != nil, isCacheOnly {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Thumbnail unavailable offline")
                } else if let logoPlaceholderCaption {
                    RemmichCoverLoadingView(caption: logoPlaceholderCaption)
                        .transition(.opacity)
                } else if isCacheOnly {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Thumbnail unavailable offline")
                } else if state.isLoading {
                    ProgressView(value: Double(state.progress.fraction))
                        .progressViewStyle(.circular)
                }
            }
            .clipped()
        }
        .pipeline(media.pipeline ?? .shared)
        .priority(priority)
        .onCompletion { result in
            media.recordThumbnailUICompletion(result, descriptor: descriptor)
            switch result {
            case let .success(response): didLoad(response)
            case let .failure(error):
                if let pipelineError = error as? ImagePipeline.Error, case .cancelled = pipelineError {
                    return
                }
                if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                didFail()
            }
        }
        .onDisappear(.cancel)
        .id("\(descriptor.assetID)-\(descriptor.updatedAt.timeIntervalSinceReferenceDate)-\(retryID)")
    }

    private func rendered(_ image: Image) -> some View {
        GeometryReader { geometry in
            image
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: imageCornerRadius,
                        style: .continuous
                    )
                )
                .scaleEffect(imageScale)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .center
                )
                .clipped()
        }
        .transition(animatesImageLoading ? .opacity : .identity)
    }
}
