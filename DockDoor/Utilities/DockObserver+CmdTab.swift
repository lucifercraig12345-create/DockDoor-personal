import ApplicationServices
import Cocoa
import Defaults

// AXObserver callback for Cmd+Tab switcher changes
func handleCmdTabSwitcherNotification(observer _: AXObserver, element _: AXUIElement, notificationName: CFString, context: UnsafeMutableRawPointer?) {
    DockObserver.activeInstance?.processCmdTabSwitcherEvent(notificationName)
}

extension DockObserver {
    // MARK: - Cmd+Tab Switcher Monitoring

    func teardownCmdTabObserver() {
        if let observer = cmdTabObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        cmdTabObserver = nil
        stopCmdTabPolling()
        DockObserver.isCmdTabSwitcherActive = false
        
        // --- ADDED: Stop observing trackpad gestures when switcher closes ---
        TrackpadGestureManager.shared.stopObserving()
    }

    // MARK: - On-Demand Polling (Event-Driven)

    func startCmdTabPolling() {
        guard Defaults[.enableCmdTabEnhancements] else { return }
        guard cmdTabObserver == nil else { return }

        attemptCmdTabSubscription()

        if cmdTabObserver == nil {
            cmdTabPollingTimer?.invalidate()
            cmdTabPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                attemptCmdTabSubscription()

                if cmdTabObserver != nil {
                    timer.invalidate()
                    cmdTabPollingTimer = nil
                }
            }
        }
    }

    func stopCmdTabPolling() {
        cmdTabPollingTimer?.invalidate()
        cmdTabPollingTimer = nil
    }

    private func attemptCmdTabSubscription() {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }

        let dockAppPID = dockApp.processIdentifier
        let dockAppElement = AXUIElementCreateApplication(dockAppPID)

        guard let processSwitcherList = findCmdTabSwitcherElement(in: dockAppElement) else {
            return
        }

        stopCmdTabPolling()
        subscribeToProcessSwitcher(processSwitcherList: processSwitcherList, dockAppPID: dockAppPID)
        processCmdTabSwitcherChanged()
    }

    private func subscribeToProcessSwitcher(processSwitcherList: AXUIElement, dockAppPID: pid_t) {
        if cmdTabObserver != nil {
            teardownCmdTabObserver()
        }

        guard AXObserverCreate(dockAppPID, handleCmdTabSwitcherNotification, &cmdTabObserver) == .success,
              let cmdTabObserver
        else {
            return
        }

        do {
            try processSwitcherList.subscribeToNotification(cmdTabObserver, kAXSelectedChildrenChangedNotification as String) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(cmdTabObserver), .commonModes)
            }
            try processSwitcherList.subscribeToNotification(cmdTabObserver, kAXUIElementDestroyedNotification as String)
            DockObserver.isCmdTabSwitcherActive = true
            
            // --- ADDED: Start observing trackpad gestures when switcher opens (if setting is ON) ---
            if Defaults[.enableWindowSwitcherSwipe] {
                TrackpadGestureManager.shared.startObserving()
            }
            
        } catch {
            // Ignore subscription errors
        }
    }

    func processCmdTabSwitcherEvent(_ notification: CFString) {
        guard Defaults[.enableCmdTabEnhancements] else { return }

        let notif = notification as String

        if notif == (kAXSelectedChildrenChangedNotification as String) {
            processCmdTabSwitcherChanged()
            return
        }

        if notif == (kAXUIElementDestroyedNotification as String) {
            teardownCmdTabObserver()
            return
        }
    }

    func processCmdTabSwitcherChanged() {
        guard Defaults[.enableCmdTabEnhancements] else { return }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }

        let dockAppElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        guard let selectedItem = getSelectedCmdTabItem(dockElement: dockAppElement) else {
            _ = findCmdTabSwitcherElement(in: dockAppElement)
            return
        }

        let resolvedApp = selectedItem.app
        let appName = resolvedApp?.localizedName ?? selectedItem.title ?? "Unknown"
        let bundleId = resolvedApp?.bundleIdentifier ?? selectedItem.bundleId

        var cachedWindows: [WindowInfo] = []
        if let app = resolvedApp {
            cachedWindows = WindowUtil.readCachedWindows(for: app.processIdentifier, sortedBy: .cmdTab)
        }

        let shouldIgnoreSingleWindowApp = Defaults[.ignoreAppsWithSingleWindowInCmdTab] && cachedWindows.count == 1

        if Defaults[.showWindowsFromCurrentSpaceOnlyInCmdTab] {
            cachedWindows = WindowUtil.filterWindowsByCurrentSpace(cachedWindows)
        }

        if Defaults[.showWindowsFromCurrentMonitorOnlyInCmdTab] {
            cachedWindows = WindowUtil.filterWindowsByCurrentMonitor(cachedWindows)
        }

        if !Defaults[.includeHiddenWindowsInCmdTab] {
            cachedWindows = cachedWindows.filter { !$0.isHidden && !$0.isMinimized }
        }

        let elementPos = try? selectedItem.element.position()
        let bestScreen = if let elementPos { NSScreen.screenFromQuartzPoint(elementPos) } else { NSScreen.main! }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if shouldIgnoreSingleWindowApp {
                previewCoordinator.hideWindow()
                return
            }

            if cachedWindows.isEmpty {
                if let app = resolvedApp, Defaults[.showWindowlessAppsInCmdTab] {
                    cachedWindows = [WindowInfo.windowlessEntry(for: app)]
                } else {
                    previewCoordinator.hideWindow()
                    return
                }
            }

            let initialIndex = Defaults[.cmdTabAutoSelectFirstWindow] ? 0 : nil
            previewCoordinator.showWindow(
                appName: appName,
                windows: cachedWindows,
                mouseLocation: DockObserver.getMousePosition(),
                mouseScreen: bestScreen,
                dockItemElement: selectedItem.element,
                overrideDelay: true,
                centeredHoverWindowState: .none,
                onWindowTap: { [weak self] in
                    self?.hideWindowAndResetLastApp()
                },
                bundleIdentifier: bundleId,
                bypassDockMouseValidation: true,
                dockPositionOverride: .cmdTab,
                initialIndex: initialIndex
            )
        }

        if let app = resolvedApp {
            let appPID = app.processIdentifier
            let screenOrigin = bestScreen.frame.origin

            Task.detached { [weak self] in
                guard let self else { return }

                do {
                    var windows = try await WindowUtil.getActiveWindows(of: app, context: .cmdTab)

                    if Defaults[.showWindowsFromCurrentSpaceOnlyInCmdTab] {
                        windows = WindowUtil.filterWindowsByCurrentSpace(windows)
                    }

                    if Defaults[.showWindowsFromCurrentMonitorOnlyInCmdTab] {
                        windows = WindowUtil.filterWindowsByCurrentMonitor(windows)
                    }

                    if !Defaults[.includeHiddenWindowsInCmdTab] {
                        windows = windows.filter { !$0.isHidden && !$0.isMinimized }
                    }

                    let freshWindows = windows

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard let screen = screenOrigin.screen() else { return }

                        previewCoordinator.mergeWindowsIfNeeded(
                            appPID,
                            windows: freshWindows,
                            dockPosition: .cmdTab,
                            bestGuessMonitor: screen
                        )
                    }
                } catch {
                    DebugLogger.log("DockObserver+CmdTab", details: "Failed to fetch windows for Cmd+Tab: \(error)")
                }
            }
        }
    }

    // MARK: - Cmd+Tab Session State

    /// Cached state tracking whether the Cmd+Tab switcher is currently active.
    /// Updated by the AXObserver when the switcher appears/disappears.
    static var isCmdTabSwitcherActive = false

    private func getSelectedCmdTabItem(dockElement: AXUIElement) -> (element: AXUIElement, app: NSRunningApplication?, bundleId: String?, title: String?)? {
        guard let appSwitcherElement = findCmdTabSwitcherElement(in: dockElement) else {
            return nil
        }

        var selectedChildren: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appSwitcherElement, kAXSelectedChildrenAttribute as CFString, &selectedChildren)

        if result == .success,
           let selectedArray = selectedChildren as? [AXUIElement],
           let selectedElement = selectedArray.first
        {
            var resolvedApp: NSRunningApplication?
            var resolvedBundleId: String?
            var resolvedTitle: String?

            if let appURL = try? selectedElement.attribute(kAXURLAttribute as String, NSURL.self)?.absoluteURL,
               let bundle = Bundle(url: appURL),
               let bundleIdentifier = bundle.bundleIdentifier
            {
                resolvedBundleId = bundleIdentifier
                resolvedApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
            }

            if resolvedApp == nil {
                do {
                    if let title = try selectedElement.title(), !title.isEmpty {
                        resolvedTitle = title
                        let allApps = NSWorkspace.shared.runningApplications
                        if let app = allApps.first(where: { $0.localizedName == title }) {
                            resolvedApp = app
                        } else {
                            let lowerTitle = title.lowercased()
                            if let app = allApps.first(where: { ($0.localizedName ?? "").lowercased().contains(lowerTitle) || lowerTitle.contains(($0.localizedName ?? "").lowercased()) }) {
                                resolvedApp = app
                            }
                        }
                        if resolvedBundleId == nil { resolvedBundleId = resolvedApp?.bundleIdentifier }
                    }
                } catch {
                    // ignore
                }
            }

            return (element: selectedElement, app: resolvedApp, bundleId: resolvedBundleId, title: resolvedTitle)
        }

        return nil
    }

    private func findCmdTabSwitcherElement(in dockElement: AXUIElement) -> AXUIElement? {
        do {
            let children = try dockElement.children() ?? []

            for child in children {
                let subrole = try? child.subrole()
                if let subrole, subrole == "AXProcessSwitcherList" {
                    return child
                }

                if let found = findCmdTabSwitcherElement(in: child) {
                    return found
                }
            }
        } catch {
            // Element might not be accessible
        }

        return nil
    }
}



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
        
        let eventMask = (1 << CGEventType.scrollWheel.rawValue) // fallback mask type
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
