import Foundation
import Photos

/// Reads photo library metadata. iOS has no on-device "find photos of a dog"
/// content search without shipping our own Vision/CoreML model, so this
/// version searches by date range, favorites and screenshots — a solid,
/// honest subset rather than a fake "search anything" promise.
struct PhotosTool: JarvisTool {
    let name = "search_photos"
    let description = "Busca fotos en la galería por rango de fechas, favoritas o capturas de pantalla, y devuelve cuántas hay."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": ["type": "string", "enum": ["recent", "favorites", "screenshots", "today"]],
            "limit": ["type": "integer", "description": "Máximo de resultados a contar, por defecto 20"]
        ],
        "required": ["filter"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        let status = await requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw ToolError.permissionDenied("acceso a Fotos")
        }

        let filter = (input["filter"] as? String) ?? "recent"
        let limit = (input["limit"] as? Int) ?? 20

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit

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

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        return "He encontrado \(assets.count) fotos (\(filter)) en tu galería."
    }

    private func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
