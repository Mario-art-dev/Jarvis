import Foundation
import Photos
import Vision
import UIKit

/// Reads photo library metadata, and — when a content_query is given — runs
/// Apple's on-device Vision classifier (VNClassifyImageRequest) over a
/// capped batch of recent photos to find ones matching a subject like "dog"
/// or "beach". Everything runs locally on the phone, no network, no extra
/// model to ship. It only scans a bounded recent window (not the whole
/// library) to stay fast and keep the server's tool-call timeout happy.
struct PhotosTool: JarvisTool {
    let name = "search_photos"
    let description = "Busca fotos en la galería por rango de fechas, favoritas o capturas de pantalla. Si se da content_query, además clasifica el contenido (ej. 'dog', 'beach', 'car') sobre las fotos más recientes que cumplan el filtro."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": ["type": "string", "enum": ["recent", "favorites", "screenshots", "today"]],
            "limit": ["type": "integer", "description": "Máximo de resultados a contar, por defecto 20"],
            "content_query": [
                "type": "string",
                "description": "Opcional: palabra en inglés que describe el contenido a buscar (ej. 'dog', 'cat', 'beach', 'car'), ya que el clasificador de Apple usa etiquetas en inglés. Traduce el término del usuario al inglés antes de llamar a la herramienta."
            ]
        ],
        "required": ["filter"]
    ]

    /// How many of the most recent matching photos we're willing to run
    /// through Vision in one call — keeps this well under the server's
    /// tool-call timeout even on an older iPhone.
    private let maxContentScan = 120

    func execute(input: [String: Any]) async throws -> String {
        let status = await requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw ToolError.permissionDenied("acceso a Fotos")
        }

        let filter = (input["filter"] as? String) ?? "recent"
        let limit = (input["limit"] as? Int) ?? 20
        let contentQuery = (input["content_query"] as? String)?.trimmingCharacters(in: .whitespaces)

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        switch filter {
        case "favorites":
            options.predicate = NSPredicate(format: "favorite == YES")
        case "screenshots":
            options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        case "today":
            let start = Calendar.current.startOfDay(for: Date())
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        default:
            break
        }

        guard let contentQuery, !contentQuery.isEmpty else {
            options.fetchLimit = limit
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            return "He encontrado \(assets.count) fotos (\(filter)) en tu galería."
        }

        options.fetchLimit = maxContentScan
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var matches = 0
        var scanned = 0

        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            scanned += 1
            if await classify(asset: asset, matches: contentQuery.lowercased()) {
                matches += 1
            }
        }

        if matches == 0 {
            return "He revisado \(scanned) fotos recientes (\(filter)) y no he encontrado ninguna que parezca de \"\(contentQuery)\"."
        }
        return "He encontrado \(matches) fotos (de las \(scanned) más recientes que revisé, filtro \(filter)) que parecen de \"\(contentQuery)\"."
    }

    private func classify(asset: PHAsset, matches query: String) async -> Bool {
        guard let image = await thumbnail(for: asset), let cgImage = image.cgImage else { return false }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return false
        }

        guard let observations = request.results else { return false }
        return observations.contains { observation in
            observation.confidence > 0.15 && observation.identifier.lowercased().contains(query)
        }
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
