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
                 caption: "Tap a topic for the action palette, write with Scribble, sketch notes with Apple Pencil.",
                 image: "Tour6"),
    ]
}

/// The Welcome Tour (WP13): six feature pages and, last, the storage
/// choice. Arrows / ← → keys / swipe, page dots, Skip. On the first launch
/// Skip jumps to the storage choice (it has to be made once); later Skip
/// closes the tour.
struct WelcomeTourView: View {
    var service: LibraryService = .shared
    let isFirstLaunch: Bool
    /// The storage page was confirmed (the mode) or the tour was closed (nil).
    let onFinish: (StorageMode?) -> Void
    /// macOS: a Files folder must be chosen before Files can be confirmed.
    var filesFolder: URL?
    var chooseFilesFolder: ((URL) -> Void)?
    var initialPage = 0

    @State private var page = 0
    @State private var drag: CGFloat = 0
    @State private var choice: StorageMode = .library
    @State private var isChoosingFolder = false

    private var pageCount: Int { TourPage.all.count + 1 }
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
                    StorageChoicePage(service: service, choice: $choice, filesFolder: filesFolder,
                                      canChooseFolder: chooseFilesFolder != nil,
                                      chooseFolder: { isChoosingFolder = true })
                        .frame(width: proxy.size.width, height: proxy.size.height)
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
        .onAppear {
            page = initialPage
            choice = service.settings.storageMode
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { chooseFilesFolder?(url) }
        }
    }

    private var topBar: some View {
        HStack {
            Text(isLastPage ? "One last step" : "Welcome to MindMap")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            if !isLastPage {
                Button("Skip") {
                    if isFirstLaunch {
                        withAnimation(.snappy) { page = pageCount - 1 }
                    } else {
                        onFinish(nil)
                    }
                }
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
                Button(action: confirm) {
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

    private func confirm() {
        if choice == .files, chooseFilesFolder != nil, filesFolder == nil {
            isChoosingFolder = true
            return
        }
        onFinish(choice)
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

/// Last tour page: iCloud Sync library or Files (WP14 storage mode), with
/// the live iCloud state.
struct StorageChoicePage: View {
    let service: LibraryService
    @Binding var choice: StorageMode
    var filesFolder: URL?
    var canChooseFolder: Bool
    var chooseFolder: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 34))
                    .foregroundStyle(WelcomeColors.brand)
                Text("Choose where new maps are saved")
                    .font(.system(size: 24, weight: .bold))
                Text("You can change this any time in Settings ▸ Storage. Opening .mindmap files always works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if sizeClass == .compact {
                VStack(spacing: 12) { cards }
            } else {
                HStack(alignment: .top, spacing: 16) { cards }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 780)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var cards: some View {
        StorageCard(mode: .library, isSelected: choice == .library, systemImage: "icloud",
                    title: "iCloud Sync",
                    subtitle: "Works without iCloud Drive, on all your devices.",
                    points: ["Maps sync through your iCloud account", "Available offline, merged per topic"]) {
            HStack(spacing: 6) {
                Image(systemName: availabilityIcon)
                    .foregroundStyle(service.availability.isAvailable ? Color.green : Color.orange)
                Text(availabilityText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } select: { choice = .library }
        StorageCard(mode: .files, isSelected: choice == .files, systemImage: "folder",
                    title: "Files",
                    subtitle: filesSubtitle,
                    points: ["Use any folder, iCloud Drive or a USB drive", "Share or back up maps like documents"]) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(folderText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if canChooseFolder {
                    Button(filesFolder == nil ? "Choose…" : "Change…", action: chooseFolder)
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } select: { choice = .files }
    }

    private var filesSubtitle: String {
        #if os(macOS)
        return ".mindmap files in a folder you choose, visible in Finder."
        #else
        return ".mindmap files in a folder, visible in the Files app."
        #endif
    }

    private var availabilityIcon: String {
        switch service.availability {
        case .available: return "checkmark.circle.fill"
        case .checking: return "clock"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var availabilityText: String {
        switch service.availability {
        case .available: return "iCloud is ready."
        case .checking: return "Checking iCloud…"
        case let .unavailable(reason):
            return "Not available now (\(reason)). Maps stay on this device until it is."
        }
    }

    private var folderText: String {
        if let filesFolder { return RecentLocation.text(for: filesFolder.appendingPathComponent("x")) }
        #if os(macOS)
        return "No folder chosen yet"
        #else
        return "On My iPad or iCloud Drive › MindMap"
        #endif
    }
}

private struct StorageCard<Footer: View>: View {
    let mode: StorageMode
    let isSelected: Bool
    let systemImage: String
    let title: String
    let subtitle: String
    let points: [String]
    @ViewBuilder let footer: () -> Footer
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(WelcomeColors.brand)
                    .frame(width: 30)
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? WelcomeColors.brand : Color.secondary.opacity(0.5))
            }
            Text(subtitle)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(points, id: \.self) { point in
                    Label(point, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            footer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(WelcomeColors.card))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? WelcomeColors.brand : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Choose \(title)", select)
    }
}

/// The tour as a sheet of the Welcome screen: finishing the first tour
/// copies the samples into the chosen store and opens "MindMap Features".
struct WelcomeTourSheet: View {
    let flow: WelcomeFlow
    let openMap: (URL) -> Void
    let dismiss: () -> Void
    @State private var isFirstLaunch = false
    @State private var folder: URL?
    @State private var errorText: String?

    var body: some View {
        WelcomeTourView(service: flow.service, isFirstLaunch: isFirstLaunch, onFinish: finish,
                        filesFolder: folder, chooseFilesFolder: chooser, initialPage: initialPage)
            #if os(macOS)
            .frame(width: 880, height: 660)
            #else
            .gestureHelpSizing() // page-sized sheet on iPad
            #endif
            .interactiveDismissDisabled(isFirstLaunch)
            .onAppear {
                isFirstLaunch = !flow.isTourCompleted
                #if os(macOS)
                folder = flow.chosenFilesFolder
                #endif
            }
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

    private var chooser: ((URL) -> Void)? {
        #if os(macOS)
        return { url in
            do {
                try flow.setFilesFolder(url)
                folder = flow.chosenFilesFolder
            } catch {
                errorText = "The folder could not be used (\(error.localizedDescription))."
            }
        }
        #else
        return nil
        #endif
    }

    private func finish(_ choice: StorageMode?) {
        Task {
            do {
                let sample = try await flow.finishTour(choice: choice ?? (isFirstLaunch ? flow.service.settings.storageMode : nil))
                dismiss()
                if let sample { openMap(sample) }
            } catch {
                errorText = "The sample maps could not be copied (\(error.localizedDescription))."
            }
        }
    }
}
