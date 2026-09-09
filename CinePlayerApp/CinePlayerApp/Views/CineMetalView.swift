import SwiftUI
import MetalKit
import CinePlayerCore

/// Wraps an `MTKView` that draws whichever frame `playbackController` is
/// currently pointed at, using `CinePlayerCore`'s shared `CineRenderer`. The
/// view is driven manually (`isPaused = true`, `enableSetNeedsDisplay =
/// true`): a redraw only happens when the coordinator explicitly asks for
/// one, either because `documentModel.uniforms` changed or because a new
/// frame's texture finished fetching from the `DecodedFrameCache`.
struct CineMetalView: NSViewRepresentable {
    @ObservedObject var documentModel: CineDocumentModel
    @ObservedObject var playbackController: PlaybackController

    /// Claims first responder and handles transport shortcuts directly in
    /// the AppKit responder chain, rather than via `KeyEventCoordinator`'s
    /// old `NSEvent` local monitor (retired — see that class's doc
    /// comment for why).
    ///
    /// Two things were tried and verified live, in order, via an lldb
    /// breakpoint on `NSBeep`/`AudioServicesPlaySystemSound`:
    ///
    /// 1. Merely becoming first responder (`acceptsFirstResponder` +
    ///    `makeFirstResponder` below) is NOT enough on its own: a plain
    ///    `MTKView` never overrode `keyDown(with:)`, so even as first
    ///    responder its *inherited* `NSResponder.keyDown(with:)` default
    ///    implementation just forwards the event up the responder chain —
    ///    confirmed landing on `SwiftUI`'s own `NSHostingView.keyDown(with:)`
    ///    (which itself forwards further via `super` when its own SwiftUI
    ///    focus/shortcut system doesn't claim the key), which forwards again
    ///    to `-[NSWindow keyDown:]`, whose documented default behavior is to
    ///    beep when nothing claimed the key. `po [[NSApp keyWindow]
    ///    firstResponder]` at that exact breakpoint confirmed this view
    ///    genuinely *was* first responder throughout — being first responder
    ///    and actually consuming the event are different things.
    /// 2. Overriding `keyDown(with:)` here (below) and not calling `super`
    ///    for any key `KeyEventCoordinator.handle` consumes stops the beep:
    ///    confirmed via the same lldb breakpoint no longer firing for K (or
    ///    any other mapped/swallowed key) while a file is open.
    final class FocusableMTKView: MTKView {
        /// Set in `makeNSView`/`updateNSView` — needed here so
        /// `magnify(with:)`/`scrollWheel(with:)` (trackpad pinch-to-zoom and
        /// two-finger pan) can drive `CineDocumentModel`'s zoom state
        /// directly, the same "thin AppKit dispatcher, real logic lives on
        /// the model" shape `keyDown(with:)` below already uses for
        /// `KeyEventCoordinator`. `weak`: this view never owns the document
        /// model's lifetime.
        weak var documentModel: CineDocumentModel?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard let passthrough = KeyEventCoordinator.shared.handle(event) else {
                // Consumed — deliberately not calling super here is what
                // stops AppKit's default `-[NSWindow keyDown:]` NSBeep
                // fallback from ever running for this key.
                return
            }
            super.keyDown(with: passthrough)
        }

        /// A single, always-on tracking area covering the view's current
        /// bounds — `.inVisibleRect` keeps it correctly sized/positioned
        /// across layout changes without this override needing to redo that
        /// math itself. Needed because plain `mouseMoved` events are not
        /// delivered to a view at all unless something (a tracking area, or
        /// `NSWindow.acceptsMouseMovedEvents`) asks for them — this is that
        /// ask, purely so `lastKnownVideoMouseNormalizedPoint` (see
        /// `CineDocumentModel`) stays current for `zoomIn()`/`zoomOut()`'s
        /// cursor-anchoring.
        private var mouseTrackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let mouseTrackingArea {
                removeTrackingArea(mouseTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            mouseTrackingArea = area
        }

        /// Converts an event's location to this frame's own normalized
        /// (0...1, 0...1) texture space, accounting for whatever zoom/pan is
        /// currently active — `nil` if the point falls outside this view's
        /// bounds (shouldn't happen for an event this view itself received,
        /// guarded anyway since a degenerate zero-size `bounds` would
        /// otherwise divide by zero) or no document is open yet.
        ///
        /// AppKit's own coordinate space is bottom-up (y=0 at the view's
        /// bottom), the reverse of the texture-space v=0-at-top convention
        /// `tonemapVertex` uses (see that function's own doc comment) —
        /// `1 - (local.y / bounds.height)` is the flip.
        private func normalizedTexturePoint(for event: NSEvent) -> CGPoint? {
            guard let documentModel, bounds.width > 0, bounds.height > 0 else { return nil }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return nil }
            let screenNormalized = CGPoint(x: local.x / bounds.width, y: 1 - (local.y / bounds.height))
            let scale = documentModel.zoomScale
            let center = documentModel.zoomCenter
            return CGPoint(
                x: center.x + (screenNormalized.x - 0.5) / scale,
                y: center.y + (screenNormalized.y - 0.5) / scale
            )
        }

