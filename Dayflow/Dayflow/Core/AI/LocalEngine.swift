import Foundation

enum LocalEngine: String, CaseIterable, Identifiable, Codable {
  case ollama
  case lmstudio
  case custom

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .ollama: return String(localized: "Ollama")
    case .lmstudio: return String(localized: "LM Studio")
    case .custom: return String(localized: "Custom")
    }
  }

  var defaultBaseURL: String {
    switch self {
    case .ollama: return "http://localhost:11434"
    case .lmstudio: return "http://localhost:1234"
    case .custom: return "http://localhost:11434"
    }
  }
}
