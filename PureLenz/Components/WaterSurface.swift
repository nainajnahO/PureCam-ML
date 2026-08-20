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
    /// Depth the finger presses the surface to, in height units. Only ratios
    /// of heights matter; this is the unit everything else is relative to.
    static let dentDepth: Float = 1
    /// Width of the finger's dent, in points (Gaussian σ).
    static let dentSigma: CGFloat = 22
    /// Fraction of the way the surface is pulled toward the dent each step. A
    /// soft contact; 1 would be a hard clamp with a harsher bow wave.
    static let grip: Float = 0.3
    /// Slope (height per cell) that counts as full refraction. The held dent's
    /// steepest point is about 0.11.
    static let maxSlope: Float = 0.12
    /// Sample offset, in points, at full slope. Also bounds `maxSampleOffset`.
    static let strength: CGFloat = 18
    /// Largest sample offset, in points, at which the surface counts as still.
    /// Half a point is a third of a pixel; cutting from that to the live
    /// viewfinder is invisible.
    static let calmOffset: CGFloat = 0.5
    /// Hard cap on the tail after release, in seconds, whatever the surface is
    /// still doing.
    static let calmTimeout: Double = 3
}

/// The water the viewfinder is seen through: a height field over the view,
/// simulated with the wave equation, that a finger presses a dent into.
///
/// Nothing here emits ripples. The finger is a *boundary condition* — while
/// pressed, the cells under it are pulled toward a small Gaussian dip each
/// step — and the rest follows from the physics: the sudden dent on touch-down
/// sends contact rings out, dragging it sheds a wake (bunched ahead, stretched
/// behind, because the finger is chasing its own waves), two presses interfere,
/// and lifting lets the dent rebound into one outgoing ring. Tap and drag are
/// the same gesture with and without movement in between.
///
/// The surface reports itself as *slope*, not height: water refracts by slope
/// (`WaterRefraction.metal`), and the dot matrix moves by the same slope, so
/// both read the one array and there is no second copy of the wave to keep in
/// step. Simulation state is `@ObservationIgnored`; only what views draw from
/// is tracked, and `slopes` is replaced once per display frame rather than
/// written in place, which would notify per cell.
///
/// Inherits from NSObject so the display link can target an `@objc` selector
/// (same pattern as `AutoExposureCoordinator`). The link exists only from a
/// press until the surface is still again, so the effect costs nothing at
/// rest — the same contract as the frame pump that feeds the warp.
@Observable
final class WaterSurface: NSObject {
    /// (∂h/∂x, ∂h/∂y) per cell, row-major, normalised to ±1 by
    /// `WaterTuning.maxSlope`. Read by the shader and by `displacement(at:)`.
    private(set) var slopes: [Float] = []
    private(set) var cellsWide = 0
    private(set) var cellsHigh = 0
    /// True while nothing is happening: no press, and every cell below the
    /// calm threshold. The warp is disabled and the copy handed back on this.
    private(set) var isCalm = true
    /// True from touch-down until `release()` — which is the lens settling,
    /// not the finger lifting (see `CameraViewModel.focusTouch`).
    private(set) var pressed = false
    /// Where the dent is: under the finger while it moves, then wherever it
    /// lifted. Positions the dot matrix.
    private(set) var contactPoint: CGPoint?

    @ObservationIgnored private var height: [Float] = []
    @ObservationIgnored private var previous: [Float] = []
    /// Per-cell damping: base decay times the sponge's extra absorption.
    @ObservationIgnored private var damping: [Float] = []
    @ObservationIgnored private var scratch: [Float] = []
    /// Exact finger position in points — never snapped to a cell, so a slow
    /// drag moves the dent continuously rather than in 4pt hops.
    @ObservationIgnored private var finger = CGPoint.zero
    @ObservationIgnored private var accumulator: Double = 0
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var releasedAt: CFTimeInterval = 0
    @ObservationIgnored private var link: CADisplayLink?

    private static let substepDuration = 1 / WaterTuning.substepRate
    /// Courant number squared: how far, in cells², a wave travels per step.
    private static let courant2 = Float(
        pow(WaterTuning.waveSpeed * substepDuration / Double(WaterTuning.cellSize), 2)
    )
    private static let baseDamping = Float(
        pow(0.5, 1 / (WaterTuning.amplitudeHalfLife * WaterTuning.substepRate))
    )

    // MARK: - Size