        override func mouseMoved(with event: NSEvent) {
            documentModel?.setLastKnownVideoMouseNormalizedPoint(normalizedTexturePoint(for: event))
            super.mouseMoved(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            documentModel?.setLastKnownVideoMouseNormalizedPoint(normalizedTexturePoint(for: event))
            super.mouseEntered(with: event)
        }

        // Deliberately NO `mouseExited` override clearing the point back to
        // `nil`: the toolbar's +/- buttons (and the ⌘+/⌘- menu commands)
        // live *outside* this view, so by the time a real click/keypress
        // reaches them the cursor has already, genuinely left (a real
        // continuous mouse move always fires `mouseExited` crossing a
        // tracking-area boundary, unlike this feature's own automated
        // testing, which warps the cursor directly and only surfaced this
        // via a live check, not by inspection). Clearing on exit would mean
        // "zoom in on where the mouse is" could only ever work for a pinch
        // gesture (which never leaves the view) and never for the buttons
        // the user explicitly asked for it to apply to. Simply leaving the
        // last value in place — "where the mouse *was* last, over the
        // video" — is exactly what makes cursor-anchored +/- possible at
        // all; `mouseMoved`/`mouseEntered` already keep it fully current
        // for as long as the cursor remains inside.

        /// Trackpad pinch-to-zoom, anchored at the pinch's own location (the
        /// point between your fingers stays put as you zoom, matching
        /// Photos.app) — `NSResponder.magnify(with:)` fires directly on
        /// whichever view is under the cursor, no gesture recognizer setup
        /// needed, and nothing else in this view hierarchy (no
        /// `NSScrollView`) intercepts it first. Falls back to the current
        /// center (a no-op anchor) on the practically-impossible case of the
        /// event's own location resolving outside this view.
        override func magnify(with event: NSEvent) {
            guard let documentModel else { return }
            let anchor = normalizedTexturePoint(for: event) ?? documentModel.zoomCenter
            documentModel.adjustZoom(byMagnification: event.magnification, aroundNormalizedPoint: anchor)
        }

        /// Two-finger trackpad pan (or a plain mouse scroll wheel), once
        /// zoomed in — see `CineDocumentModel.panZoom(scrollDelta:viewSize:)`
        /// for the actual math. At `zoomScale == 1` there's nothing to pan
        /// across, so the event is left to propagate normally instead of
        /// being silently swallowed for no visible effect.
        override func scrollWheel(with event: NSEvent) {
            guard let documentModel, documentModel.zoomScale > CineDocumentModel.minZoomScale else {
                super.scrollWheel(with: event)
                return
            }
            documentModel.panZoom(
                scrollDelta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                viewSize: bounds.size
            )
        }

        /// Tracks `mouseDragged`'s previous call's local position — see that
        /// method's own doc comment for why the drag is measured this way
        /// (position differences) rather than off `event.deltaX`/`deltaY`.
        private var lastDragLocation: CGPoint?

        /// Click-and-drag panning, once zoomed in — the mouse equivalent of
        /// two-finger scroll, for anyone without (or not using) a trackpad.
        /// At `zoomScale == 1` there's nothing to pan across, so the click
        /// is left to propagate normally (there is no other left-click
        /// behavior on the video today, but this keeps that door open)
        /// instead of being swallowed for no visible effect.
        override func mouseDown(with event: NSEvent) {
            guard let documentModel, documentModel.zoomScale > CineDocumentModel.minZoomScale else {
                super.mouseDown(with: event)
                return
            }
            lastDragLocation = convert(event.locationInWindow, from: nil)
        }

        /// Measured as the delta between this call's and the previous call's
        /// `convert(event.locationInWindow, from: nil)` — deliberately NOT
        /// `event.deltaX`/`deltaY` (the raw-hardware-motion fields
        /// `scrollWheel`'s `scrollingDeltaX`/`Y` equivalent would be), which
        /// live-testing (via a position-warping automated drag) showed can
        /// read as zero on an absolute-positioned synthetic event even
        /// though the pointer genuinely moved — tracking position directly
        /// sidesteps that regardless of the event's origin.
        override func mouseDragged(with event: NSEvent) {
            guard let documentModel, documentModel.zoomScale > CineDocumentModel.minZoomScale else {
                super.mouseDragged(with: event)
                return
            }
            let location = convert(event.locationInWindow, from: nil)
            defer { lastDragLocation = location }
            guard let previous = lastDragLocation else { return }
            // AppKit's local coordinate space is bottom-up (y increases
            // upward) — the reverse of `scrollWheel`'s `scrollingDeltaY`
            // convention (positive = content should move down), so the Y
            // term is negated here to match "grab the image and slide it"
            // (Preview/Photoshop's hand tool): dragging up reveals content
            // that was below, the same as scrolling down does. Both axes'
            // signs were confirmed against the live app, not just reasoned
            // about: a naive eyeball check of a before/after screenshot
            // pair first suggested the X sign was backwards, because this
            // sample footage's chain-link fence is a near-periodic pattern —
            // easy to mistake a shift by one post's spacing for the opposite
            // direction. A pixel cross-correlation between the two
            // screenshots (not eyeballed) confirmed the drag was already
            // correct in both axes.
            documentModel.panZoom(
                scrollDelta: CGPoint(x: location.x - previous.x, y: previous.y - location.y),
                viewSize: bounds.size
            )
        }

        override func mouseUp(with event: NSEvent) {
            lastDragLocation = nil
            super.mouseUp(with: event)
        }
    }

