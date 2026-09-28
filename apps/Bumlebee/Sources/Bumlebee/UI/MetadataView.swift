import AppKit
import SwiftUI

/// Shows everything Bumlebee can read about a file, lets you edit the common fields, and strips metadata.
struct MetadataView: View {
    let url: URL
    @State private var sections: [MetadataSection] = []
    @State private var fields: [EditableField] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !fields.isEmpty {
                        Section("Redigér") {
                            ForEach($fields) { $field in
                                TextField(field.label, text: $field.value)
                            }
                            Button("Gem kopi med ændringer") { saveEdits() }
                        }
                    }
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    if !row.key.isEmpty {
                                        Text(row.key)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 170, alignment: .leading)
                                    }
                                    Text(row.value)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Kopiér alt") { copyAll() }
                Spacer()
                if FileKind.of(url) == .image {
                    Button("Fjern kun lokation") { strip(onlyLocation: true) }
                }
                Button("Fjern al metadata") { strip(onlyLocation: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.honeyDeep)
                    .disabled(![.image, .video, .audio, .pdf].contains(FileKind.of(url)))
            }
            .padding(12)
        }
        .task {
            sections = await MetadataEngine.read(url)
            fields = await MetadataEngine.editableFields(url)
            isLoading = false
        }
    }

    private func copyAll() {
        let text = sections.map { section in
            ([section.title.uppercased()] + section.rows.map { $0.key.isEmpty ? $0.value : "\($0.key): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func strip(onlyLocation: Bool) {
        let url = self.url
        JobRunner.shared.run(title: onlyLocation ? "Fjerner lokation" : "Fjerner metadata", files: [url]) { context in
            [try await MetadataEngine.strip(url, onlyLocation: onlyLocation, context: context)]
        }
    }

    private func saveEdits() {
        let url = self.url
        let fields = self.fields
        JobRunner.shared.run(title: "Gemmer metadata", files: [url]) { context in
            [try await MetadataEngine.write(url, fields: fields, context: context)]
        }
    }
}
