import Foundation

/// Где живёт визуализация: только в открытой панели или ещё и под вырезом.
///
/// Одно свойство, и отдельный объект ради него — потому что спрашивают о нём из
/// трёх мест сразу: панель рисует плашку, настройки её переключают, модель по
/// нему решает, держать ли тап открытым. Поле в `NotchViewModel` пришлось бы
/// тащить во все три через саму модель, а этого достаточно, чтобы переключатель
/// в настройках перерисовывал всю панель.
@MainActor
final class VisualizerState: ObservableObject {
    static let pinnedKey = "visualizerPinned"

    /// Плашка у выреза: то, что играет, и спектр — без открытой панели.
    ///
    /// Сохраняется: закрепили один раз и хотят видеть это и завтра.
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey) }
    }

    init() {
        isPinned = UserDefaults.standard.bool(forKey: Self.pinnedKey)
    }
}
