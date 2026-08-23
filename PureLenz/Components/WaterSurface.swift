// PureLenz - An iOS camera app with AI-powered exposure control
// Copyright (C) 2025 nainajnahO
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

/// Every number the feel of the water depends on, in one place. All of these
/// are judged on device; nothing else in the simulation is meant to be tuned.
enum WaterTuning {
    /// Grid pitch, in points. Finer resolves tighter rings and costs
    /// quadratically; 4pt is ~24k cells on an iPhone screen.
    static let cellSize: CGFloat = 4
    /// How fast a ring travels, points per second. Rings bunch up ahead of a
    /// finger moving near this speed and stretch out behind it — the look of
    /// a finger drawn through water comes from the finger being comparable to
    /// the wave.
    static let waveSpeed: Double = 500
    /// Simulation steps per second. The explicit wave scheme is only stable
    /// while `(waveSpeed / substepRate / cellSize)² ≤ 0.5`; these numbers put
    /// it at 0.27. Display frames are split into however many steps fit.
    static let substepRate: Double = 240
    /// Longest stretch of real time one display frame is allowed to simulate.
    /// After a hitch the excess is dropped rather than caught up, so a stall
    /// can never snowball into a longer stall.
    static let maxFrameTime: Double = 1.0 / 30
    /// Seconds for a ring's height to halve. Sets how long the surface takes
    /// to go still after the finger leaves: roughly five half-lives.
    static let amplitudeHalfLife: Double = 0.4
    /// Width of the absorbing border, in cells. Rings that reach it die
    /// instead of bouncing back off the screen edge like a tray of water.
    /// Keep it at least a ring's width wide or it reflects.
    static let spongeCells = 16
    /// Extra fraction of height lost per step at the outermost cell, ramping
    /// quadratically to nothing at the sponge's inner edge.
    static let spongeAbsorb: Float = 0.15
    /// Depth a still or slow finger presses the surface to, in height units.
    /// Only ratios of heights matter; this is the unit everything else is
    /// relative to.
    static let dentDepth: Float = 1.3
    /// Depth at `planingSpeed` and above. A finger moving fast through water
    /// rides up and penetrates less, so a quick sweep leaves a shallower dent
    /// than a slow one; the slow sweep is where the warp should be felt.
    static let planedDepth: Float = 1
    /// Finger speed, points per second, at which the dent has fully planed
    /// down to `planedDepth`. Depth falls linearly between rest and this.
    static let planingSpeed: CGFloat = 600
    /// Seconds over which the finger's speed is smoothed before it sets the
    /// depth — touch events are jittery, and a dent that flickered in depth
    /// would shed rings of its own.
    static let speedSmoothing: Double = 0.08
    /// Width of the finger's dent, in points (Gaussian σ).
    static let dentSigma: CGFloat = 22
    /// Fraction of the way the surface is pulled toward the dent each step. A
    /// soft contact; 1 would be a hard clamp with a harsher bow wave.
    static let grip: Float = 0.3
    /// Slope (height per cell) that counts as full refraction. The resting
    /// dent's steepest point is about 0.14; the planed dent's about 0.11.
    static let maxSlope: Float = 0.15
    /// Sample offset, in points, at full slope — how far the scene *under* the
    /// water shifts when refracted. Also bounds `maxSampleOffset`.
    static let strength: CGFloat = 24
    /// How far a dot is carried by the finger's own dent at full slope, in
    /// points. The dots ride the *waves* at `strength`, like the scene; this
    /// much smaller gain applies only to the dent the finger is holding. At
    /// the scene's gain the dots near the rim were carried past the centre and
    /// piled up into one white blob; at this one the finger just dimples the
    /// mesh.
    static let dotStrength: CGFloat = 4
    /// Seconds for the finger's dent, as the dots account for it, to fade
    /// after a lift — roughly how long the real dent takes to rebound, so the
    /// dots hand over from "dimpled by the finger" to "riding the rebound
    /// ring" without a jump.
    static let dentRebound: Double = 0.05
    /// Largest sample offset, in points, at which the surface counts as still.
    /// Half a point is a third of a pixel; cutting from that to the live
    /// viewfinder is invisible.
    static let calmOffset: CGFloat = 0.5
    /// Hard cap on the tail after release, in seconds, whatever the surface is
    /// still doing.
    static let calmTimeout: Double = 3

    // The finger's trace — what the dot matrix lights up.

