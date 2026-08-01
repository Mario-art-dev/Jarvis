import Foundation
import UIKit

/// Opens Safari on a web search. Jarvis can't read the results back (Apple
/// doesn't allow reading another app's content), but it can trigger the
/// search instantly so you land straight on the results page.
struct WebSearchTool: JarvisTool {
    let name = "web_search"
    let description = "Abre una búsqueda en Safari para una consulta dada. Úsalo cuando el usuario pida buscar algo en internet."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Texto a buscar"]
        ],
        "required": ["query"]
    ]

    func execute(input: [String: Any]) async throws -> String {
        guard let query = input["query"] as? String, !query.isEmpty else {
            throw ToolError.invalidInput("query")
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else {
            throw ToolError.invalidInput("query")
        }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
        return "He abierto la búsqueda de \"\(query)\" en Safari."
    }
}
