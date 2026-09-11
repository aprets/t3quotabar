// Derived from CodexBar, MIT license. See PROVENANCE.md.
// Source revision: 7ba403f26df6965b118f157c8b9883f5d5836a57
import AppKit

/// Card rows draw their own selection state. Keeping AppKit's parallel highlight hidden also
/// prevents newer menu implementations from painting a native selection behind the custom view.
final class MenuCardMenuItem: NSMenuItem {
    override var isHighlighted: Bool {
        false
    }
}
