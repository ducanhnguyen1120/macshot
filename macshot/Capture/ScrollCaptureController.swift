import Cocoa
import Vision

// MARK: - Supporting types

nonisolated final class ScrollCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

nonisolated struct ScrollCaptureConfig: Sendable {
    let rect: CGRect
    let excludeWindowID: CGWindowID
}

nonisolated struct ScrollStrip {
    let image: CGImage
    let topY: Int
}

nonisolated struct ScrollAnalysisState: Sendable {
    var headerHeight = 0
    var headerDetectionDone = false
    var headerDetectionSamples = 0
    var rightMarginPx = 0
    var rightMarginDetected = false
    var frozenDetectionEnabled = true

    mutating func detectRightMargin(current: CGImage, previous: CGImage) {
        guard let scrollbarWidth = ScrollFrameAnalyzer.scrollbarWidth(current: current, previous: previous) else { return }
        rightMarginDetected = true
        if scrollbarWidth >= 3 && scrollbarWidth <= 40 {
            rightMarginPx = scrollbarWidth + 4
        }
    }

    mutating func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard shiftPx > 5 else { return }
        guard let frozenRows = ScrollFrameAnalyzer.frozenTopRows(
            current: current, previous: previous, rightMarginPx: rightMarginPx) else { return }

        let h = current.height
        guard frozenRows < h else { return }

        if frozenRows >= 10 && frozenRows < (h * 6 / 10) {
            headerDetectionSamples += 1
            if headerDetectionSamples == 1 {
                headerHeight = frozenRows
                headerDetectionDone = true
            } else {
                if abs(frozenRows - headerHeight) <= 5 {
                    headerHeight = min(headerHeight, frozenRows)
                } else {
                    headerHeight = 0
                }
                headerDetectionDone = true
            }
        } else if frozenRows < 10 {
            headerDetectionDone = true
        }
    }
}

nonisolated struct ScrollFrameOutcome {
    enum Kind {
        case registrationFailed
        case noMovement
        case belowMinimum
        case merged(strip: CGImage, newRows: Int, overlap: Int, preview: CGImage?)
    }
    var state: ScrollAnalysisState
    var kind: Kind
}

// MARK: - ScrollCaptureController

