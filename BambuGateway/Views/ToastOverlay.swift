#if os(iOS)
import SwiftUI

struct ToastOverlay: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastBannerView(toast: toast) {
                    center.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal)
                .padding(.top, 8)
            }
            Spacer()
        }
        .animation(.spring(duration: 0.3), value: center.current)
        .allowsHitTesting(center.current != nil)
    }
}

private struct ToastBannerView: View {
    let toast: ToastMessage
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.fill")
                .foregroundStyle(.white)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if !toast.title.isEmpty {
                    Text(toast.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                if !toast.body.isEmpty {
                    Text(toast.body)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
#endif
