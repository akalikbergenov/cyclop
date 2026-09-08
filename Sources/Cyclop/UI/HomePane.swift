import SwiftUI

/// Одна поверхность вместо трёх вкладок.
///
/// Музыка, ближайшая встреча и последние копирования — это то, на что смотрят
/// между делом, и смотреть на них по очереди незачем: пока открыт календарь,
/// не видно, что играет, а чтобы вернуть строку в буфер, надо уйти с обоих.
/// Три вкладки, которые никогда не нужны по одной, здесь лежат рядом.
///
/// Права колонка узкая намеренно. Встреча — это одна строка и отсчёт, а
/// история буфера читается по началу строки: то и другое живёт в ширине, для
/// которой музыке места хватает с запасом.
struct HomePane: View {
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @ObservedObject var audio: AudioTap

    /// Сколько копирований помещается в правую колонку под встречей.
    private let clipLimit = 3

    @State private var scrubHover = false
    /// Держится, пока тянут: полоса должна идти за пальцем, а не за часами.
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 14) {
            music
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
            aside
                .frame(width: 218)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Музыка

    @ViewBuilder
    private var music: some View {
        if let track = media.track {
            HStack(spacing: 13) {
                artwork
                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle(for: track))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                    Spacer(minLength: 4)
                    controls
                    Spacer(minLength: 4)
                    Spectrum(bands: audio.bands)
                        .frame(height: 20)
                    Spacer(minLength: 4)
                    scrubber
                }
                .frame(height: 118)
            }
            .animation(Theme.artworkAnimation, value: track.key)
        } else {
            VStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                Text(localized("Nothing is playing"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var artwork: some View {
        ZStack {
            if let image = media.artwork {
                Theme.surface
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isSquare(image) ? .fill : .fit)
                    .transition(.opacity)
            } else {
                SkeletonBox(cornerRadius: 12)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Обложки приходят в том размере, в каком их публикует источник, поэтому
    /// квадратность — вопрос о пропорции, а не о точных пикселях.
    private func isSquare(_ image: NSImage) -> Bool {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return true }
        return abs(size.width / size.height - 1) < 0.02
    }

    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { media.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)

            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 30, prominent: true))

            Button { media.next() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
        }
        // По центру колонки, а не по её левому краю: три кнопки — единственный
        // элемент здесь, который читается как группа, и прижатая влево группа
        // выглядит съехавшей, а не выровненной.
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: media.canSkip)
    }

    /// Доля, которую показывает полоса: пока тянут — та, что под пальцем.
    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 5 : 3

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    // Намеренно без анимации: перемотка должна оказаться под
                    // курсором сразу, а плавность даёт частота тиков.
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(.white)
                            .frame(width: 9, height: 9)
                            .offset(x: min(max(filled - 4.5, 0), max(width - 9, 0)))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                // Полоса тонкая, а целиться в неё приходится на ходу, поэтому
                // мишень выше самой полосы: три пикселя мышью не поймать.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { scrubHover = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            // Сначала перемотка: сбросить `scrubbing` раньше
                            // значит на кадр вернуть полосу на старое место.
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.contentAnimation, value: scrubHover)
            }
            .frame(height: 12)

            HStack {
                Text(formatTime(media.duration * progress))
                Spacer(minLength: 6)
                Text(formatTime(media.duration))
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Правая колонка

    private var aside: some View {
        VStack(alignment: .leading, spacing: 9) {
            meeting
            // Пустая история буфера не показывается вовсе: заголовок над
            // пустотой читается как поломка, а место лучше отдать встрече.
            if !clipboard.items.isEmpty {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                clips
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var meeting: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Разрешение спрашивается отсюда же. Во вкладке под объяснение
            // была целая панель; здесь есть строка и место справа от
            // заголовка — этого хватает, а вот потерять саму дверь нельзя:
            // без неё календарь навсегда остаётся закрытым.
            HStack(spacing: 6) {
                Text(localized("Calendar").uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 4)
                if calendar.access == .notRequested {
                    Button { calendar.requestAccess() } label: {
                        Text(localized("Allow"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 18)
                            .background(Capsule().fill(Theme.surfaceHover))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if let countdown {
                    Text(countdown)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            if let next = calendar.next {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(nsColor: next.calendarColor))
                        .frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(clock(next))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if next.link != nil {
                        Button { calendar.join(next) } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Theme.surfaceHover))
                        }
                        .buttonStyle(.plain)
                        .help(localized("Join"))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendarPlaceholder)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    if calendar.access == .denied {
                        Text(localized("Settings → Privacy → Calendars"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.tertiary.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 26, alignment: .topLeading)
            }
        }
    }

    private var countdown: String? {
        guard let next = calendar.next else { return nil }
        return CalendarPane.countdown(to: next, from: calendar.now).localizedCapitalized
    }

    private var calendarPlaceholder: String {
        switch calendar.access {
        case .granted: return localized("No more meetings")
        case .notRequested: return localized("The only permission")
        case .denied: return localized("Calendar access is off")
        }
    }

    private func clock(_ meeting: CalendarStore.Meeting) -> String {
        var parts = ["\(CalendarPane.clock.string(from: meeting.start))–\(CalendarPane.clock.string(from: meeting.end))"]
        if let provider = meeting.provider { parts.append(provider) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var clips: some View {
        VStack(alignment: .leading, spacing: 5) {
            eyebrow(localized("Clipboard"), trailing: "\(clipboard.items.count)")
            VStack(spacing: 2) {
                ForEach(clipboard.items.prefix(clipLimit)) { item in
                    HomeClipRow(item: item, clipboard: clipboard, privacy: privacy)
                }
            }
        }
    }

    private func eyebrow(_ title: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Строка буфера в домашней колонке: та же механика, что во вкладке, но ниже
/// и без кнопки удаления — здесь на неё нет ширины, а удалять есть где.
private struct HomeClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 12)
            SpoilerText(
                text: item.preview.replacingOccurrences(of: "\n", with: " "),
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            clipboard.copy(item)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}


/// Спектр: двадцать восемь полос по настоящему звуку.
///
/// Рисуется без анимации SwiftUI намеренно — данные и так приходят тридцать
/// раз в секунду, а наложенная поверх них интерполяция превратила бы удар в
/// плавное всплытие, то есть ровно в ту неправду, из-за которой декоративные
/// «эквалайзеры» и видно.
private struct Spectrum: View {
    let bands: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(bands.count, 1)
            let gap: CGFloat = 2
            let width = max((geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Color.white.opacity(0.28 + Double(value) * 0.62))
                        .frame(width: width, height: max(2, CGFloat(value) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
