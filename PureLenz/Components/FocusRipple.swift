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

extension View {
    /// Ripples this view outward from `origin`, releasing when `settled` flips.
    /// Applied to the app-drawn copy of the viewfinder — see `FocusRipple`.
    func focusRipple(origin: CGPoint, settled: Bool) -> some View {
        modifier(FocusRipple(origin: origin, settled: settled))
    }
}

/// A droplet ripple run across the viewfinder by `FocusRipple.metal`, lasting
/// exactly as long as the focus it reports.
///
/// The shader displaces where each pixel is *sampled from*, so the scene itself
/// bulges and settles rather than having anything drawn over it — a picture of
/// what the hardware is doing, since a lens is curved glass and it is refocusing.
///
/// **Why this is applied to a copy and not the viewfinder.** A shader effect
/// needs SwiftUI to rasterize the view it is attached to. The live viewfinder is
/// an `AVCaptureVideoPreviewLayer` inside a `UIViewRepresentable` — a video pane
/// the system paints straight to the screen, whose pixels SwiftUI's renderer
/// never has. Attaching a shader to it replaced the whole preview with SwiftUI's
/// unavailable-view placeholder. So for the length of the ripple the app draws
/// the camera itself and distorts what it draws. See
/// `CameraViewModel.runFocusRipple`.
///
/// **Why the wave lingers rather than simply running longer.** The ripple starts
/// the instant the screen is tapped, but focus does not report back until later,
/// so there is no duration to stretch the wave to at the moment it begins. One
/// wave can only span an unknown length if it has somewhere to wait. So the
/// clock driving it eases *out*: the wave unfolds at full pace, then slows to a
/// crawl and hangs in its own tail until the lens lands, at which point
/// `settled` releases it. One warp, one wave equation, a variable-rate clock —
/// no second ring and no separate confirmation beat.
///
/// This is why the shader is tuned slow and long-lived (`decay` 2.0 rather than
/// 7, `speed` 500 rather than 1400): a wave tuned to die in 0.7s has nothing
/// left to hold with. The release is what kills it now, not the decay.
struct FocusRipple: ViewModifier {
    /// Wave-time at which the wave is fully spent. Not seconds on the clock —
    /// the clock runs at whatever rate the focus wait demands.
    private static let waveLife: Double = 1.3

    /// How far into its life the wave creeps while waiting on the lens. Short of
    /// `waveLife`, so there is always something left to release.
    private static let sustainTarget: Double = 0.9

    /// Real seconds the unfold-and-linger phase is spread over. `easeOut` puts
    /// most of the movement at the front, so the tap is answered immediately and
    /// the slowing happens in the tail. Sized past `CameraService`'s focus
    /// timeout so the wave is still holding when even a slow lens gives up.
    private static let sustainSpan: TimeInterval = 1.7

    /// Real seconds from the lens landing to the scene being still.
    static let releaseDuration: Duration = .seconds(0.32)
    private static let releaseSeconds: TimeInterval = 0.32

    let origin: CGPoint
    /// Flips once the lens has stopped scanning; see `CameraViewModel.focusSettled`.
    let settled: Bool

    @State private var waveTime: Double = 0
    @State private var dotsVisible = false

    /// Real seconds for the dots to reach full brightness. Fast on purpose: a
    /// quick lens can settle in well under a second, and the extended-range
    /// glow only registers if the dots are at full strength for most of that.
    private static let dotsFadeInSeconds: TimeInterval = 0.15

