import SwiftUI

/// Закреплённая плашка под вырезом: что играет и как это звучит.
///
/// Живёт в свёрнутой чёлке, на том же месте, где приезжают объявления, и по тем
/// же правилам: рисунок растёт, а область, которую панель забирает у указателя,
/// остаётся размером с вырез. Отсюда главное её свойство — она не мешает.
/// Наведение на вырез открывает Cyclop поверх неё, как и раньше; нажатие мимо
/// выреза уходит в меню-бар, а не в плашку.
///
/// Кнопок здесь нет намеренно. Всё, чем плашкой управляют — открепить,
/// переключить трек, — лежит на домашней поверхности, в одном наведении отсюда.
/// Строку под вырезом читают боковым зрением, и мишени в ней читаться так не
/// могут.
struct PinnedBar: View {
    @ObservedObject var media: MediaController
    @ObservedObject var audio: AudioTap

    var body: some View {
        HStack(spacing: 9) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                Text(media.track?.title ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = media.track?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            // Пока тап не открыт, спектра нет вовсе: плоская линия на его месте
            // выглядит поломкой, а не выключенной настройкой.
            if audio.isRunning {
                Spectrum(bands: audio.bands, maxBars: 14)
                    .frame(width: 150, height: 18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        ZStack {
            Theme.surface
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
