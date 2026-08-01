import Foundation
import Contacts

struct ContactsTool: JarvisTool {
    let name = "search_contacts"
    let description = "Busca contactos por nombre y devuelve nombre y teléfono si existen."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Nombre o parte del nombre a buscar"]
        ],
        "required": ["name"]
    ]

    private let store = CNContactStore()

    func execute(input: [String: Any]) async throws -> String {
        guard let name = input["name"] as? String, !name.isEmpty else {
            throw ToolError.invalidInput("name")
        }
        guard try await requestAccess() else {
            throw ToolError.permissionDenied("acceso a Contactos")
        }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        if contacts.isEmpty {
            return "No encontré ningún contacto llamado \(name)."
        }

        let summary = contacts.prefix(5).map { contact -> String in
            let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            let phone = contact.phoneNumbers.first?.value.stringValue ?? "sin teléfono"
            return "\(fullName) (\(phone))"
        }.joined(separator: "; ")

        return "Encontré: \(summary)."
    }

    private func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
