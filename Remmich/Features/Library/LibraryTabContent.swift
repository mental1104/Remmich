import SwiftUI

/// 图库底栏下的相簿与分类；两个独立导航栈持续挂载，仅切换可见性，不丢失选图、滚动或返回历史。
struct LibraryTabContent: View {
    let selection: NativeTabDestination
    let atRoot: Bool
    let select: (NativeTabDestination) -> Void
    let albums: AnyView
    let collections: AnyView

    /// selection只使用albums/library；进入二级页面后收起切换器，Back仍归当前导航栈所有。
    var body: some View {
        VStack(spacing: 0) {
            if atRoot {
                Picker("Library Section", selection: Binding(get: { selection }, set: select)) {
                    Text("Albums").tag(NativeTabDestination.albums)
                    Text("Collections").tag(NativeTabDestination.library)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("library-section-picker")
            }
            ZStack {
                albums
                    .opacity(selection == .albums ? 1 : 0)
                    .allowsHitTesting(selection == .albums)
                    .accessibilityHidden(selection != .albums)
                collections
                    .opacity(selection == .library ? 1 : 0)
                    .allowsHitTesting(selection == .library)
                    .accessibilityHidden(selection != .library)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}