    func makeNSView(context: Context) -> MTKView {
        let view = FocusableMTKView()
        view.device = documentModel.device
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        view.documentModel = documentModel
        // Explicitly declares this drawable as plain SDR device RGB, not
        // deferring to whatever default `CAMetalLayer` would otherwise pick
        // up from the window/display — `tonemapFragment`'s output is
        // already fully display-encoded (the real Rec.709 OETF, see
        // `Tonemap.metal`'s own doc comment) and never meant to be
        // reinterpreted through an EDR/wide-gamut tone curve a second time.
        // A `CAMetalLayer` can otherwise inherit HDR/extended-range
        // behavior from the display/window it's hosted in (e.g. a Reference
        // Mode or an HDR-capable display in a non-default state) even
        // though nothing in this app's own code ever opts into that, which
        // reads as exactly this symptom: identical pixel data looks
        // correctly exposed through any offscreen/file-based path (a PNG,
        // `cine-diagnostic`) but blown-out only in the live window.
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = false
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        context.coordinator.update(documentModel: documentModel, playbackController: playbackController, view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        (nsView as? FocusableMTKView)?.documentModel = documentModel
        context.coordinator.update(documentModel: documentModel, playbackController: playbackController, view: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        // Plain (non-isolated) stored state read by `draw(in:)`, which MTKView
        // calls back on the main thread as a result of our own explicit
        // `setNeedsDisplay` calls — every write below also happens on the
        // main actor, so there's no actual concurrent access despite this
        // class not being globally `@MainActor`-isolated itself (mirroring
        // Phase 2's Coordinator, which needed the same split so `draw(in:)`
        // can satisfy `MTKViewDelegate`'s non-isolated requirement).
        private var renderer: CineRenderer?
        private var rawTexture: MTLTexture?
        private var uniforms = ExposureUniforms(blackLevel: 0, whiteLevel: 1023)
        // The active LUT texture (if any), read straight from
        // `documentModel.currentLUTTexture` in `update(...)` — this is a
        // stored, ready-made texture reference (unlike `rawTexture`, which
        // needs an async `DecodedFrameCache` fetch), so there's no fetch
        // task/loading-state dance needed for it, just a plain copy.
        private var lutTexture: MTLTexture?
        private var toneCurveTextures: ToneCurveTextureSet?
        // The active "Cine Colour" grading parameters, read straight from
        // `documentModel.grading` in `update(...)` — same tracking shape as
        // `uniforms` immediately above (a plain `Equatable` value struct, so
        // no `AnyObject` identity cast is needed here, unlike `lutTexture`).
        private var grading = GradingUniforms.identity
        // `documentModel.viewportUniforms`'s latest value, read in
        // `update(...)` — the TARGET the eased animation below animates
        // *toward*, not necessarily what's actually being rendered right
        // now (see `displayedViewport`).
        private var viewport = ViewportUniforms.identity
        // What's actually fed to `renderer.render(...)` on each `draw(in:)`
        // — equal to `viewport` outright for a pinch/scroll/drag (already
        // continuous, real-time input with nothing to ease) or once an
        // eased transition has finished; mid-transition, this is the
        // interpolated value `draw(in:)` computes fresh each frame from
        // `viewportAnimationFrom`/`viewportAnimationStart`.
        //
        // This whole eased-animation mechanism deliberately lives here, in
        // the Coordinator, entirely outside `CineDocumentModel`'s
        // `@Published` properties — an earlier version drove it from a
        // `Task` inside the model that wrote `zoomScale`/`zoomCenter` 60
        // times a second, and because EVERY `@Published` change on a
        // `ObservableObject` fires that whole object's `objectWillChange`
        // regardless of which property changed, that made SwiftUI
        // re-evaluate every other view holding an `@ObservedObject`/
        // `@EnvironmentObject` reference to the same `documentModel` —
        // `InspectorSidebarView`'s dozen-plus "Cine Colour" sliders
        // included — 60 times over a quarter second, for a change none of
        // them actually needed to react to. That's what made the zoom
        // animation itself look slow/stuttery: real dropped frames from
        // real, unnecessary SwiftUI work, not a duration or easing-curve
        // problem. Animating `displayedViewport` here instead means each
        // discrete zoom action fires exactly ONE `@Published` update (the
        // final target), and the 60Hz interpolation loop only ever calls
        // `MTKView.setNeedsDisplay(_:)` directly — untouched by Combine,
        // invisible to every other observer of `documentModel`.
        private var displayedViewport = ViewportUniforms.identity
        private var viewportAnimationFrom = ViewportUniforms.identity
        private var viewportAnimationStart: Date?
        private let viewportAnimationDuration: TimeInterval = 0.22
        // Keeps re-triggering `draw(in:)` for the animation's duration —
        // see `startViewportAnimationLoop(view:)`. Distinct from `fetchTask`
        // (which fetches a new frame's texture); this one never touches
        // `rawTexture` and only ever calls `setNeedsDisplay`.
        private var viewportAnimationTask: Task<Void, Never>?

        private var lastRenderedFrameIndex: Int = -1
        private var lastRenderedControllerID: ObjectIdentifier?
        // Compared against `documentModel.currentLUTTexture` on every
        // `update(...)` call, the same way `uniforms` is compared against
        // `documentModel.uniforms` — see `update(...)`'s `lutChanged`
        // computation for why this needs its own explicit AnyObject-cast
        // identity comparison rather than plain `!=`/`!==`.
        private var lastRenderedLUTTexture: MTLTexture?
        private var lastRenderedMasterCurveTexture: MTLTexture?
        private var lastRenderedRedCurveTexture: MTLTexture?
        private var lastRenderedGreenCurveTexture: MTLTexture?
        private var lastRenderedBlueCurveTexture: MTLTexture?
        private var fetchTask: Task<Void, Never>?

        @MainActor
        func update(documentModel: CineDocumentModel, playbackController: PlaybackController, view: MTKView) {
            if renderer == nil {
                // This view now lives in the Xcode app target (CinePlayerApp),
                // not a SwiftPM target, so it has no `Bundle.module` of its
                // own. Xcode compiles `Shaders/Tonemap.metal` (a duplicate of
                // CinePlayerCore's copy — see CinePlayerApp/project.yml) into
                // `default.metallib` inside the app's own main bundle, so
                // pass that explicitly rather than relying on the `nil`
                // default (which resolves to CinePlayerCore's own
                // `Bundle.module` — correct for `cine-diagnostic`/
                // `cine-scrub-bench`, wrong here).
                renderer = try? CineRenderer(device: documentModel.device, bundle: Bundle.main)
            }
            // Compared before overwriting `uniforms` below: this is what
            // lets a debayer-mode switch (which only ever changes
            // `documentModel.uniforms`, never `currentFrameIndex`) still
            // force a redraw even though the frame-index/controller-identity
            // check further down would otherwise see nothing worth
            // redrawing for and return early.
            let newUniforms = documentModel.uniforms
            let uniformsChanged = newUniforms != uniforms
            uniforms = newUniforms

            // Mirrors `uniformsChanged` immediately above: loading/toggling/
            // clearing a LUT only ever changes `documentModel.
            // currentLUTTexture`, never `currentFrameIndex`, so this must
            // also be computed here and force a redraw through the same
            // early-return branch below — otherwise a LUT change would
            // silently not show up on screen until something else (e.g.
            // scrubbing a frame) happened to trigger a redraw.
            // `MTLTexture` is a protocol, so plain `!=`/`!==` between two
            // `MTLTexture?` existentials isn't guaranteed to compile as (or
            // behave as) a true reference-identity comparison — cast
            // explicitly through `AnyObject?` to get one.
            let newLUTTexture = documentModel.currentLUTTexture
            let lutChanged = (newLUTTexture as AnyObject?) !== (lastRenderedLUTTexture as AnyObject?)
            lastRenderedLUTTexture = newLUTTexture
            // Cheap — just a stored, ready-made texture reference, no async
            // fetch needed (unlike `rawTexture` below) — so this is always
            // kept current regardless of whether the frame-index check
            // further down finds anything worth re-fetching for.
            lutTexture = newLUTTexture

            let toneCurveChanged = updateToneCurveTracking(documentModel)

            // Mirrors `uniformsChanged`/`lutChanged` immediately above: a
            // slider drag in the "Cine Colour" sidebar section only ever
            // changes `documentModel.grading`, never `currentFrameIndex`, so
            // this must also be computed here and force a redraw through the
            // same early-return branch below — otherwise a grading change
            // would only take visible effect after something else (like
            // scrubbing a frame) happened to trigger a redraw.
            let newGrading = documentModel.grading
            let gradingChanged = newGrading != grading
            grading = newGrading

            // Mirrors `uniformsChanged`/`lutChanged`/`gradingChanged` above:
            // a pinch/scroll gesture or a toolbar/menu zoom action only ever
            // changes `documentModel.viewportUniforms`, never
            // `currentFrameIndex`, so this must also be computed here and
            // force a redraw through the same early-return branch below.
            let newViewport = documentModel.viewportUniforms
            let viewportChanged = newViewport != viewport
            if viewportChanged {
                if documentModel.lastZoomChangeAnimated {
                    // A discrete action (toolbar +/-/dropdown, a View-menu
                    // command) — ease `displayedViewport` from wherever it
                    // currently is toward this new target over
                    // `viewportAnimationDuration`; see
                    // `startViewportAnimationLoop(view:)`.
                    viewportAnimationFrom = displayedViewport
                    viewportAnimationStart = Date()
                    startViewportAnimationLoop(view: view)
                } else {
                    // A pinch/scroll/drag — already continuous, real-time
                    // input with its own natural cadence; jumping straight
                    // there (and cancelling any still-settling animation
                    // from an earlier discrete action) is correct, not a
                    // shortcut. Layering the same ease on top would make
                    // live gesture tracking feel laggy/rubber-banded instead
                    // of 1:1 responsive.
                    viewportAnimationStart = nil
                    displayedViewport = newViewport
                }
            }
            viewport = newViewport

            // SwiftUI can keep this same `Coordinator` instance alive across
            // a document switch (opening a second file doesn't change
            // `ContentView`'s structural identity), so `playbackController`
            // itself — not just its `currentFrameIndex` — can change between
            // calls. A brand-new controller always starts at frame 0, which
            // is also the most common "just opened" state for the outgoing
            // controller, so comparing indices alone can spuriously match
            // and skip fetching the new file's frame entirely. Track the
            // controller's identity alongside the index so a controller
            // swap always forces a refetch.
            let controllerID = ObjectIdentifier(playbackController)
            let targetIndex = playbackController.currentFrameIndex
            guard targetIndex != lastRenderedFrameIndex || controllerID != lastRenderedControllerID else {
                // The already-fetched, already-displayed frame is still
                // correct — but if only the uniforms changed (a debayer
                // mode switch) or only the LUT changed (a load/toggle/
                // clear), the raw texture needs to be re-rendered through
                // the new interpretation without going anywhere near
                // `DecodedFrameCache`.
                if uniformsChanged || lutChanged || toneCurveChanged || gradingChanged || viewportChanged {
                    view.setNeedsDisplay(view.bounds)
                }
                return
            }
            let controllerChanged = controllerID != lastRenderedControllerID
            lastRenderedFrameIndex = targetIndex
            lastRenderedControllerID = controllerID

            fetchTask?.cancel()
            if controllerChanged {
                // Don't keep showing the outgoing file's last frame while
                // the new file's frame fetches in — that's a stale frame
                // from a different document, not merely an old frame of
                // the same one.
                rawTexture = nil
            }
            fetchTask = Task { [weak self, weak view] in
                guard let self else { return }
                do {
                    let texture = try await playbackController.currentTexture()
                    guard !Task.isCancelled else { return }
                    self.rawTexture = texture
                    if let view {
                        view.setNeedsDisplay(view.bounds)
                    }
                } catch {
                    // Decode failed or this fetch was superseded by a newer
                    // one (cancellation) — leave whatever was last drawn on
                    // screen rather than blanking it.
                }
            }
        }

        /// Keeps calling `view.setNeedsDisplay(_:)` at ~60Hz for
        /// `viewportAnimationDuration`, so `draw(in:)` gets invoked
        /// repeatedly while `viewportAnimationStart` is set — a no-op if a
        /// loop is already running (a second discrete zoom action landing
        /// mid-animation just updates `viewportAnimationFrom`/`Start` above;
        /// the existing loop picks up the new target on its very next tick,
        /// no need for a second one racing it).
        @MainActor
        private func startViewportAnimationLoop(view: MTKView) {
            guard viewportAnimationTask == nil else { return }
            viewportAnimationTask = Task { [weak self, weak view] in
                while true {
                    guard let self, let view else { return }
                    guard let start = self.viewportAnimationStart else { break }
                    view.setNeedsDisplay(view.bounds)
                    if Date().timeIntervalSince(start) >= self.viewportAnimationDuration { break }
                    try? await Task.sleep(for: .seconds(1.0 / 60.0))
                }
                self?.viewportAnimationTask = nil
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let renderer = renderer,
                let rawTexture = rawTexture,
                let drawable = view.currentDrawable,
                let commandBuffer = renderer.commandQueue.makeCommandBuffer()
            else { return }

            // Computed fresh from wall-clock time on every frame (not
            // pre-computed by the animation loop above, whose only job is
            // making sure this function keeps getting called) — see
            // `displayedViewport`'s own doc comment for why this whole
            // mechanism lives here rather than as `@Published` state.
            let renderViewport: ViewportUniforms
            if let start = viewportAnimationStart {
                let t = min(1, Date().timeIntervalSince(start) / viewportAnimationDuration)
                let eased = 1 - pow(1 - Float(t), 3)
                renderViewport = ViewportUniforms(
                    scale: viewportAnimationFrom.scale + (viewport.scale - viewportAnimationFrom.scale) * eased,
                    centerX: viewportAnimationFrom.centerX + (viewport.centerX - viewportAnimationFrom.centerX) * eased,
                    centerY: viewportAnimationFrom.centerY + (viewport.centerY - viewportAnimationFrom.centerY) * eased
                )
                displayedViewport = renderViewport
                if t >= 1 { viewportAnimationStart = nil }
            } else {
                renderViewport = displayedViewport
            }

            renderer.render(
                rawTexture: rawTexture,
                uniforms: uniforms,
                into: commandBuffer,
                colorAttachment: drawable.texture,
                lutTexture: lutTexture,
                grading: grading,
                viewport: renderViewport,
                toneCurveTextures: toneCurveTextures
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

extension CineMetalView.Coordinator {
    @MainActor
    private func updateToneCurveTracking(_ documentModel: CineDocumentModel) -> Bool {
        let newToneCurveTextures = documentModel.toneCurveTextures
        let toneCurveChanged =
            (newToneCurveTextures?.master as AnyObject?) !== (lastRenderedMasterCurveTexture as AnyObject?)
            || (newToneCurveTextures?.red as AnyObject?) !== (lastRenderedRedCurveTexture as AnyObject?)
            || (newToneCurveTextures?.green as AnyObject?) !== (lastRenderedGreenCurveTexture as AnyObject?)
            || (newToneCurveTextures?.blue as AnyObject?) !== (lastRenderedBlueCurveTexture as AnyObject?)
        lastRenderedMasterCurveTexture = newToneCurveTextures?.master
        lastRenderedRedCurveTexture = newToneCurveTextures?.red
        lastRenderedGreenCurveTexture = newToneCurveTextures?.green
        lastRenderedBlueCurveTexture = newToneCurveTextures?.blue
        toneCurveTextures = newToneCurveTextures
        return toneCurveChanged
    }
}
