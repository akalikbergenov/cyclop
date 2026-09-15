import SwiftUI

/// Спектр играющего: столбики по настоящему звуку.
///
/// Рисуется без анимации SwiftUI намеренно — данные и так приходят тридцать раз
/// в секунду, а наложенная поверх них интерполяция превратила бы удар в плавное
/// всплытие, то есть ровно в ту неправду, из-за которой декоративные
/// «эквалайзеры» и видно.
///
/// Один `Canvas` вместо двадцати восьми `Capsule`. Дело не в красоте кода: на
/// тридцати кадрах в секунду каждый кадр перекладывал `HStack` из двадцати
/// восьми вью, а здесь тот же кадр — один проход рисования.
struct Spectrum: View {
    let bands: [Float]
    /// Потолок числа столбиков. В узкой плашке двадцать восемь полос
    /// вырождаются в штриховку по два пункта: видно, что полоса есть, и не
    /// видно, какая она. Там они складываются попарно — подробностей меньше,
    /// зато каждый столбик читается.
    var maxBars = Int.max

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let values = Self.fit(bands, into: maxBars)
            guard !values.isEmpty else { return }
            let gap: CGFloat = 2
            let width = max((size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count), 1)
            let floorHeight: CGFloat = 2

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let height = max(floorHeight, CGFloat(value) * size.height)
                let bar = CGRect(x: x, y: size.height - height, width: width, height: height)
                context.fill(
                    Path(roundedRect: bar, cornerRadius: min(width, height) / 2),
                    // Яркость идёт за высотой: тихая полоса не должна спорить за
                    // внимание с громкой, иначе спектр читается как забор.
                    with: .color(.white.opacity(0.28 + Double(value) * 0.62)))
            }
        }
    }

    /// Складывает соседние полосы, пока их не станет не больше `limit`.
    ///
    /// Берётся максимум группы, а не среднее: усреднение съедает удар — как раз
    /// то единственное, ради чего на спектр и смотрят.
    private static func fit(_ bands: [Float], into limit: Int) -> [Float] {
        guard limit > 0, bands.count > limit else { return bands }
        let group = Int((Double(bands.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: bands.count, by: group).map { start in
            bands[start..<min(start + group, bands.count)].max() ?? 0
        }
    }
}
