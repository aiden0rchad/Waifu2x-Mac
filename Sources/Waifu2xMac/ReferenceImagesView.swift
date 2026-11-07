import CoreImage
import SwiftUI
import UpscaleCore

struct ReferenceImagesView: View {
    @Bindable var workspace: Workspace
    @State private var editing: ReferenceImage?
    @FocusState private var editingDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Character Details").font(.callout)
            TextField("Character Details",
                text: Binding(get: { workspace.options.restore.characterDetails }, set: {
                    workspace.options.restore.characterDetails = String($0.prefix(200))
                }), prompt: Text("e.g. purple eyes, light blue hair, red horns"), axis: .vertical)
                .labelsHidden().lineLimit(2...4).textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Character Details").focused($editingDetails)
                .onChange(of: editingDetails) { _, focused in
                    if !focused {
                        workspace.options.restore.characterDetails = workspace.options.restore.characterDetails
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            Text("Eye colour, hair, anything AI should keep.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 8) {
            Text("References").font(.callout)
            HStack(spacing: 6) {
                ForEach(workspace.references, id: \.url) { reference in
                    Button { editing = reference } label: {
                        ReferenceThumbnail(reference: reference)
                            .overlay(alignment: .bottomTrailing) {
                                if reference.crop != nil {
                                    Image(systemName: "crop").font(.caption2).padding(2)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Crop \(reference.url.lastPathComponent)")
                    .contextMenu {
                        Button("Crop…") { editing = reference }
                        Button("Remove", role: .destructive) { workspace.removeReference(reference.url) }
                    }
                }
                if workspace.references.count < 4 {
                    Button(action: workspace.chooseReferences) {
                        Image(systemName: "plus").frame(width: 52, height: 52)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Add References")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { Color.clear.contentShape(Rectangle()) }
            .dropDestination(for: URL.self) { urls, _ in
                guard !workspace.isExporting else { return false }
                let images = urls.filter { $0.isFileURL && MediaKind(url: $0) == .image }
                workspace.addReferences(images)
                return !images.isEmpty
            }
            Text("Same character. Crop to the face for better eyes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(workspace.isExporting)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                ReferenceCropSheet(reference: editing) { crop in
                    workspace.setReferenceCrop(crop, for: editing.url)
                }
            }
        }
    }
}

private struct ReferenceThumbnail: View {
    let reference: ReferenceImage
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 52, height: 52)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: reference) {
            image = await referencePreview(reference, maxSide: 104)
        }
    }
}

private struct ReferenceCropSheet: View {
    let reference: ReferenceImage
    let save: (CGRect?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var crop: CGRect?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crop Reference").font(.headline)
            Text("Drag to draw. Move the box or drag a corner to resize.").font(.caption).foregroundStyle(.secondary)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .overlay {
                        RegionSelection(region: crop, label: "Face crop") { crop = $0 }
                    }
                    .frame(width: CGFloat(image.width), height: CGFloat(image.height))
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else if failed {
                Text("Cannot read reference image.").foregroundStyle(.red)
            } else { ProgressView().frame(width: 300, height: 200) }
            HStack {
                Button("Use Whole Image") { crop = nil }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(crop); dismiss() }.keyboardShortcut(.defaultAction).disabled(image == nil)
            }
        }
        .padding(20)
        .task {
            crop = reference.crop
            image = await referencePreview(ReferenceImage(url: reference.url), maxSide: 600)
            failed = image == nil
        }
    }
}

// Decode, orient, crop and render off the main actor; no large NSImage decoding during layout.
private func referencePreview(_ reference: ReferenceImage, maxSide: CGFloat) async -> CGImage? {
    await Task.detached {
        guard let image = CIImage(contentsOf: reference.url, options: [.applyOrientationProperty: true]),
              let rect = try? reference.pixelRect(in: Dimensions(width: Int(image.extent.width), height: Int(image.extent.height))) else { return nil }
        let cropped = image.cropped(to: CGRect(x: image.extent.minX + rect.minX,
            y: image.extent.maxY - rect.maxY, width: rect.width, height: rect.height))
        let normalized = cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
        let scale = min(1, maxSide / max(rect.width, rect.height))
        let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard !Task.isCancelled else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(small, from: small.extent)
    }.value
}
