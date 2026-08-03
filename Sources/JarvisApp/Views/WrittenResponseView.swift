import SwiftUI

/// Full-screen overlay shown when the user says "escríbeme" — the answer
/// appears as text instead of being spoken. Tapping the X in the top-left
/// dismisses it and returns to the normal HUD/voice screen.
struct WrittenResponseView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                ScrollView {
                    Text(text)
                        .font(.system(.title3, design: .rounded))
                        .foregroundColor(.white)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    WrittenResponseView(text: "Esto es una respuesta escrita de ejemplo.") {}
}
