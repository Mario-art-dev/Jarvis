import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// A picked image ready to attach to the next message to Claude.
struct ImageAttachment {
    let data: Data
    let mediaType: String // "image/jpeg"
}

/// Downscales to Claude's recommended max dimension and re-encodes as JPEG,
/// so a full-resolution photo doesn't blow up the WebSocket message or the
/// prompt's token cost.
private func jpegAttachment(from image: UIImage) -> ImageAttachment? {
    let maxDimension: CGFloat = 1568
    let scale = min(1, maxDimension / max(image.size.width, image.size.height))
    let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let resized = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }
    return ImageAttachment(data: data, mediaType: "image/jpeg")
}

/// "Fototeca" — lets the user pick one or more existing photos.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPicked: ([ImageAttachment]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 5
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }
            let group = DispatchGroup()
            var attachments: [ImageAttachment] = []
            let lock = NSLock()

            for result in results {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage, let attachment = jpegAttachment(from: image) else { return }
                    lock.lock()
                    attachments.append(attachment)
                    lock.unlock()
                }
            }
            group.notify(queue: .main) {
                self.parent.onPicked(attachments)
            }
        }
    }
}

/// "Cámara" — takes a single new photo.
struct CameraCapturePicker: UIViewControllerRepresentable {
    let onPicked: (ImageAttachment) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapturePicker
        init(_ parent: CameraCapturePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let attachment = jpegAttachment(from: image) {
                parent.onPicked(attachment)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

/// "Archivo" — picks image files from Files/iCloud Drive/third-party providers.
struct FileImagePicker: UIViewControllerRepresentable {
    let onPicked: ([ImageAttachment]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FileImagePicker
        init(_ parent: FileImagePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else {
                parent.onCancel()
                return
            }
            let attachments: [ImageAttachment] = urls.compactMap { url in
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
                return jpegAttachment(from: image)
            }
            parent.onPicked(attachments)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
