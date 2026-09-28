import AppKit
import CoreImage
import SwiftUI

/// State for the photo editor: rotation, adjustments, crop, drawings and redactions.
/// All geometry is stored normalised (0…1, top-left origin) in the rotated image, so it is resolution independent.
@MainActor
final class ImageEditorModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case crop, adjust, draw, redact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .crop: return "Beskær"
            case .adjust: return "Justér"
            case .draw: return "Tegn"
            case .redact: return "Censurér"
            }
        }
    }

    enum DrawTool: String, CaseIterable, Identifiable {
        case pen, arrow, rectangle
        var id: String { rawValue }
        var title: String { self == .pen ? "Pen" : self == .arrow ? "Pil" : "Firkant" }
    }

    enum RedactStyle: String, CaseIterable, Identifiable {
        case pixelate, blur, black
        var id: String { rawValue }
        var title: String { self == .pixelate ? "Pixelér" : self == .blur ? "Slør" : "Sort" }
    }

    struct Stroke: Identifiable {
        let id = UUID()
        var tool: DrawTool
        var color: NSColor
        /// Line width as a fraction of the image width.
        var width: CGFloat
        var points: [CGPoint]
    }

    struct Redaction: Identifiable {
        let id = UUID()
        var rect: CGRect
        var style: RedactStyle
    }

    struct Adjustments: Equatable {
        var exposure = 0.0
        var brightness = 0.0
        var contrast = 1.0
        var saturation = 1.0
        var warmth = 0.0
        var highlights = 1.0
        var shadows = 0.0
        var sharpness = 0.0
    }

    let url: URL
    private let original: CIImage
    private let previewSource: CIImage
    private let ciContext = CIContext()

    @Published var mode: Mode
    @Published var rotation = 0 { didSet { crop = nil; refresh() } }
    @Published var adjustments = Adjustments() { didSet { if adjustments != oldValue { refresh() } } }
    @Published var crop: CGRect?
    @Published var cropAspect: CGFloat?
    @Published var strokes: [Stroke] = []
    @Published var redactions: [Redaction] = [] { didSet { refresh() } }
    @Published var draftStroke: Stroke?
    @Published var draftRect: CGRect?
    @Published var drawTool: DrawTool = .pen
    @Published var drawColor: Color = .red
    @Published var lineWidth: CGFloat = 0.006
    @Published var redactStyle: RedactStyle = .pixelate
    @Published private(set) var preview: NSImage?
    @Published private(set) var previewPixelSize: CGSize = .zero

    init(url: URL, mode: Mode) throws {
        self.url = url
        self.mode = mode
        let full = CIImage(cgImage: try ImageEngine.loadImage(url))
        original = full
        let longest = max(full.extent.width, full.extent.height)
        let scale = min(1, 1600 / longest)
        previewSource = full.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        refresh()
    }

    var hasChanges: Bool {
        rotation % 4 != 0 || adjustments != Adjustments() || crop != nil || !strokes.isEmpty || !redactions.isEmpty
    }

    func reset() {
        adjustments = Adjustments()
        strokes = []
        redactions = []
        rotation = 0
        crop = nil
    }

    func rotate(clockwise: Bool) {
        rotation = (rotation + (clockwise ? 1 : 3)) % 4
        strokes = []
        redactions = []
    }

    // MARK: Rendering

    private func refresh() {
        let rendered = render(previewSource, burnInRedactions: true)
        guard let cgImage = ciContext.createCGImage(rendered, from: rendered.extent) else { return }
        preview = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        previewPixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    }

    private func render(_ source: CIImage, burnInRedactions: Bool) -> CIImage {
        var image = source
        switch rotation % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let extent = image.extent
        let a = adjustments

        if a.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + a.warmth * 3500, y: 0),
            ])
        }
        if a.highlights != 1 || a.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": a.highlights, "inputShadowAmount": a.shadows,
            ])
        }
        if a.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness])
        }
        image = image.cropped(to: extent)

        if burnInRedactions {
            let side = max(extent.width, extent.height)
            for redaction in redactions {
                let rect = CGRect(
                    x: redaction.rect.minX * extent.width,
                    y: (1 - redaction.rect.maxY) * extent.height,
                    width: redaction.rect.width * extent.width,
                    height: redaction.rect.height * extent.height
                )
                let cover: CIImage
                switch redaction.style {
                case .black:
                    cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                case .pixelate:
                    cover = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(side / 45, 6), kCIInputCenterKey: CIVector(x: 0, y: 0)])
                case .blur:
                    cover = image.clampedToExtent().applyingGaussianBlur(sigma: max(side / 70, 8))
                }
                image = cover.cropped(to: rect).composited(over: image)
            }
        }
        return image
    }

    /// Renders at full resolution, draws annotations on top, crops, and saves a copy.
    func save() throws -> URL {
        let rendered = render(original, burnInRedactions: true)
        guard let base = ciContext.createCGImage(rendered, from: rendered.extent),
              let canvas = ImageEngine.makeContext(width: base.width, height: base.height)
        else { throw BumlebeeError.failed("Kunne ikke gemme billedet.") }
        let width = CGFloat(base.width), height = CGFloat(base.height)
        canvas.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip so normalised top-left coordinates map directly.
        canvas.translateBy(x: 0, y: height)
        canvas.scaleBy(x: 1, y: -1)
        for stroke in strokes {
            draw(stroke, in: canvas, size: CGSize(width: width, height: height))
        }
        guard var result = canvas.makeImage() else { throw BumlebeeError.failed("Kunne ikke gemme billedet.") }
        if let crop, crop.width > 0.01, crop.height > 0.01 {
            let pixels = CGRect(x: crop.minX * width, y: crop.minY * height, width: crop.width * width, height: crop.height * height).integral
            if let cropped = result.cropping(to: pixels) { result = cropped }
        }
        let format = ImageEngine.writableFormat(sameAs: url)
        let output = Output.url(for: url, ext: format.fileExtension, suffix: "redigeret")
        try ImageEngine.write(result, to: output, format: format, quality: max(Prefs.imageQuality, 0.9), metadata: ImageEngine.metadata(url))
        return output
    }

    private func draw(_ stroke: Stroke, in context: CGContext, size: CGSize) {
        let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = points.first else { return }
        let lineWidth = max(stroke.width * size.width, 1)
        context.saveGState()
        context.setStrokeColor(stroke.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch stroke.tool {
        case .pen:
            context.move(to: first)
            points.dropFirst().forEach { context.addLine(to: $0) }
            context.strokePath()
        case .rectangle:
            guard let last = points.last else { break }
            context.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            guard let last = points.last else { break }
            for segment in ArrowGeometry.segments(from: first, to: last, headLength: lineWidth * 4) {
                context.move(to: segment.0)
                context.addLine(to: segment.1)
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: Gestures (points arrive normalised)

    func dragChanged(start: CGPoint, current: CGPoint) {
        switch mode {
        case .crop:
            crop = constrainedRect(from: start, to: current)
        case .draw:
            if var stroke = draftStroke {
                if drawTool == .pen { stroke.points.append(current) } else { stroke.points = [start, current] }
                draftStroke = stroke
            } else {
                draftStroke = Stroke(tool: drawTool, color: NSColor(drawColor), width: lineWidth, points: [start, current])
            }
        case .redact:
            draftRect = rect(from: start, to: current)
        case .adjust:
            break
        }
    }

    func dragEnded() {
        if let stroke = draftStroke { strokes.append(stroke) }
        if let rect = draftRect, rect.width > 0.005, rect.height > 0.005 {
            redactions.append(Redaction(rect: rect, style: redactStyle))
        }
        draftStroke = nil
        draftRect = nil
        if let crop, crop.width < 0.01 || crop.height < 0.01 { self.crop = nil }
    }

    func undo() {
        switch mode {
        case .draw: if !strokes.isEmpty { strokes.removeLast() }
        case .redact: if !redactions.isEmpty { redactions.removeLast() }
        case .crop: crop = nil
        case .adjust: adjustments = Adjustments()
        }
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let clampedEnd = CGPoint(x: min(max(end.x, 0), 1), y: min(max(end.y, 0), 1))
        return CGRect(x: min(start.x, clampedEnd.x), y: min(start.y, clampedEnd.y), width: abs(clampedEnd.x - start.x), height: abs(clampedEnd.y - start.y))
    }

    private func constrainedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        guard let aspect = cropAspect, previewPixelSize.width > 0 else { return rect(from: start, to: end) }
        // Convert the pixel aspect ratio into normalised units.
        let normalizedAspect = aspect * previewPixelSize.height / previewPixelSize.width
        var width = abs(end.x - start.x)
        var height = width / normalizedAspect
        if height > abs(end.y - start.y), abs(end.y - start.y) > 0 {
            height = abs(end.y - start.y)
            width = height * normalizedAspect
        }
        let x = end.x >= start.x ? start.x : start.x - width
        let y = end.y >= start.y ? start.y : start.y - height
        return CGRect(x: x, y: y, width: width, height: height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

enum ArrowGeometry {
    /// The shaft and the two barbs of an arrow.
    static func segments(from start: CGPoint, to end: CGPoint, headLength: CGFloat) -> [(CGPoint, CGPoint)] {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread))
        let right = CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread))
        return [(start, end), (end, left), (end, right)]
    }
}

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                EditorCanvas(model: model)
                    .frame(minWidth: 520, minHeight: 420)
                    .background(Color(white: 0.12))
                Divider()
                sidebar
                    .frame(width: 250)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.mode) {
                ForEach(ImageEditorModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .labelsHidden()
            Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("Rotér mod uret")
            Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("Rotér med uret")
            Spacer()
            Button("Nulstil") { model.reset() }
                .disabled(!model.hasChanges)
            Button("Gem kopi") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.honeyDeep)
                .disabled(!model.hasChanges)
        }
        .padding(12)
    }

    @ViewBuilder
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.mode {
                case .crop: cropControls
                case .adjust: adjustControls
                case .draw: drawControls
                case .redact: redactControls
                }
            }
            .padding(16)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Træk en ramme over billedet.").font(.callout).foregroundStyle(.secondary)
            Text("Format").font(.headline)
            let options: [(String, CGFloat?)] = [("Fri", nil), ("1:1", 1), ("4:3", 4 / 3), ("3:2", 3 / 2), ("16:9", 16 / 9), ("9:16", 9 / 16), ("4:5", 4 / 5)]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button(option.0) { model.cropAspect = option.1; model.crop = nil }
                        .buttonStyle(.bordered)
                        .tint(model.cropAspect == option.1 ? Theme.honeyDeep : nil)
                }
            }
            Button("Fjern beskæring") { model.crop = nil }
                .disabled(model.crop == nil)
        }
    }

    private var adjustControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider("Eksponering", value: $model.adjustments.exposure, range: -2...2, neutral: 0)
            slider("Lysstyrke", value: $model.adjustments.brightness, range: -0.5...0.5, neutral: 0)
            slider("Kontrast", value: $model.adjustments.contrast, range: 0.5...1.5, neutral: 1)
            slider("Mætning", value: $model.adjustments.saturation, range: 0...2, neutral: 1)
            slider("Varme", value: $model.adjustments.warmth, range: -1...1, neutral: 0)
            slider("Højlys", value: $model.adjustments.highlights, range: 0...1, neutral: 1)
            slider("Skygger", value: $model.adjustments.shadows, range: -1...1, neutral: 0)
            slider("Skarphed", value: $model.adjustments.sharpness, range: 0...2, neutral: 0)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: "%+.2f", value.wrappedValue - neutral))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { value.wrappedValue = neutral } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(value.wrappedValue == neutral)
            }
            Slider(value: value, in: range)
                .tint(Theme.honeyDeep)
        }
    }

    private var drawControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Værktøj", selection: $model.drawTool) {
                ForEach(ImageEditorModel.DrawTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ColorPicker("Farve", selection: $model.drawColor)
            VStack(alignment: .leading) {
                Text("Stregtykkelse").font(.callout)
                Slider(value: $model.lineWidth, in: 0.002...0.03).tint(Theme.honeyDeep)
            }
            HStack {
                Button("Fortryd") { model.undo() }.disabled(model.strokes.isEmpty)
                Button("Ryd") { model.strokes = [] }.disabled(model.strokes.isEmpty)
            }
        }
    }

    private var redactControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Træk over det, der skal skjules. Censureringen brændes ind i kopien og kan ikke fjernes igen.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Stil", selection: $model.redactStyle) {
                ForEach(ImageEditorModel.RedactStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Fortryd") { model.undo() }.disabled(model.redactions.isEmpty)
                Button("Ryd") { model.redactions = [] }.disabled(model.redactions.isEmpty)
            }
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

