import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var isArchive: Bool { url.pathExtension.lowercased() == "zip" }
}

@MainActor
final class ShelfService: ObservableObject {
    @Published private(set) var items: [ShelfItem]
    @Published private(set) var isWorking = false

    init() {
        let stored = JSONStore.load([ShelfItem].self, from: "shelf.json") ?? []
        items = stored.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(urls: [URL]) {
        var changed = false
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            items.append(ShelfItem(path: url.path))
            changed = true
        }
        if changed { save() }
    }

    func add(providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.add(urls: [url]) }
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ items: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    func airDrop(_ items: [ShelfItem]) {
        let urls = items.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func zip(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let sources = items.map(\.url)
        let directory = Self.writableDirectory(near: sources[0])
        let baseName = sources.count == 1 ? sources[0].deletingPathExtension().lastPathComponent : "Archive"
        let destination = Self.uniqueURL(in: directory, name: baseName, pathExtension: "zip")

        runInBackground {
            if sources.count == 1 {
                return Self.ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, destination.path]) ? destination : nil
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(baseName)
            defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                for source in sources {
                    try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
                }
            } catch {
                return nil
            }
            return Self.ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path]) ? destination : nil
        }
    }

    func unzip(_ item: ShelfItem) {
        guard item.isArchive else { return }
        let directory = Self.writableDirectory(near: item.url)
        let destination = Self.uniqueURL(in: directory, name: item.url.deletingPathExtension().lastPathComponent, pathExtension: nil)
        let source = item.url
        runInBackground {
            Self.ditto(["-x", "-k", source.path, destination.path]) ? destination : nil
        }
    }

    // MARK: Internals

    private func runInBackground(_ work: @escaping @Sendable () -> URL?) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            Task { @MainActor in
                self?.isWorking = false
                if let result { self?.add(urls: [result]) }
            }
        }
    }

    private func save() {
        JSONStore.save(items, to: "shelf.json")
    }

    nonisolated private static func ditto(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func writableDirectory(near url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: directory.path) { return directory }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    nonisolated private static func uniqueURL(in directory: URL, name: String, pathExtension: String?) -> URL {
        func candidate(_ suffix: String) -> URL {
            let base = directory.appendingPathComponent(name + suffix)
            return pathExtension.map { base.appendingPathExtension($0) } ?? base
        }
        var url = candidate("")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate(" \(index)")
            index += 1
        }
        return url
    }
}

struct ShelfTabView: View {
    @EnvironmentObject private var shelf: ShelfService
    @EnvironmentObject private var state: IslandState
    @EnvironmentObject private var hero: HeroFeaturesService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("File Shelf")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(shelf.items.count) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if shelf.isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !shelf.items.isEmpty {
                    PillButton(title: hero.phoneShareURL == nil ? "Phone" : "Stop Share", symbol: "iphone.and.arrow.forward") {
                        hero.togglePhoneShare()
                    }
                    PillButton(title: "AirDrop", symbol: "airplayaudio") { shelf.airDrop(shelf.items) }
                    PillButton(title: "Zip", symbol: "archivebox") { shelf.zip(shelf.items) }
                    PillButton(title: "Reveal", symbol: "folder") { shelf.reveal(shelf.items) }
                    PillButton(title: "Clear", symbol: "trash") { shelf.clear() }
                }
            }

            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(state.isDropTargeted ? Color.accentColor : Color.white.opacity(0.25))
                    .overlay(
                        EmptyStateView(symbol: "tray.and.arrow.down",
                                       title: "Drop files on the notch",
                                       subtitle: "They stay here — even after a restart — until you drag them out.")
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("Drag items out to use them · double-click to open · right-click for more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @EnvironmentObject private var shelf: ShelfService

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 54, height: 54)
            Text(item.name)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 88)
        }
        .padding(8)
        .cardBackground(cornerRadius: 16, tint: LuminousCardTheme.violet)
        .overlay(alignment: .topTrailing) {
            Button {
                shelf.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Reveal in Finder") { shelf.reveal([item]) }
            Button("AirDrop") { shelf.airDrop([item]) }
            if item.isArchive {
                Button("Unzip") { shelf.unzip(item) }
            } else {
                Button("Compress") { shelf.zip([item]) }
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
    }
}
