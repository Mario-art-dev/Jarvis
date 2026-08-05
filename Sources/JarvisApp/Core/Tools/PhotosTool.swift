import Foundation
import Photos
import Vision
import UIKit

/// Reads photo library metadata, and — when a content_query is given — runs
/// Apple's on-device Vision classifier (VNClassifyImageRequest) over the
/// matching photos to find ones showing a subject like "dog" or "beach".
/// Everything runs locally on the phone, no network, no extra model to ship.
///
/// Content search works through the library newest-first under a wall-clock
/// budget rather than a fixed photo count, so an ordinary library gets
/// covered completely while a very large one degrades to "the most recent N,
/// and it says so" instead of blowing the server's tool-call timeout.
struct PhotosTool: JarvisTool {
    let name = "search_photos"
    let description = "Busca fotos en la galería por rango de fechas, favoritas o capturas de pantalla. Si se da content_query, además clasifica el contenido (ej. 'dog', 'beach', 'car') sobre las fotos que cumplan el filtro."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": ["type": "string", "enum": ["all", "recent", "favorites", "screenshots", "today"]],
            "content_query": [
                "type": "string",
                "description": "Opcional: palabra en inglés que describe el contenido a buscar (ej. 'dog', 'cat', 'beach', 'car'), ya que el clasificador de Apple usa etiquetas en inglés. Traduce el término del usuario al inglés antes de llamar a la herramienta."
            ]
        ],
        "required": ["filter"]
    ]

    /// Ceiling on how many photos one content search will classify. High
    /// enough that a normal library gets covered end to end, with
    /// `scanBudget` (not this) doing the real protecting on huge ones.
    private let maxContentScan = 4000

    /// Wall-clock budget for classification. The server gives search_photos
    /// 60s before it gives up on the phone, so this stops comfortably short
    /// and returns partial results — saying honestly how far it got beats
    /// timing out with nothing to show.
    private let scanBudget: TimeInterval = 40

    /// Photos classified concurrently. Fetching each thumbnail is mostly
    /// waiting on Photos, so overlapping them is what makes scanning
    /// thousands (rather than ~120) feasible inside the budget.
    private let batchSize = 8

    func execute(input: [String: Any]) async throws -> String {
        let status = await requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw ToolError.permissionDenied("acceso a Fotos")
        }

        let filter = (input["filter"] as? String) ?? "recent"
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
            // "recent" and "all" both fetch the whole library; they differ
            // only in intent, and the sort above already puts newest first.
            break
        }

        // Deliberately no fetchLimit: it would cap `count` itself, so a
        // library with 5.000 favourites reported however many the caller
        // happened to ask for. The count should be the real one.
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        guard let contentQuery, !contentQuery.isEmpty else {
            return "He encontrado \(assets.count) fotos (\(filter)) en tu galería."
        }

        let needle = contentQuery.lowercased()
        let total = assets.count
        let ceiling = min(total, maxContentScan)
        let deadline = Date().addingTimeInterval(scanBudget)
        var matches = 0
        var scanned = 0

        while scanned < ceiling, Date() < deadline {
            let end = min(scanned + batchSize, ceiling)
            let batch = (scanned..<end).map { assets.object(at: $0) }
            let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                for asset in batch {
                    group.addTask { await Self.classify(asset: asset, matches: needle) }
                }
                var out: [Bool] = []
                for await result in group { out.append(result) }
                return out
            }
            scanned += results.count
            matches += results.filter { $0 }.count
        }

        // Say plainly when the whole library wasn't covered, rather than
        // implying a "no encontré nada" verdict over photos never looked at.
        let coverage = scanned >= total
            ? "las \(total) fotos"
            : "las \(scanned) fotos más recientes (de \(total))"

        if matches == 0 {
            return "He revisado \(coverage) y no he encontrado ninguna que parezca de \"\(contentQuery)\"."
        }
        return "He encontrado \(matches) fotos que parecen de \"\(contentQuery)\", revisando \(coverage)."
    }

    private static func classify(asset: PHAsset, matches query: String) async -> Bool {
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

    private static func thumbnail(for asset: PHAsset) async -> UIImage? {
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
