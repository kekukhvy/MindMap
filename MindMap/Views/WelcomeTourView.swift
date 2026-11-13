import SwiftUI
import UniformTypeIdentifiers

/// One page of the Welcome Tour: a real rendered picture of the app
/// (asset "TourN", made by `Tools/tour/generate.sh`) and a short caption.
struct TourPage: Identifiable {
    let id: Int
    let title: String
    let caption: String
    let image: String

    static let all: [TourPage] = [
        TourPage(id: 1, title: "Maps the XMind way",
                 caption: "Type, press Tab for a child and Return for a sibling. Map, Logic, Tree and Org Chart "
                    + "layouts — per branch.", image: "Tour1"),
        TourPage(id: 2, title: "Styles, shapes and themes",
                 caption: "Pastel themes, shapes, borders and branch lines for one topic or a whole branch.",
                 image: "Tour2"),
        TourPage(id: 3, title: "Notes, handwriting and files",
                 caption: "Attach Markdown notes, Pencil sketches and any file. The icons stay small on the topic.",
                 image: "Tour3"),
        TourPage(id: 4, title: "Links and tasks",
                 caption: "Link to websites, topics and other maps. Turn topics into tasks — the Tasks panel "
                    + "collects them.", image: "Tour4"),
        TourPage(id: 5, title: "Select, group, relate",
                 caption: "Select several topics (⌘-click, or Select on iPad), draw a boundary around them and "
                    + "connect ideas with relationships.", image: "Tour5"),
        TourPage(id: 6, title: "Made for iPad and Pencil",
                 caption: "Tap a topic to fold it and get the action palette, double-tap to add a child, "
                    + "write on topics with Scribble, sketch notes with Apple Pencil.",
                 image: "Tour6"),
    ]
}

/// The Welcome Tour (WP13): six feature pages. Arrows / ← → keys / swipe,
/// page dots, Skip, Continue on the last page. New maps are always files:
/// the first tour (finished or skipped) sets the Files storage mode.
struct WelcomeTourView: View {
    let isFirstLaunch: Bool
    /// The storage mode to set (Files on the first launch) or nil (keep it).
    let onFinish: (StorageMode?) -> Void
    var initialPage = 0

    @State private var page = 0
    @State private var drag: CGFloat = 0

    private var pageCount: Int { TourPage.all.count }
    private var isLastPage: Bool { page == pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(TourPage.all) { item in
                        TourPageView(page: item)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .offset(x: -CGFloat(page) * proxy.size.width + drag)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        drag = value.translation.width
                    }
                    .onEnded { value in
                        let threshold = proxy.size.width * 0.18
                        let predicted = value.predictedEndTranslation.width
                        withAnimation(.snappy) {
                            if value.translation.width < -threshold || predicted < -proxy.size.width / 2 {
                                page = min(page + 1, pageCount - 1)
                            } else if value.translation.width > threshold || predicted > proxy.size.width / 2 {
                                page = max(page - 1, 0)
                            }
                            drag = 0
                        }
                    })
            }
            .clipped()
            bottomBar
        }
        .background(TourBackground())
        .onAppear { page = min(initialPage, pageCount - 1) }
    }

    private var topBar: some View {
        HStack {
            Text("Welcome to MindMap")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            if !isLastPage {
                Button("Skip", action: finish)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(isFirstLaunch ? nil : .cancelAction)
            } else if !isFirstLaunch {
                Button("Close") { onFinish(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(.snappy) { page = max(page - 1, 0) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .opacity(page == 0 ? 0.3 : 1)
            .disabled(page == 0)
            .accessibilityLabel("Previous")

            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? WelcomeColors.brand : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 22 : 8, height: 8)
                        .onTapGesture { withAnimation(.snappy) { page = index } }
                }
            }
            .animation(.snappy, value: page)
            Spacer()

            if isLastPage {
                Button(action: finish) {
                    Text("Continue")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(WelcomeColors.brand))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    withAnimation(.snappy) { page = min(page + 1, pageCount - 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(WelcomeColors.brand))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityLabel("Next")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func finish() {
        onFinish(isFirstLaunch ? .files : nil)
    }
}

/// One feature page: the picture in a card, title, caption.
private struct TourPageView: View {
    let page: TourPage

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(page.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .frame(maxWidth: 1000)
                .layoutPriority(1)
            VStack(spacing: 6) {
                Text(page.title)
                    .font(.system(size: 24, weight: .bold))
                Text(page.caption)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Soft brand-tinted background of the tour.
private struct TourBackground: View {
    var body: some View {
        ZStack {
            WelcomeColors.background
            LinearGradient(colors: [WelcomeColors.brand.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// The tour as a sheet of the Welcome screen: finishing the first tour
/// copies the samples into the chosen store and opens "MindMap Features".
struct WelcomeTourSheet: View {
    let flow: WelcomeFlow
    let openMap: (URL) -> Void
    let dismiss: () -> Void
    @State private var isFirstLaunch = false
    @State private var errorText: String?

    var body: some View {
        WelcomeTourView(isFirstLaunch: isFirstLaunch, onFinish: finish, initialPage: initialPage)
            #if os(macOS)
            .frame(width: 880, height: 660)
            #else
            .pageSheetSizing() // page-sized sheet on iPad
            #endif
            .interactiveDismissDisabled(isFirstLaunch)
            .onAppear { isFirstLaunch = !flow.isTourCompleted }
            .alert("MindMap", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(errorText ?? "")
            }
    }

    private var initialPage: Int {
        #if DEBUG
        return WelcomeDebugHook.tourPage
        #else
        return 0
        #endif
    }

    private func finish(_ choice: StorageMode?) {
        Task {
            do {
                let sample = try await flow.finishTour(choice: choice)
                dismiss()
                if let sample { openMap(sample) }
            } catch {
                errorText = "The sample maps could not be copied (\(error.localizedDescription))."
            }
        }
    }
}