    /// Lay the grid over a view of this size. Called from layout; a change
    /// mid-session starts the surface over flat.
    func resize(to size: CGSize) {
        let wide = Int((size.width / WaterTuning.cellSize).rounded(.up))
        let high = Int((size.height / WaterTuning.cellSize).rounded(.up))
        guard wide > 2, high > 2, wide != cellsWide || high != cellsHigh else { return }

        reset()
        cellsWide = wide
        cellsHigh = high
        height = [Float](repeating: 0, count: wide * high)
        previous = height
        scratch = [Float](repeating: 0, count: wide * high * 2)
        slopes = scratch

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

    func press(at point: CGPoint) {
        guard cellsWide > 0 else { return }
        finger = point
        contactPoint = point
        pressed = true
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
        contactPoint = point
    }

    /// Let the surface go. Safe to call when nothing is pressed.
    func release() {
        guard pressed else { return }
        pressed = false
        releasedAt = CACurrentMediaTime()
    }

    /// Flatten everything and stop, immediately — for leaving the foreground,
    /// where a surface left mid-wave would otherwise resume on return.
    func reset() {
        pressed = false
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        for i in height.indices {
            height[i] = 0
            previous[i] = 0
        }
        for i in scratch.indices {
            scratch[i] = 0
        }
        slopes = scratch
        contactPoint = nil
        isCalm = true
    }

    // MARK: - Reading

    /// The shader's sample offset at `point`, in points — the same bilinear
    /// blend of the same array, so anything drawn with this moves with the
    /// scene. Content (the dots) takes the negative: the shader moves where a
    /// pixel is *sampled from*, which moves what is seen the other way.
    func displacement(at point: CGPoint) -> CGVector {
        guard cellsWide > 0 else { return .zero }
        let fx = point.x / WaterTuning.cellSize - 0.5
        let fy = point.y / WaterTuning.cellSize - 0.5
        let x0 = Int(fx.rounded(.down))
        let y0 = Int(fy.rounded(.down))
        let tx = Float(fx - CGFloat(x0))
        let ty = Float(fy - CGFloat(y0))
        let xa = min(max(x0, 0), cellsWide - 1), xb = min(max(x0 + 1, 0), cellsWide - 1)
        let ya = min(max(y0, 0), cellsHigh - 1), yb = min(max(y0 + 1, 0), cellsHigh - 1)

        func slope(_ x: Int, _ y: Int) -> SIMD2<Float> {
            let i = (y * cellsWide + x) * 2
            return SIMD2(slopes[i], slopes[i + 1])
        }
        let top = slope(xa, ya) + (slope(xb, ya) - slope(xa, ya)) * tx
        let bottom = slope(xa, yb) + (slope(xb, yb) - slope(xa, yb)) * tx
        let g = top + (bottom - top) * ty
        return CGVector(
            dx: CGFloat(g.x) * WaterTuning.strength,
            dy: CGFloat(g.y) * WaterTuning.strength
        )
    }

    // MARK: - Simulation

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastTimestamp.map { link.timestamp - $0 }
            ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = link.timestamp

        accumulator = min(accumulator + elapsed, WaterTuning.maxFrameTime)
        while accumulator >= Self.substepDuration {
            step()
            accumulator -= Self.substepDuration
        }

        let peakOffset = writeSlopes()
        slopes = scratch

        let settled = peakOffset < WaterTuning.calmOffset
            || CACurrentMediaTime() - releasedAt > WaterTuning.calmTimeout
        if !pressed, settled {
            stop()
        }
    }

    /// One step of the wave equation, then the finger.
    ///
    /// `previous` is overwritten with the *next* heights and the buffers are
    /// swapped, so the two arrays are reused without allocating. The border
    /// ring is never written and stays at zero, a fixed edge inside the sponge.
    private func step() {
        let wide = cellsWide
        let high = cellsHigh
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
                        let fx = Float(finger.x / WaterTuning.cellSize) - 0.5
                        let fy = Float(finger.y / WaterTuning.cellSize) - 0.5
                        let sigma = Float(WaterTuning.dentSigma / WaterTuning.cellSize)
                        let radius = 3 * sigma
                        let x0 = max(1, Int((fx - radius).rounded(.down)))
                        let x1 = min(wide - 2, Int((fx + radius).rounded(.up)))
                        let y0 = max(1, Int((fy - radius).rounded(.down)))
                        let y1 = min(high - 2, Int((fy + radius).rounded(.up)))
                        if x0 <= x1, y0 <= y1 {
                            for y in y0...y1 {
                                for x in x0...x1 {
                                    let dx = Float(x) - fx
                                    let dy = Float(y) - fy
                                    let d2 = dx * dx + dy * dy
                                    guard d2 < radius * radius else { continue }
                                    let target = -WaterTuning.dentDepth * exp(-d2 / (2 * sigma * sigma))
                                    let i = y * wide + x
                                    next[i] += (target - next[i]) * WaterTuning.grip
                                }
                            }
                        }
                    }
                }
            }
        }
        swap(&height, &previous)
    }

    /// Central-difference slope of every interior cell into `scratch`,
    /// normalised and clamped to ±1. Returns the largest resulting sample
    /// offset, in points — the calm check, for free.
    private func writeSlopes() -> CGFloat {
        let wide = cellsWide
        let high = cellsHigh
        let scale = 0.5 / WaterTuning.maxSlope
        var peak: Float = 0

        height.withUnsafeBufferPointer { h in
            scratch.withUnsafeMutableBufferPointer { s in
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
}