/// The image with live overlays for crop, drawings and redactions.
private struct EditorCanvas: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        GeometryReader { proxy in
            let frame = fittedFrame(in: proxy.size)
            ZStack(alignment: .topLeading) {
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                Canvas { context, _ in
                    drawOverlays(in: &context, frame: frame)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.dragChanged(start: normalize(value.startLocation, in: frame), current: normalize(value.location, in: frame))
                    }
                    .onEnded { _ in model.dragEnded() }
            )
        }
        .padding(20)
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        let image = model.previewPixelSize
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(size.width / image.width, size.height / image.height)
        let fitted = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func normalize(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: min(max((point.x - frame.minX) / frame.width, 0), 1), y: min(max((point.y - frame.minY) / frame.height, 0), 1))
    }

    private func denormalize(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
    }

    private func drawOverlays(in context: inout GraphicsContext, frame: CGRect) {
        let strokes = model.strokes + (model.draftStroke.map { [$0] } ?? [])
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
            guard let first = points.first, let last = points.last else { continue }
            var path = Path()
            switch stroke.tool {
            case .pen:
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
            case .rectangle:
                path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            case .arrow:
                for segment in ArrowGeometry.segments(from: first, to: last, headLength: max(stroke.width * frame.width, 1) * 4) {
                    path.move(to: segment.0)
                    path.addLine(to: segment.1)
                }
            }
            context.stroke(path, with: .color(Color(nsColor: stroke.color)), style: StrokeStyle(lineWidth: max(stroke.width * frame.width, 1), lineCap: .round, lineJoin: .round))
        }

        if model.mode == .redact {
            for redaction in model.redactions {
                context.stroke(Path(denormalize(redaction.rect, in: frame)), with: .color(Theme.honey), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        if let draft = model.draftRect {
            let rect = denormalize(draft, in: frame)
            context.fill(Path(rect), with: .color(Theme.honey.opacity(0.25)))
            context.stroke(Path(rect), with: .color(Theme.honey), lineWidth: 1.5)
        }

        if let crop = model.crop {
            let rect = denormalize(crop, in: frame)
            var outside = Path(frame)
            outside.addRect(rect)
            context.fill(outside, with: .color(.black.opacity(model.mode == .crop ? 0.55 : 0.35)), style: FillStyle(eoFill: true))
            context.stroke(Path(rect), with: .color(Theme.honey), lineWidth: 2)
            if model.mode == .crop {
                // Rule-of-thirds guides.
                var guides = Path()
                for fraction in [1.0 / 3, 2.0 / 3] {
                    guides.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                    guides.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                    guides.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                    guides.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                }
                context.stroke(guides, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
            }
        }
    }
}
