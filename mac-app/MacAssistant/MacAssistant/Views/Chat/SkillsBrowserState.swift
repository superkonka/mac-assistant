import Foundation

@MainActor
final class SkillsBrowserState: ObservableObject {
    static let shared = SkillsBrowserState()

    @Published var selectedPanelRawValue: String = "内置"

    private init() {}
}