    /// How brightly the finger excites the surface around it: full at the
    /// contact point, ~63% gone by this distance, halved every ~29pt.
    static let traceFalloff: CGFloat = 42
    /// The exponential alone never reaches zero — and a few percent of a
    /// two-stops-up white is still visible — so the last stretch is windowed
    /// down to nothing between these two distances instead of cut.
    static let traceWindowStart: CGFloat = 70
    static let traceWindowEnd: CGFloat = 115
    /// Seconds for the trace under a *stationary* finger to reach half
    /// brightness. Fast on purpose: a quick lens can settle in well under a
    /// second, and the glow only registers if it is at full strength for most
    /// of that.
    static let traceRiseHalfLife: Double = 0.05
    /// Seconds for the trace to fade to half once the finger has moved on.
    /// This is the length of the glowing tail behind a drag, and of the fade
    /// once the lens has landed.
    static let traceHalfLife: Double = 0.1

    // Breathing — what the lit patch does while the lens works.

    /// Seconds per breath, full to dim and back, starting the moment the finger
    /// lifts. The breath is the unit the glow is measured in: `settle()` lets
    /// the patch breathe out before fading, so a quick focus shows one dip and
    /// a hunting lens shows however many it took.
    static let breathePeriod: Double = 1.6
    /// How far the patch dims at the bottom of a breath, as a fraction of full
    /// brightness. Never all the way: dark reads as "done".
    static let breatheDepth: Double = 0.75
}

/// One frame of the surface as views read it: slope per cell for refraction,
/// and the finger's trace per cell for the dot matrix. A value, so a view
/// captures a consistent frame and reads nothing live while drawing.
struct WaterField {
    /// The dent the finger is imposing (or, just after a lift, its fading
    /// ghost): the one part of the surface that is not a wave.
    struct Dent {
        var center: CGPoint
        var depth: Float
    }

    /// (∂h/∂x, ∂h/∂y) per cell, row-major, normalised to ±1 by
    /// `WaterTuning.maxSlope`.
    var slopes: [Float] = []
    /// 0…1 per cell: how recently, and how closely, the finger was here.
    var trace: [Float] = []
    /// 0…1, one value for the whole patch: how bright the trace is drawn this
    /// frame — full under the finger, breathing once it has lifted (see
    /// `WaterTuning.breathePeriod`). The trace says where the light is; this
    /// says how much of it there is.
    var breath: Double = 1
    /// 0…1, one value for the whole patch: how far the dots have gone from
    /// white toward yellow. 0 until a hold's second stage is on its way
    /// (`WaterSurface.warm`), rising over that wait, 1 once it has landed.
    var warmth: Double = 0
    var cellsWide = 0
    var cellsHigh = 0
    var dent: Dent?

    /// The normalised slope at `point` — the same bilinear blend of the same
    /// array the shader samples, so anything moved by it tilts with the scene.
    /// Times `WaterTuning.strength` it is the shader's sample offset; times
    /// `WaterTuning.dotStrength` it is how far a dot on the surface is carried.
    func slope(at point: CGPoint) -> CGVector {
        guard cellsWide > 0 else { return .zero }
        let (xa, xb, ya, yb, tx, ty) = cells(around: point)
        func slope(_ x: Int, _ y: Int) -> SIMD2<Float> {
            let i = (y * cellsWide + x) * 2
            return SIMD2(slopes[i], slopes[i + 1])
        }
        let top = slope(xa, ya) + (slope(xb, ya) - slope(xa, ya)) * tx
        let bottom = slope(xa, yb) + (slope(xb, yb) - slope(xa, yb)) * tx
        let g = top + (bottom - top) * ty
        return CGVector(dx: CGFloat(g.x), dy: CGFloat(g.y))
    }

    /// The slope of the finger's own dent at `point`, normalised like
    /// `slope(at:)` — the analytic Gaussian the surface is being pulled
    /// toward, so `slope(at:) - dentSlope(at:)` is the waves alone.
    func dentSlope(at point: CGPoint) -> CGVector {
        guard let dent else { return .zero }
        let sigma = Float(WaterTuning.dentSigma / WaterTuning.cellSize)
        let dx = Float((point.x - dent.center.x) / WaterTuning.cellSize)
        let dy = Float((point.y - dent.center.y) / WaterTuning.cellSize)
        let gain = dent.depth * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            / (sigma * sigma) / WaterTuning.maxSlope
        return CGVector(dx: CGFloat(dx * gain), dy: CGFloat(dy * gain))
    }

