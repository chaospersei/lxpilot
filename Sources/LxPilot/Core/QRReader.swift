import AppKit
import Vision
import UniformTypeIdentifiers

/// QR codes out of pictures: a saved image, a screenshot on the clipboard.
enum QRReader {
    static func payloads(in image: NSImage) -> [String] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        // A config with AmneziaWG parameters makes a dense code; small screenshots of it read only enlarged.
        let side = max(source.width, source.height)
        for scale in [1, 2, 4] where scale == 1 || side * scale <= 4096 {
            guard let flat = flatten(source, scale: scale) else { continue }
            let found = detect(flat)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func detect(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }

    /// On white: a code saved with a transparent background is otherwise black on black.
    private static func flatten(_ image: CGImage, scale: Int) -> CGImage? {
        let width = image.width * scale, height = image.height * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

/// What the "add profile" sheet takes besides typed text: files and pictures.
enum ImportSource {
    private static func isPicture(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// One text file as it is, or pictures with QR codes (several — an Amnezia series).
    static func text(fromFiles urls: [URL]) throws -> String {
        guard let first = urls.first else { throw AppError("Файл не выбран.") }
        if urls.count == 1, !isPicture(first) {
            guard let data = try? Data(contentsOf: first) else { throw AppError("Не удалось прочитать файл.") }
            if let text = String(data: data, encoding: .utf8) { return text }
            guard let image = NSImage(data: data) else {
                throw AppError("Файл не является ни текстом, ни картинкой с QR-кодом.")
            }
            return try text(fromQR: QRReader.payloads(in: image))
        }
        var payloads: [String] = []
        for url in urls {
            guard let image = NSImage(contentsOf: url) else {
                throw AppError("Несколько файлов можно выбрать, только если это картинки с частями одного QR-кода.")
            }
            payloads += QRReader.payloads(in: image)
        }
        return try text(fromQR: payloads)
    }

    static func text(fromImage image: NSImage) throws -> String {
        try text(fromQR: QRReader.payloads(in: image))
    }

    static func text(fromQR payloads: [String]) throws -> String {
        guard !payloads.isEmpty else { throw AppError("На картинке не найден QR-код.") }
        if let link = try AmneziaLink.link(fromQRParts: payloads) { return link }
        if let conf = payloads.first(where: WireGuardConf.looksLikeConf) { return conf }
        return payloads.joined(separator: "\n")
    }
}
