import Cocoa

class TrackpadGestureManager {
    static let shared = TrackpadGestureManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Threshold to register a swipe (3% of trackpad surface)
    private let MIN_SWIPE_DISTANCE: Double = 0.03 
    private var startPositions = [String: NSPoint]()
    
    // Callback: deltaX/Y will be -1 or 1 based on swipe direction
    var onSwipe: ((_ deltaX: Int, _ deltaY: Int) -> Void)?
    
    func startObserving() {
        guard eventTap == nil else { return }
        
        let eventMask = (1 << CGEventType.gesture.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap, // Captures raw HID data ahead of WindowServer
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                let manager = Unmanaged<TrackpadGestureManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleGesture(event: event, type: type)
            },
            userInfo: userInfo
        )
        
        if let eventTap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }
    
    func stopObserving() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            self.eventTap = nil
            self.runLoopSource = nil
        }
        startPositions.removeAll()
    }
    
    private func handleGesture(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type.rawValue == NSEvent.EventType.gesture.rawValue {
            guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            
            let touches = nsEvent.allTouches()
            let activeTouches = touches.filter { !$0.isResting && ($0.phase == .began || $0.phase == .moved) }
            
            // Require exactly 3 fingers
            if activeTouches.count == 3 {
                processTouches(activeTouches)
                return nil // Absorb event so macOS doesn't switch spaces
            } else {
                startPositions.removeAll()
            }
        }
        return Unmanaged.passUnretained(event)
    }
    
    private func processTouches(_ touches: Set<NSTouch>) {
        // Record initial positions for new touches
        if touches.contains(where: { startPositions["\($0.identity)"] == nil }) {
            for touch in touches {
                startPositions["\(touch.identity)"] = touch.normalizedPosition
            }
            return
        }
        
        // Calculate average movement delta
        var totalDelta = NSPoint(x: 0, y: 0)
        for touch in touches {
            guard let start = startPositions["\(touch.identity)"] else { continue }
            totalDelta.x += (touch.normalizedPosition.x - start.x)
            totalDelta.y += (touch.normalizedPosition.y - start.y)
        }
        
        let averageX = totalDelta.x / CGFloat(touches.count)
        let averageY = totalDelta.y / CGFloat(touches.count)
        
        let absX = abs(averageX)
        let absY = abs(averageY)
        let maxIsX = absX >= absY
        
        // Deadzone check
        guard (maxIsX ? absX : absY) > MIN_SWIPE_DISTANCE else { return }
        
        // Reset the baseline so the swipe can repeat if they keep moving
        for touch in touches {
            if maxIsX {
                startPositions["\(touch.identity)"]?.x = touch.normalizedPosition.x
            } else {
                startPositions["\(touch.identity)"]?.y = touch.normalizedPosition.y
            }
        }
        
        let deltaX = maxIsX ? (averageX < 0 ? -1 : 1) : 0
        let deltaY = !maxIsX ? (averageY < 0 ? -1 : 1) : 0
        
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            self.onSwipe?(deltaX, deltaY)
        }
    }
}