    /// The finger's trace at `point`, 0…1.
    func glow(at point: CGPoint) -> Double {
        guard cellsWide > 0 else { return 0 }
        let (xa, xb, ya, yb, tx, ty) = cells(around: point)
        func value(_ x: Int, _ y: Int) -> Float { trace[y * cellsWide + x] }
        let top = value(xa, ya) + (value(xb, ya) - value(xa, ya)) * tx
        let bottom = value(xa, yb) + (value(xb, yb) - value(xa, yb)) * tx
        return Double(top + (bottom - top) * ty)
    }

    /// The four cells around `point` (cell `(x, y)` is centred at
    /// `(x + 0.5, y + 0.5) * cellSize`) and the blend weights between them.
    private func cells(around point: CGPoint)
        -> (xa: Int, xb: Int, ya: Int, yb: Int, tx: Float, ty: Float) {
        let fx = point.x / WaterTuning.cellSize - 0.5
        let fy = point.y / WaterTuning.cellSize - 0.5
        let x0 = Int(fx.rounded(.down))
        let y0 = Int(fy.rounded(.down))
        return (
            xa: min(max(x0, 0), cellsWide - 1), xb: min(max(x0 + 1, 0), cellsWide - 1),
            ya: min(max(y0, 0), cellsHigh - 1), yb: min(max(y0 + 1, 0), cellsHigh - 1),
            tx: Float(fx - CGFloat(x0)), ty: Float(fy - CGFloat(y0))
        )
    }
}

/// The water the viewfinder is seen through: a height field over the view,
/// simulated with the wave equation, that a finger presses a dent into.
///
/// Nothing here emits ripples. The finger is a *boundary condition* — while it
/// is on the glass, the cells under it are pulled toward a small Gaussian dip
/// each step — and the rest follows from the physics: the sudden dent on
/// touch-down sends contact rings out, dragging it sheds a wake (bunched
/// ahead, stretched behind, because the finger is chasing its own waves), two
/// presses interfere, and lifting lets the dent rebound into one outgoing
/// ring. Tap and drag are the same gesture with and without movement in
/// between, and the finger is in the water exactly as long as it is on the
/// screen — a held dent is perfectly still once its rings have left, which on
/// device read as a freeze, so nothing is ever held waiting for the lens.
///
/// Alongside the height the surface keeps the finger's *trace*: how recently
/// it was over each cell, rising while it is there and fading once it has
/// gone. That is what the dot matrix lights up — a stationary mesh over the
/// whole view that glows only where the finger has been. The trace is the one
/// thing that does wait for the lens: after a lift the patch under the lift
/// point stays lit, breathing, until `settle()` — and then until the end of
/// that breath — marking where focus is being found, then fades like the
/// rest. It is light, not water, so nothing has to hold still.
/// The trace is kept here rather than in the dot view so the one display link
/// drives both and both live on the same grid.
///
/// The surface publishes one `WaterField` per display frame — slope rather
/// than height, since water refracts by slope (`WaterRefraction.metal`), and
/// the dots move by the same slope, so there is no second copy of the wave to
/// keep in step. Simulation state is `@ObservationIgnored`; the field is
/// replaced once per frame rather than written in place, which would notify
/// per cell.
///
/// Inherits from NSObject so the display link can target an `@objc` selector
/// (same pattern as `AutoExposureCoordinator`). The link exists only from a
/// press until the surface is still again, so the effect costs nothing at
/// rest — the same contract as the frame pump that feeds the warp.
@Observable
final class WaterSurface: NSObject {
    private(set) var field = WaterField()
    /// True while nothing is happening: no press, every cell below the calm
    /// threshold and the trace faded. The warp is disabled and the copy handed
    /// back on this.
    private(set) var isCalm = true