    func body(content: Content) -> some View {
        content
            .modifier(RippleWave(waveTime: waveTime, origin: origin))
            // The dot matrix stays *outside* the warp — the distortion pass
            // clamps extended-range colour to SDR, so the dots displace
            // themselves with the same wave instead (see `RippleDotMatrix`).
            .overlay {
                RippleDotMatrix(waveTime: waveTime)
                    .position(origin)
                    .opacity(dotsVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // `task(id:)` rather than `onChange`: this runs on appear *and* on
            // change, so it covers a lens that reports back before the copy is
            // even on screen — which `onChange` alone would sleep straight
            // through, leaving the warp hanging forever.
            .task(id: settled) {
                if settled {
                    withAnimation(.easeOut(duration: Self.releaseSeconds)) {
                        waveTime = Self.waveLife
                        dotsVisible = false
                    }
                } else {
                    withAnimation(.easeOut(duration: Self.sustainSpan)) {
                        waveTime = Self.sustainTarget
                    }
                    withAnimation(.easeOut(duration: Self.dotsFadeInSeconds)) {
                        dotsVisible = true
                    }
                }
            }
    }
}

/// Carries the wave's clock into the shader.
///
/// `Animatable` is what makes a plain `Double` interpolate: SwiftUI only
/// animates values it is told are animatable, and a number handed to a shader is
/// not one by default. Conforming here also means SwiftUI drives `waveTime` per
/// frame *inside this modifier*, without re-running the view that owns it.
private struct RippleWave: ViewModifier, Animatable {
    var waveTime: Double
    let origin: CGPoint

    var animatableData: Double {
        get { waveTime }
        set { waveTime = newValue }
    }

    func body(content: Content) -> some View {
        let time = Float(waveTime)
        let x = Float(origin.x)
        let y = Float(origin.y)

        return content.distortionEffect(
            ShaderLibrary.focusRipple(
                .float2(x, y),
                .float(time),
                .float(RippleTuning.amplitude),
                .float(RippleTuning.frequency),
                .float(RippleTuning.decay),
                .float(RippleTuning.speed),
                .float(RippleTuning.sigma)
            ),
            maxSampleOffset: CGSize(
                width: CGFloat(RippleTuning.amplitude),
                height: CGFloat(RippleTuning.amplitude)
            ),
            // Off at rest, so the copy is never shown through an idle shader pass.
            isEnabled: time > 0
        )
    }
}

/// Wave tuning shared by the shader (`RippleWave`) and the dot matrix
/// (`RippleDotMatrix`), which moves its dots with the same wave equation — one
/// set of numbers, or the dots and the scene would wobble to different waves.
private enum RippleTuning {
    /// Peak sample displacement, in points. Also bounds `maxSampleOffset`, which
    /// tells SwiftUI how far outside its bounds the effect may reach.
    static let amplitude: Float = 18
    /// ~1.75Hz. Slow enough that a crest is still legible while the wave waits.
    static let frequency: Float = 11
    /// Low, so the wave survives long enough to be held. The release ends it.
    static let decay: Float = 2.0
    /// Wavefront speed, points per second of wave-time. Slow enough that the
    /// crest is still near the tap while the lens works, rather than having run
    /// off-screen with nothing left to linger.
    static let speed: Float = 500
    /// Width of the dent — where the bulge peaks; the wobble is gone by about
    /// 2.5× this. Keep comfortably above ~3× `amplitude`, which is what makes a
    /// black-hole centre impossible (see `FocusRipple.metal`).
    static let sigma: Float = 90
}

/// The halftone sheen on the wobble: a fine grid of HDR-white dots centred on
/// the tap, fully lit over the bulge and faded out past where the waterbed
/// profile dies.
///
/// **Why the dots move themselves instead of sitting under the warp.** Running
/// them through `RippleWave` would keep them in lockstep with the scene for
/// free — but the distortion pass rasterizes what it wraps and clamps
/// extended-range colour to SDR (verified on device: the same dots glow outside
/// the warp and go flat inside it). Dots are discrete objects, so they don't
/// need the shader: each frame this view displaces every dot's position with
/// the wave equation from `FocusRipple.metal` — same maths, same `RippleTuning`
/// numbers, same `waveTime` clock — and draws it already-moved, in a plain
/// SwiftUI layer the renderer keeps in extended range.
///
/// `Animatable` for the same reason as `RippleWave`: it is what makes SwiftUI
/// interpolate `waveTime` per frame in here, on the very transactions that
/// drive the shader, so the dots and the scene ride one wave.
///
/// The edge fade is per-dot alpha rather than a `.mask` layer: every extra
/// compositing layer is another place the extended-range white could get
/// silently clamped to SDR.
private struct RippleDotMatrix: View, Animatable {
    var waveTime: Double

    var animatableData: Double {
        get { waveTime }
        set { waveTime = newValue }
    }

    /// Grid pitch, in points.
    private static let spacing: CGFloat = 7
    private static let dotDiameter: CGFloat = 2
    /// Brightness decays exponentially from the centre; ~63% is gone by this
    /// distance, halved every ~42pt.
    private static let falloff: CGFloat = 60
    /// Grid extent, and where the fade lands on exactly zero. The exponential
    /// alone never reaches zero — and a few percent of a two-stops-up white is
    /// still visible — so the last stretch is windowed down to nothing (see
    /// `fade`) instead of cut.
    private static let fadeEnd: CGFloat = 150
    /// Where that closing window starts.
    private static let windowStart: CGFloat = 90
    /// White pushed two stops past SDR white. `headroom(_:)` annotates the
    /// extended-range components so the renderer raises display headroom (or
    /// tone-maps) instead of clamping.
    private static let hdrWhite = Color(.sRGBLinear, red: 4, green: 4, blue: 4)
        .headroom(4)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let steps = Int(Self.fadeEnd / Self.spacing)
            let amplitude = Double(RippleTuning.amplitude)
            let frequency = Double(RippleTuning.frequency)
            let decay = Double(RippleTuning.decay)
            let speed = Double(RippleTuning.speed)
            let sigma = Double(RippleTuning.sigma)

            for row in -steps...steps {
                for col in -steps...steps {
                    // Fade and displacement both use the dot's rest position,
                    // so the fade circle stays put while the dots move.
                    let dist = Self.spacing * hypot(CGFloat(col), CGFloat(row))
                    guard dist < Self.fadeEnd else { continue }

                    let t = max(0, (dist - Self.windowStart) / (Self.fadeEnd - Self.windowStart))
                    let window = 1 - t * t * (3 - 2 * t)
                    let fade = exp(-dist / Self.falloff) * window

                    var x = center.x + CGFloat(col) * Self.spacing
                    var y = center.y + CGFloat(row) * Self.spacing

                    // The wave equation from FocusRipple.metal, with one sign
                    // flip: the shader moves where a pixel is *sampled from*,
                    // which moves the visible content the opposite way. The
                    // dots are content, so they take the negative.
                    let local = waveTime - Double(dist) / speed
                    if local > 0, dist > 0.001 {
                        let slope = (Double(dist) / sigma)
                            * exp(0.5 - Double(dist * dist) / (2 * sigma * sigma))
                        let offset = amplitude
                            * sin(frequency * local)
                            * exp(-decay * local)
                            * slope
                        x -= CGFloat(offset) * CGFloat(col) * Self.spacing / dist
                        y -= CGFloat(offset) * CGFloat(row) * Self.spacing / dist
                    }

                    let rect = CGRect(
                        x: x - Self.dotDiameter / 2,
                        y: y - Self.dotDiameter / 2,
                        width: Self.dotDiameter,
                        height: Self.dotDiameter
                    )
                    // Fade via the context's compositing alpha, not
                    // `Color.opacity`, so the colour value handed to the
                    // renderer — extended components and headroom annotation —
                    // is never rebuilt along the way.
                    context.opacity = fade
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Self.hdrWhite)
                    )
                }
            }
        }
        .frame(width: Self.fadeEnd * 2, height: Self.fadeEnd * 2)
    }
}
