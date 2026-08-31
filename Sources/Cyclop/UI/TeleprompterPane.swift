import SwiftUI

/// The script, scrolling under the camera.
///
/// Two states rather than two tabs: the script is pasted in once and read many
/// times, so reading is what the tab opens onto and editing is a step aside.
struct TeleprompterPane: View {
    @ObservedObject var prompter: TeleprompterStore
    /// Whether the panel holds the keyboard, so the editor can follow it.
    @Binding var wantsKeyboard: Bool

    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if editing || prompter.script.isEmpty {
                editor
            } else {
                reader
            }
            controls
        }
        .padding(.top, 2)
        .onChange(of: wantsKeyboard) { _, wants in
            focused = wants && editing
            // The keyboard going elsewhere means attention went with it.
            if !wants { editing = false }
        }
        // Arriving puts the script back at the top. A take starts at the
        // beginning, and mid-take nobody is switching tabs — so the only way
        // to arrive on a script left halfway is to have finished with it, and
        // the one thing that must not happen then is opening onto the blank
        // space past the last line with no way to tell why it is blank.
        .onAppear { prompter.rewind() }
        .onDisappear { prompter.suspend() }
    }

    // MARK: - Reading

    /// The line being read sits in the middle of the window, not at the top:
    /// what is coming is as much of the job as what is here, and a reader with
    /// nothing below the current line has nowhere to look ahead to.
    private var reader: some View {
        GeometryReader { outer in
            ScrollView(.vertical, showsIndicators: false) {
                Text(prompter.script)
                    .font(.system(size: prompter.fontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(prompter.fontSize * 0.34)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    // Half a window of blank above and below, so the first line
                    // starts at the reading mark and the last one can reach it.
                    .padding(.top, outer.size.height / 2)
                    .padding(.bottom, outer.size.height / 2)
                    .background(
                        GeometryReader { inner in
                            Color.clear.onAppear {
                                prompter.contentHeight = inner.size.height
                                prompter.viewportHeight = outer.size.height
                            }
                            .onChange(of: inner.size.height) { _, height in
                                prompter.contentHeight = height
                            }
                        }
                    )
                    .offset(y: -prompter.offset)
            }
            .scrollDisabled(true)
            .overlay(alignment: .top) { fade(.top) }
            .overlay(alignment: .bottom) { fade(.bottom) }
            .onAppear { prompter.viewportHeight = outer.size.height }
            .onChange(of: outer.size.height) { _, height in prompter.viewportHeight = height }
        }
    }

    /// Where the eye rests, and the only thing that says so.
    ///
    /// There was a tick in the margin here as well, marking the line to read.
    /// It went: the first person to see it asked what it was, which is the
    /// whole verdict on a mark whose entire job is being understood without
    /// explanation. The fade already does that job — the band in the middle is
    /// the only fully lit text on screen, so the eye coming back from the lens
    /// lands on it without being pointed at anything.
    ///
    /// Text does not end at an edge, it dissolves into one — a hard cut reads
    /// as the script being clipped rather than continuing.
    private func fade(_ edge: VerticalEdge) -> some View {
        LinearGradient(
            colors: [.black, .black.opacity(0)],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: 34)
        .allowsHitTesting(false)
    }

    // MARK: - Editing

    private var editor: some View {
        TextEditor(text: $prompter.script)
            .font(.system(size: 13, design: .rounded))
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focused)
            .padding(.horizontal, 14)
            .overlay(alignment: .topLeading) {
                if prompter.script.isEmpty {
                    // Offsets match where the editor actually puts its first
                    // line, not where the rounded rectangle starts: 14 is the
                    // padding above, 5 is the text container's own line
                    // fragment padding. Getting this wrong parks the caret
                    // above and left of the placeholder it is supposed to
                    // stand in front of.
                    Text("Paste the script here")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 14 + 5)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            if editing || prompter.script.isEmpty {
                Spacer()
                Button(prompter.script.isEmpty ? "Ready" : "Done") {
                    editing = false
                    wantsKeyboard = false
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(prompter.script.isEmpty ? Theme.tertiary : .white)
                .disabled(prompter.script.isEmpty)
            } else {
                Button { prompter.rewind() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(NotchButtonStyle(size: 26))

                Button { prompter.toggle() } label: {
                    Image(systemName: prompter.isRunning ? "pause.fill" : "play.fill")
                }
                .buttonStyle(NotchButtonStyle(size: 32, prominent: true))

                speedControl

                Spacer()

                sizeControl

                Button {
                    prompter.pause()
                    editing = true
                    wantsKeyboard = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(NotchButtonStyle(size: 26))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(height: 44)
    }

    /// A slider rather than presets: the right pace depends on the script and
    /// on the person, and it is found by moving it while reading, not chosen
    /// from a list beforehand.
    private var speedControl: some View {
        HStack(spacing: 7) {
            Slider(value: $prompter.speed, in: 0.3...3.0)
                .controlSize(.mini)
                .tint(.white.opacity(0.7))
                .frame(width: 96)
            Text(String(format: "%.1f×", prompter.speed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, alignment: .leading)
        }
    }

    private var sizeControl: some View {
        HStack(spacing: 4) {
            Button { prompter.fontSize = max(18, prompter.fontSize - 2) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .buttonStyle(NotchButtonStyle(size: 26))
            Button { prompter.fontSize = min(64, prompter.fontSize + 2) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .buttonStyle(NotchButtonStyle(size: 26))
        }
    }
}