    /// True while the finger is on the glass: the dent is being pressed.
    @ObservationIgnored private var pressed = false
    /// True from touch-down until the lens settles: the trace under `finger`
    /// is being lit. Outlives `pressed` by however long focus takes.
    @ObservationIgnored private var marking = false
    @ObservationIgnored private var height: [Float] = []
    @ObservationIgnored private var previous: [Float] = []
    /// Per-cell damping: base decay times the sponge's extra absorption.
    @ObservationIgnored private var damping: [Float] = []
    @ObservationIgnored private var slopes: [Float] = []
    @ObservationIgnored private var trace: [Float] = []
    /// Exact finger position in points — never snapped to a cell, so a slow
    /// drag moves the dent continuously rather than in 4pt hops.
    @ObservationIgnored private var finger = CGPoint.zero
    /// Where the finger was at the last display frame, for its speed.
    @ObservationIgnored private var fingerBefore = CGPoint.zero
    /// Smoothed finger speed, points per second.
    @ObservationIgnored private var fingerSpeed: CGFloat = 0
    /// The dent's depth this frame, planed by `fingerSpeed`.
    @ObservationIgnored private var depth = WaterTuning.dentDepth
    @ObservationIgnored private var accumulator: Double = 0
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var releasedAt: CFTimeInterval = 0
    /// When the finger last left the glass — the clock the breathing runs on.
    /// Separate from `releasedAt`, which is restamped when the marking ends;
    /// restarting the breath there would make the brightness jump.
    @ObservationIgnored private var liftedAt: CFTimeInterval = 0
    /// When the marking will end: the bottom of the breath that was under way
    /// when `settle()` was called. Nil while nothing has asked to settle.
    @ObservationIgnored private var settleAt: CFTimeInterval?
    /// When the dots began warming from white toward yellow, and how long
    /// the warming takes. Nil while the dots are white.
    @ObservationIgnored private var warmingStart: CFTimeInterval?
    @ObservationIgnored private var warmingDuration: CFTimeInterval = 1
    @ObservationIgnored private var link: CADisplayLink?

    private static let substepDuration = 1 / WaterTuning.substepRate
    /// Courant number squared: how far, in cells², a wave travels per step.
    private static let courant2 = Float(
        pow(WaterTuning.waveSpeed * substepDuration / Double(WaterTuning.cellSize), 2)
    )
    private static let baseDamping = Float(
        pow(0.5, 1 / (WaterTuning.amplitudeHalfLife * WaterTuning.substepRate))
    )
    /// Below this the trace is invisible even as a two-stops-up white.
    private static let traceFloor: Float = 1 / 255

    // MARK: - Size

    /// Lay the grid over a view of this size. Called from layout; a change
    /// mid-session starts the surface over flat.
    func resize(to size: CGSize) {
        let wide = Int((size.width / WaterTuning.cellSize).rounded(.up))
        let high = Int((size.height / WaterTuning.cellSize).rounded(.up))
        guard wide > 2, high > 2, wide != field.cellsWide || high != field.cellsHigh else { return }

        reset()
        height = [Float](repeating: 0, count: wide * high)
        previous = height
        trace = height
        slopes = [Float](repeating: 0, count: wide * high * 2)
        field = WaterField(slopes: slopes, trace: trace, cellsWide: wide, cellsHigh: high)

        damping = height
        let sponge = Float(WaterTuning.spongeCells)
        for y in 0..<high {
            for x in 0..<wide {
                let toEdge = Float(min(x, y, wide - 1 - x, high - 1 - y))
                let depth = max(0, (sponge - toEdge) / sponge)
                damping[y * wide + x] = Self.baseDamping * (1 - WaterTuning.spongeAbsorb * depth * depth)
            }
        }
    }

    // MARK: - Finger

    /// The finger lands: the dent forms and the trace under it starts to light.
    func press(at point: CGPoint) {
        guard field.cellsWide > 0 else { return }
        finger = point
        fingerBefore = point
        fingerSpeed = 0
        pressed = true
        marking = true
        // A new press is the focus now; a settle still pending from the last
        // one must not end this patch mid-breath.
        settleAt = nil
        // And it starts white, whatever the last one warmed to.
        warmingStart = nil
        guard isCalm else { return }

        isCalm = false
        lastTimestamp = nil
        accumulator = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func move(to point: CGPoint) {
        guard pressed else { return }
        finger = point
    }

    /// The finger leaves the glass: the dent rebounds into its ring. The trace
    /// stays lit where it lifted until `settle()`.
    func lift() {
        guard pressed else { return }
        pressed = false
        releasedAt = CACurrentMediaTime()
        liftedAt = releasedAt
    }

    /// The lens has landed: let the lit patch breathe out, then stop lighting
    /// the lift point and let the trace fade. The marking ends at the *bottom*
    /// of the breath under way, so the glow always leaves on an exhale — one
    /// dip for a quick focus, more for a lens that hunted. Ending at the top
    /// was tried first: the patch came back to full and then cut out, and that
    /// second brightening read as one breath too many. Safe to call when
    /// nothing is marked.
    func settle() {
        guard marking, settleAt == nil else { return }
        let breathed = (CACurrentMediaTime() - liftedAt) / WaterTuning.breathePeriod
        // Troughs sit at (k + ½) periods; take the first one not yet passed.
        let trough = (breathed - 0.5).rounded(.up) + 0.5
        settleAt = liftedAt + trough * WaterTuning.breathePeriod
    }

    /// The dots under the finger begin turning from white to yellow, reaching
    /// yellow after `duration` — the wait for a hold's second stage, so the
    /// colour arrives with the stage. They stay yellow from then on, through
    /// the lift and the fade, until the next press starts white again.
    func warm(over duration: TimeInterval) {
        warmingStart = CACurrentMediaTime()
        warmingDuration = duration
    }

    /// Back to white at once — the second stage was declined partway.
    func cool() {
        warmingStart = nil
    }

    /// Flatten everything and stop, immediately — for leaving the foreground,
    /// where a surface left mid-wave would otherwise resume on return.
    func reset() {
        pressed = false
        marking = false
        settleAt = nil
        warmingStart = nil
        field.warmth = 0
        link?.invalidate()
        link = nil
        for i in height.indices {
            height[i] = 0
            previous[i] = 0
            trace[i] = 0
        }
        for i in slopes.indices {
            slopes[i] = 0
        }
        field.slopes = slopes
        field.trace = trace
        field.breath = 1
        field.dent = nil
        isCalm = true
    }

    // MARK: - Simulation

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 }
            ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp

        if pressed {
            plane(elapsed: elapsed)
            field.dent = WaterField.Dent(center: finger, depth: depth)
        } else if let ghost = field.dent {
            // The real dent is rebounding; let the dots' idea of it go at the
            // same pace.
            let depth = ghost.depth * Float(exp(-elapsed / WaterTuning.dentRebound))
            field.dent = depth > 0.01 ? WaterField.Dent(center: ghost.center, depth: depth) : nil
        }

        accumulator = min(accumulator + elapsed, WaterTuning.maxFrameTime)
        while accumulator >= Self.substepDuration {
            step()
            accumulator -= Self.substepDuration
        }

        let peakOffset = writeSlopes()
        let peakTrace = writeTrace(elapsed: elapsed)
        field.slopes = slopes
        field.trace = trace
        field.breath = pressed ? 1 : breath(sinceLift: link.timestamp - liftedAt)
        field.warmth = warmingStart.map { start in
            min(1, max(0, (link.timestamp - start) / warmingDuration))
        } ?? 0

        if let settleAt, !pressed, link.timestamp >= settleAt {
            // Bottom of the last breath: the marking ends here, and the tail's
            // clock restarts so the fade is not cut short by `calmTimeout`.
            marking = false
            self.settleAt = nil
            releasedAt = link.timestamp
        }

