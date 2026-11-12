import SwiftUI

/// Shown instead of a locked map: generic blurred backdrop (never the real
/// content), "Unlock with Face ID / Touch ID" and any problem (missing key,
/// failed authentication). Prompts by itself when the map was just opened
/// or the iPad app came back to the foreground.
struct LockScreenView: View {
    let model: MindMapModel
    let title: String
    @Environment(\.scenePhase) private var scenePhase

    private var lock: DocumentLock { model.lock }
    private var authenticator: LockAuthenticator { lock.services.authenticator }

    var body: some View {
        ZStack {
            LockBackdrop()
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("“\(title)” is locked")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Its topics, notes and files are encrypted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    unlock()
                } label: {
                    Label("Unlock with \(authenticator.methodName)", systemImage: authenticator.methodSymbol)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
                .padding(.top, 6)
                if let message = lock.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
            .padding(24)
        }
        .onAppear(perform: autoPromptIfWanted)
        .onChange(of: scenePhase) { _, _ in autoPromptIfWanted() }
    }

    private func autoPromptIfWanted() {
        guard lock.wantsAutoPrompt, scenePhase == .active, !lock.isAuthenticating else { return }
        lock.wantsAutoPrompt = false
        // Let the window finish appearing before the system prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { unlock() }
    }

    private func unlock() {
        Task { await model.unlockMap(reason: "Unlock “\(title)”") }
    }
}

/// Decorative, content-free "mind map" shapes, heavily blurred.
struct LockBackdrop: View {
    private static let colors: [Color] = [
        Color(red: 0.93, green: 0.45, blue: 0.44), Color(red: 0.95, green: 0.63, blue: 0.43),
        Color(red: 0.55, green: 0.80, blue: 0.95), Color(red: 0.62, green: 0.87, blue: 0.84),
        Color(red: 0.64, green: 0.83, blue: 0.71), Color(red: 0.73, green: 0.66, blue: 0.90),
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            ZStack {
                Color(white: 0.97)
                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) / 6 * 2 * .pi + 0.4
                    let point = CGPoint(x: center.x + cos(angle) * size.width * 0.3,
                                        y: center.y + sin(angle) * size.height * 0.28)
                    Path { path in
                        path.move(to: center)
                        path.addQuadCurve(to: point, control: CGPoint(x: (center.x + point.x) / 2, y: point.y))
                    }
                    .stroke(Self.colors[index].opacity(0.7), lineWidth: 6)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Self.colors[index].opacity(0.75))
                        .frame(width: 150, height: 44)
                        .position(point)
                }
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(white: 0.25).opacity(0.5))
                    .frame(width: 190, height: 56)
                    .position(center)
            }
            .blur(radius: 28)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Inside a note window / sheet while the note is locked: Unlock button
/// (prompts by itself once when the editor opens) and any problem.
struct LockedNoteView: View {
    let model: MindMapModel
    let attachment: Attachment
    /// Prompt right away (first appearance after opening the note).
    let autoPrompt: Bool
    let didAutoPrompt: () -> Void
    @State private var message: String?
    @State private var isWorking = false
    @Environment(\.scenePhase) private var scenePhase

    private var authenticator: LockAuthenticator { model.lock.services.authenticator }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("This \(attachment.kind == .drawing ? "handwritten note" : "note") is locked")
                .font(.title3.weight(.semibold))
            Button {
                unlock()
            } label: {
                Label("Unlock with \(authenticator.methodName)", systemImage: authenticator.methodSymbol)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard autoPrompt else { return }
            didAutoPrompt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { unlock() }
        }
    }

    private func unlock() {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            let result = await model.unlockNote(attachment.id, reason: "Unlock “\(attachment.title)”")
            isWorking = false
            switch result {
            case let .failed(text), let .unavailable(text): message = text
            case .success, .cancelled: break
            }
        }
    }
}
