import PDFKit
import SwiftUI

/// Reorder, rotate and delete PDF pages, then save a copy.
@MainActor
final class PDFOrganizerModel: ObservableObject {
    struct PageItem: Identifiable {
        let id = UUID()
        let page: PDFPage
        let number: Int
        let thumbnail: NSImage
        var extraRotation = 0
    }

    let url: URL
    private let document: PDFDocument
    @Published var pages: [PageItem]
    @Published var selection = Set<UUID>()

    init(url: URL) throws {
        self.url = url
        document = try PDFEngine.open(url)
        var items: [PageItem] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            items.append(PageItem(page: page, number: index + 1, thumbnail: page.thumbnail(of: NSSize(width: 120, height: 160), for: .cropBox)))
        }
        pages = items
    }

    var isChanged: Bool {
        pages.count != document.pageCount
            || pages.enumerated().contains { $0.offset + 1 != $0.element.number || $0.element.extraRotation != 0 }
    }

    func move(from source: IndexSet, to destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    func delete(at offsets: IndexSet) {
        pages.remove(atOffsets: offsets)
    }

    func deleteSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
    }

    func rotateSelected() {
        for index in pages.indices where selection.contains(pages[index].id) {
            pages[index].extraRotation = (pages[index].extraRotation + 90) % 360
        }
    }

    func reverse() {
        pages.reverse()
    }

    func save() throws -> URL {
        guard !pages.isEmpty else { throw BumlebeeError.failed("Der er ingen sider tilbage.") }
        let result = PDFDocument()
        for item in pages {
            guard let copy = item.page.copy() as? PDFPage else { continue }
            copy.rotation = (copy.rotation + item.extraRotation) % 360
            result.insert(copy, at: result.pageCount)
        }
        let output = Output.url(for: url, ext: "pdf", suffix: "organiseret")
        try PDFEngine.save(result, to: output)
        return output
    }
}

struct PDFOrganizerView: View {
    @ObservedObject var model: PDFOrganizerModel
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.pages) { item in
                    HStack(spacing: 14) {
                        Image(nsImage: item.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 80)
                            .rotationEffect(.degrees(Double(item.extraRotation)))
                            .shadow(radius: 1)
                        VStack(alignment: .leading) {
                            Text("Side \(item.number)").font(.headline)
                            if item.extraRotation != 0 {
                                Text("Roteret \(item.extraRotation)°").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(item.id)
                }
                .onMove { model.move(from: $0, to: $1) }
                .onDelete { model.delete(at: $0) }
            }
            Divider()
            HStack {
                Button("Rotér valgte", systemImage: "rotate.right") { model.rotateSelected() }
                    .disabled(model.selection.isEmpty)
                Button("Slet valgte", systemImage: "trash") { model.deleteSelected() }
                    .disabled(model.selection.isEmpty)
                Button("Vend rækkefølge", systemImage: "arrow.up.arrow.down") { model.reverse() }
                Spacer()
                Button("Gem kopi") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.honeyDeep)
                    .disabled(!model.isChanged)
            }
            .padding(12)
        }
        .safeAreaInset(edge: .top) {
            Text("Træk siderne for at ændre rækkefølgen. \(model.pages.count) sider.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private func save() {
        do {
            let output = try model.save()
            if Prefs.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([output]) }
            onClose()
        } catch {
            Alerts.error(title: "Kunne ikke gemme", message: error.localizedDescription)
        }
    }
}