        let still = (peakOffset < WaterTuning.calmOffset && peakTrace < Self.traceFloor)
            || CACurrentMediaTime() - releasedAt > WaterTuning.calmTimeout
        if !pressed, !marking, still {
            reset()
        }
    }

    /// Set this frame's dent depth from how fast the finger is moving: full
    /// depth at rest, shallower the faster it sweeps (see
    /// `WaterTuning.planedDepth`). Speed is measured frame to frame here rather
    /// than from touch events, so a finger that stops — and sends no events —
    /// reads as still.
    private func plane(elapsed: Double) {
        let moved = hypot(finger.x - fingerBefore.x, finger.y - fingerBefore.y)
        fingerBefore = finger
        let speed = moved / max(elapsed, 0.001)
        let blend = 1 - exp(-elapsed / WaterTuning.speedSmoothing)
        fingerSpeed += (speed - fingerSpeed) * blend

        let planing = Float(min(fingerSpeed / WaterTuning.planingSpeed, 1))
        depth = WaterTuning.dentDepth + (WaterTuning.planedDepth - WaterTuning.dentDepth) * planing
    }

    /// Brightness of the lit patch `elapsed` seconds after the finger left: a
    /// raised cosine that leaves full brightness without a step and dips by
    /// `breatheDepth` once per `breathePeriod`. `settle()` ends the marking at
    /// a dip, so the fade always starts from the bottom. A pure function of
    /// time, so it keeps running through the fade rather than snapping, which
    /// would read as a flash.
    private func breath(sinceLift elapsed: Double) -> Double {
        let phase = 2 * Double.pi * elapsed / WaterTuning.breathePeriod
        return 1 - WaterTuning.breatheDepth * (1 - cos(phase)) / 2
    }

    /// One step of the wave equation, then the finger.
    ///
    /// `previous` is overwritten with the *next* heights and the buffers are
    /// swapped, so the two arrays are reused without allocating. The border
    /// ring is never written and stays at zero, a fixed edge inside the sponge.
    private func step() {
        let wide = field.cellsWide
        let high = field.cellsHigh
        let c2 = Self.courant2

        height.withUnsafeBufferPointer { h in
            damping.withUnsafeBufferPointer { d in
                previous.withUnsafeMutableBufferPointer { next in
                    for y in 1..<(high - 1) {
                        for x in 1..<(wide - 1) {
                            let i = y * wide + x
                            let laplacian = h[i - 1] + h[i + 1] + h[i - wide] + h[i + wide] - 4 * h[i]
                            next[i] = (2 * h[i] - next[i] + c2 * laplacian) * d[i]
                        }
                    }

                    if pressed {
                        let sigma = Float(WaterTuning.dentSigma / WaterTuning.cellSize)
                        let depth = self.depth
                        forEachCell(within: 3 * sigma) { i, d2 in
                            let target = -depth * exp(-d2 / (2 * sigma * sigma))
                            next[i] += (target - next[i]) * WaterTuning.grip
                        }
                    }
                }
            }
        }
        swap(&height, &previous)
    }

    /// Central-difference slope of every interior cell into `slopes`,
    /// normalised and clamped to ±1. Returns the largest resulting sample
    /// offset, in points — the calm check, for free.
    private func writeSlopes() -> CGFloat {
        let wide = field.cellsWide
        let high = field.cellsHigh
        let scale = 0.5 / WaterTuning.maxSlope
        var peak: Float = 0

        height.withUnsafeBufferPointer { h in
            slopes.withUnsafeMutableBufferPointer { s in
                for y in 1..<(high - 1) {
                    for x in 1..<(wide - 1) {
                        let i = y * wide + x
                        let gx = min(max((h[i + 1] - h[i - 1]) * scale, -1), 1)
                        let gy = min(max((h[i + wide] - h[i - wide]) * scale, -1), 1)
                        s[i * 2] = gx
                        s[i * 2 + 1] = gy
                        peak = max(peak, abs(gx), abs(gy))
                    }
                }
            }
        }
        return CGFloat(peak) * WaterTuning.strength
    }

    /// Fade the whole trace by `elapsed`, then, while marking, re-light what is
    /// under the finger (or where it lifted). Returns the brightest cell left.
    private func writeTrace(elapsed: Double) -> Float {
        let decay = Float(pow(0.5, elapsed / WaterTuning.traceHalfLife))
        let rise = Float(1 - pow(0.5, elapsed / WaterTuning.traceRiseHalfLife))
        let cell = Float(WaterTuning.cellSize)
        let falloff = Float(WaterTuning.traceFalloff) / cell
        let windowStart = Float(WaterTuning.traceWindowStart) / cell
        let windowEnd = Float(WaterTuning.traceWindowEnd) / cell
        var peak: Float = 0

        trace.withUnsafeMutableBufferPointer { t in
            for i in t.indices {
                t[i] *= decay
            }
            if marking {
                forEachCell(within: windowEnd) { i, d2 in
                    let d = d2.squareRoot()
                    let w = max(0, (d - windowStart) / (windowEnd - windowStart))
                    let window = 1 - w * w * (3 - 2 * w)
                    let target = exp(-d / falloff) * window
                    if target > t[i] {
                        t[i] += (target - t[i]) * rise
                    }
                }
            }
            for i in t.indices {
                peak = max(peak, t[i])
            }
        }
        return peak
    }

    /// Visit every interior cell within `radius` cells of the finger, with its
    /// index and squared distance in cells.
    private func forEachCell(within radius: Float, _ body: (_ index: Int, _ distance2: Float) -> Void) {
        let wide = field.cellsWide
        let high = field.cellsHigh
        let fx = Float(finger.x / WaterTuning.cellSize) - 0.5
        let fy = Float(finger.y / WaterTuning.cellSize) - 0.5
        let x0 = max(1, Int((fx - radius).rounded(.down)))
        let x1 = min(wide - 2, Int((fx + radius).rounded(.up)))
        let y0 = max(1, Int((fy - radius).rounded(.down)))
        let y1 = min(high - 2, Int((fy + radius).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }

        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Float(x) - fx
                let dy = Float(y) - fy
                let d2 = dx * dx + dy * dy
                if d2 < radius * radius {
                    body(y * wide + x, d2)
                }
            }
        }
    }
}