/// Scroll capture engine. Everything heavy (window capture, settle checks,
/// Vision registration, strip extraction, preview + final compositing) runs on
/// a background queue; the main actor only holds state and applies results.
///
/// - Frames are compared by raw pixel bytes (no TIFF encoding).
/// - Only the newly scrolled rows are kept per step (`ScrollStrip`); the full
///   tall image is composited once when the session ends, so cost per step is
///   independent of how long the capture already is.
/// - The live preview is a small downscaled image that grows incrementally.
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0
    private var isCancelled: Bool = false
    private var didStop: Bool = false

    var stitchedPixelSize: CGSize {
        CGSize(width: CGFloat(frameWidth), height: CGFloat(totalRows))
    }

    var estimatedTotalHeight: CGFloat {
        CGFloat(totalRows) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    private let captureQueue = DispatchQueue(label: "macshot.scrollcapture", qos: .userInitiated)
    private let cancelFlag = ScrollCancelFlag()
    private var config = ScrollCaptureConfig(rect: .zero, excludeWindowID: kCGNullWindowID)

    // Frame / stitch state
    private var shotA: CGImage?
    private var strips: [ScrollStrip] = []
    private var totalRows: Int = 0
    private var frameWidth: Int = 0
    private var frameColorSpace: CGColorSpace?
    private var analysisState = ScrollAnalysisState()
    private var previewImage: CGImage?
    private var previewScale: CGFloat = 1
    private let previewPixelWidth: CGFloat = 400

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8
    private var hasScrolledOnce: Bool = false
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6

    // Scroll monitors (manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.12
    private var lastCaptureTime: TimeInterval = 0
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25
    private var pendingSettle: Bool = false

    private var isCapturing: Bool = false

    private var targetAppPID: pid_t = 0
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive, !isCancelled else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        analysisState.frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        resolveTargetWindow()
        resolveTargetApp()

        config = ScrollCaptureConfig(rect: captureRectCG, excludeWindowID: excludedWindowIDs.first ?? kCGNullWindowID)
        let cfg = config
        let cancel = cancelFlag
        let firstFrame: CGImage? = await onQueue {
            Self.settledFrame(cfg, cancel: cancel, initialWaitMicros: 10_000, initialDelayMicros: 0, fallbackToLast: true)
        }
        guard !isCancelled else { return }
        guard let firstFrame else {
            onSessionDone?(nil)
            return
        }

        isActive = true
        shotA = firstFrame
        strips = [ScrollStrip(image: firstFrame, topY: 0)]
        totalRows = firstFrame.height
        frameWidth = firstFrame.width
        frameColorSpace = firstFrame.colorSpace
        analysisState = ScrollAnalysisState(frozenDetectionEnabled: analysisState.frozenDetectionEnabled)
        matchNotFoundCount = 0
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        frozenTopHeight = 0
        stripCount = 1
        previewScale = min(1, previewPixelWidth / CGFloat(max(1, firstFrame.width)))
        previewImage = nil

        let scale = previewScale
        let preview: CGImage? = await onQueue {
            Self.appendedPreview(old: nil, strip: firstFrame, newRows: firstFrame.height, scale: scale)
        }
        guard isActive else { return }
        previewImage = preview
        emitPreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    func stopSession() {
        guard !didStop, isActive || !isCancelled else { return }
        guard isActive else {
            isCancelled = true
            cancelFlag.set()
            onSessionDone?(nil)
            return
        }
        isActive = false
        didStop = true
        cancelFlag.set()
        tearDownInput()

        let snapshot = strips
        let width = frameWidth
        let rows = totalRows
        let cs = frameColorSpace
        let scale = backingScale
        Task { [weak self] in
            guard let self else { return }
            let cg: CGImage? = await self.onQueue {
                Self.composite(strips: snapshot, width: width, totalRows: rows, colorSpace: cs)
            }
            let finalImage = cg.map {
                NSImage(cgImage: $0, size: CGSize(width: CGFloat($0.width) / scale,
                                                  height: CGFloat($0.height) / scale))
            }
            self.strips = []
            self.onSessionDone?(finalImage)
        }
    }

    func cancelSession() {
        isCancelled = true
        isActive = false
        cancelFlag.set()
        tearDownInput()
        strips = []
    }

    private func tearDownInput() {
        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
    }

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            captureQueue.async { cont.resume(returning: work()) }
        }
    }

    // MARK: - Target window/app management

    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Background capture helpers

    nonisolated private static func captureFrame(_ cfg: ScrollCaptureConfig) -> CGImage? {
        CGWindowListCreateImage(
            cfg.rect, [.optionOnScreenBelowWindow], cfg.excludeWindowID,
            [.boundsIgnoreFraming, .bestResolution])
    }

    /// Grabs frames until two consecutive ones are byte-identical (content has
    /// stopped rendering). Runs entirely on the capture queue.
    nonisolated private static func settledFrame(
        _ cfg: ScrollCaptureConfig, cancel: ScrollCancelFlag,
        initialWaitMicros: useconds_t, initialDelayMicros: useconds_t, fallbackToLast: Bool
    ) -> CGImage? {
        if initialDelayMicros > 0 { usleep(initialDelayMicros) }
        var previousData: CFData?
        var previousCG: CGImage?
        var wait = initialWaitMicros

        for _ in 0..<30 {
            if cancel.isSet { return nil }
            guard let cg = captureFrame(cfg), let data = cg.dataProvider?.data else {
                usleep(30_000)
                continue
            }
            if let previousData, CFEqual(previousData, data) { return cg }
            previousData = data
            previousCG = cg
            usleep(wait)
            wait = min(wait * 3 / 2, 80_000)
        }
        return fallbackToLast ? previousCG : nil
    }

    nonisolated private static func process(
        current: CGImage, previous: CGImage, state inState: ScrollAnalysisState,
        previewOld: CGImage?, previewScale: CGFloat
    ) -> ScrollFrameOutcome {
        var state = inState

        if !state.rightMarginDetected {
            state.detectRightMargin(current: current, previous: previous)
        }

        guard let offset = visionShift(current: current, previous: previous, state: state) else {
            return ScrollFrameOutcome(state: state, kind: .registrationFailed)
        }
        let offsetPx = Int(round(offset))
        guard offsetPx > 0 else { return ScrollFrameOutcome(state: state, kind: .noMovement) }

        let minShift = current.height / 10
        guard offsetPx >= minShift else { return ScrollFrameOutcome(state: state, kind: .belowMinimum) }

        if state.frozenDetectionEnabled && !state.headerDetectionDone {
            state.detectHeader(current: current, previous: previous, shiftPx: offsetPx)
        }

        // Bias by -1px so strips overlap by one row; the newer frame wins the
        // seam row, hiding sub-pixel rendering differences.
        let newRows = min(max(1, offsetPx - 1), current.height)
        let hasHeader = state.headerDetectionDone && state.headerHeight > 0
        let overlap = hasHeader ? 0 : min(1, current.height - newRows)
        let rows = newRows + overlap
        guard let strip = renderStrip(frame: current, rows: rows) else {
            return ScrollFrameOutcome(state: state, kind: .registrationFailed)
        }
        let preview = appendedPreview(old: previewOld, strip: strip, newRows: newRows, scale: previewScale)
        return ScrollFrameOutcome(state: state, kind: .merged(strip: strip, newRows: newRows, overlap: overlap, preview: preview))
    }

    /// Copies the bottom `rows` rows of `frame` into their own bitmap so the
    /// strip does not keep the whole captured frame alive.
    nonisolated private static func renderStrip(frame: CGImage, rows: Int) -> CGImage? {
        let w = frame.width
        guard rows > 0, rows <= frame.height,
              let crop = frame.cropping(to: CGRect(x: 0, y: frame.height - rows, width: w, height: rows)),
              let ctx = CGContext(data: nil, width: w, height: rows, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: rows))
        return ctx.makeImage()
    }

    nonisolated private static func appendedPreview(old: CGImage?, strip: CGImage, newRows: Int, scale: CGFloat) -> CGImage? {
        let pw = old?.width ?? max(1, Int(round(CGFloat(strip.width) * scale)))
        let addH = max(1, Int(round(CGFloat(newRows) * scale)))
        let stripH = max(addH, Int(round(CGFloat(strip.height) * scale)))
        let oldH = old?.height ?? 0
        let totalH = oldH + addH
        guard let ctx = CGContext(data: nil, width: pw, height: totalH, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        if let old { ctx.draw(old, in: CGRect(x: 0, y: addH, width: pw, height: oldH)) }
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: pw, height: stripH))
        return ctx.makeImage()
    }

    nonisolated private static func composite(strips: [ScrollStrip], width: Int, totalRows: Int, colorSpace: CGColorSpace?) -> CGImage? {
        guard width > 0, totalRows > 0,
              let ctx = CGContext(data: nil, width: width, height: totalRows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        for strip in strips {
            let h = strip.image.height
            ctx.draw(strip.image, in: CGRect(x: 0, y: totalRows - strip.topY - h, width: width, height: h))
        }
        return ctx.makeImage()
    }

    // MARK: - Frame cycle

    /// One capture → register → stitch cycle. `settle` waits for pixel-stable
    /// frames (used after scrolling stops and in auto-scroll); otherwise grabs
    /// whatever is on screen right now. Returns true when a strip was added.
    private func runCycle(settle: Bool) async -> Bool {
        let cfg = config
        let cancel = cancelFlag
        let current: CGImage? = await onQueue {
            settle
                ? Self.settledFrame(cfg, cancel: cancel, initialWaitMicros: 12_000, initialDelayMicros: 50_000, fallbackToLast: false)
                : Self.captureFrame(cfg)
        }
        guard isActive, let current else { return false }
        guard let previous = shotA else {
            shotA = current
            return false
        }

        let state = analysisState
        let oldPreview = previewImage
        let scale = previewScale
        let outcome: ScrollFrameOutcome = await onQueue {
            Self.process(current: current, previous: previous, state: state, previewOld: oldPreview, previewScale: scale)
        }
        guard isActive else { return false }

        analysisState = outcome.state
        frozenTopHeight = outcome.state.headerDetectionDone ? CGFloat(outcome.state.headerHeight) / backingScale : 0

        switch outcome.kind {
        case .registrationFailed:
            shotA = current
            if settle {
                consecutiveZeroShifts += 1
                if hasScrolledOnce && consecutiveZeroShifts >= maxZeroShiftsBeforeStop { stopSession() }
            }
            return false
        case .noMovement:
            shotA = current
            return false
        case .belowMinimum:
            return false
        case .merged(let strip, let newRows, let overlap, let preview):
            consecutiveZeroShifts = 0
            hasScrolledOnce = true
            strips.append(ScrollStrip(image: strip, topY: totalRows - overlap))
            totalRows += newRows
            shotA = current
            stripCount += 1
            previewImage = preview
            emitPreview()
            onStripAdded?(stripCount)
            return true
        }
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount)
        }
    }

    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int) async {
        while isActive && autoScrollActive {
            for _ in 0..<burstCount {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: -linesPerTick, wheel2: 0, wheel3: 0) {
                    event.post(tap: .cghidEventTap)
                }
            }

            if isCapturing {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            isCapturing = true
            let success = await runCycle(settle: true)
            isCapturing = false

            if !success {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            if maxScrollHeight > 0, totalRows >= maxScrollHeight {
                stopSession()
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll()
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onManualScrollEvent()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent()
            return event
        }
    }

    private func onManualScrollEvent() {
        guard isActive else { return }

        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settledCapture() }
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval, !isCapturing else { return }
        lastCaptureTime = now
        launchCycle(settle: false)
    }

    private func settledCapture() {
        guard isActive else { return }
        if isCapturing {
            pendingSettle = true
            return
        }
        launchCycle(settle: true)
    }

    private func launchCycle(settle: Bool) {
        isCapturing = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.runCycle(settle: settle)
            self.isCapturing = false
            if self.pendingSettle, self.isActive {
                self.pendingSettle = false
                self.launchCycle(settle: true)
            }
        }
    }

    // MARK: - Vision shift detection

    nonisolated private static func visionShift(current: CGImage, previous: CGImage, state: ScrollAnalysisState) -> CGFloat? {
        var curImg = current
        var prevImg = previous
        let maxCropY = current.height / 5
        let cropY = state.headerDetectionDone ? min(state.headerHeight, maxCropY) : 0
        let cropW = current.width - state.rightMarginPx
        let cropH = current.height - cropY
        if cropY > 0 || state.rightMarginPx > 0 {
            guard cropH > 20 && cropW > 20 else { return nil }
            let cropRect = CGRect(x: 0, y: cropY, width: cropW, height: cropH)
            guard let cc = current.cropping(to: cropRect),
                  let pc = previous.cropping(to: cropRect) else { return nil }
            curImg = cc
            prevImg = pc
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevImg)
        let handler = VNImageRequestHandler(cgImage: curImg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let shift = obs.alignmentTransform.ty
        return ScrollFrameAnalyzer.validatedVerticalShift(shift, frameHeight: curImg.height)
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let cg = previewImage, let callback = onPreviewUpdated else { return }
        callback(NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height)))
    }
}
