import Defaults
import SwiftUI

protocol Preferences: Equatable, Hashable, Codable, Defaults.Serializable {}

// --- ADDED: The memory key for our new Three Finger Swipe setting ---
extension Defaults.Keys {
    static let enableWindowSwitcherSwipe = Key<Bool>("enableWindowSwitcherSwipe", default: true)
}
