import AppKit

/// A Space of the panel's own, shown over every desktop.
///
/// `.stationary` keeps a window still while the desktop is revealed, but the
/// window still belongs to the desktops: a swipe between them, or into a
/// full-screen app, slides it away with the wallpaper and brings it back once
/// the swipe settles. Over a real notch that went unseen while the folded
/// panel painted nothing; the island paints, and it vanished mid-swipe. A
/// window that joins this Space before it is first shown belongs to no
/// desktop, so no desktop change moves it — the way the menu bar stays put.
///
/// Private window-server calls, looked up at run time. Without them the
/// panel behaves exactly as before.
@MainActor
final class OverlaySpace {
    private typealias Connection = UInt32
    private typealias Create = @convention(c) (Connection, Int32, CFDictionary?) -> UInt64
    private typealias Spaces = @convention(c) (Connection, CFArray) -> Int32
    private typealias Windows = @convention(c) (Connection, CFArray, CFArray) -> Void

    static let shared = OverlaySpace()

    private let connection: Connection
    private let space: UInt64
    private let add: Windows?
    private let remove: Windows?

    private init?() {
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        guard let main = symbol("CGSMainConnectionID"),
              let create = symbol("CGSSpaceCreate"),
              let show = symbol("CGSShowSpaces"),
              let add = symbol("CGSAddWindowsToSpaces"),
              let remove = symbol("CGSRemoveWindowsFromSpaces") else { return nil }
        let connection = unsafeBitCast(main, to: (@convention(c) () -> Connection).self)()
        guard connection != 0 else { return nil }
        // Flag 1: a plain overlay. Other values have Finder draw the desktop
        // icons into it.
        let space = unsafeBitCast(create, to: Create.self)(connection, 1, nil)
        guard space != 0 else { return nil }
        _ = unsafeBitCast(show, to: Spaces.self)(connection, [NSNumber(value: space)] as CFArray)
        self.connection = connection
        self.space = space
        self.add = unsafeBitCast(add, to: Windows.self)
        self.remove = unsafeBitCast(remove, to: Windows.self)
    }

    /// Before the window is first ordered in: one already on screen would
    /// keep its desktop as well, and slide with it anyway.
    func adopt(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        add?(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    /// The Space lives as long as the app; only the window leaves.
    func release(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        remove?(connection, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }
}
