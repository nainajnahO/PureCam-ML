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

    func body(content: Content) -> some View {
        content
            .modifier(RippleWave(waveTime: waveTime, origin: origin))
            // `task(id:)` rather than `onChange`: this runs on appear *and* on
            // change, so it covers a lens that reports back before the copy is
            // even on screen — which `onChange` alone would sleep straight
            // through, leaving the warp hanging forever.
            .task(id: settled) {
                if settled {
                    withAnimation(.easeOut(duration: Self.releaseSeconds)) {
                        waveTime = Self.waveLife
                    }
                } else {
                    withAnimation(.easeOut(duration: Self.sustainSpan)) {
                        waveTime = Self.sustainTarget
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

    // `nonisolated` because a SwiftUI view's members are main-actor isolated by
    // default and the shader arguments are read outside that. Immutable Sendable
    // scalars, so opting them out is free.

    /// Peak sample displacement, in points. Also bounds `maxSampleOffset`, which
    /// tells SwiftUI how far outside its bounds the effect may reach.
    nonisolated private static let amplitude: Float = 18
    /// ~1.75Hz. Slow enough that a crest is still legible while the wave waits.
    nonisolated private static let frequency: Float = 11
    /// Low, so the wave survives long enough to be held. The release ends it.
    nonisolated private static let decay: Float = 2.0
    /// Wavefront speed, points per second of wave-time. Slow enough that the
    /// crest is still near the tap while the lens works, rather than having run
    /// off-screen with nothing left to linger.
    nonisolated private static let speed: Float = 500
    /// Distance over which the ripple dies out. Keeps it a local disturbance at
    /// the tap rather than a screen-wide wobble.
    nonisolated private static let radius: Float = 200

    func body(content: Content) -> some View {
        let time = Float(waveTime)
        let x = Float(origin.x)
        let y = Float(origin.y)

        return content.distortionEffect(
            ShaderLibrary.focusRipple(
                .float2(x, y),
                .float(time),
                .float(Self.amplitude),
                .float(Self.frequency),
                .float(Self.decay),
                .float(Self.speed),
                .float(Self.radius)
            ),
            maxSampleOffset: CGSize(
                width: CGFloat(Self.amplitude), height: CGFloat(Self.amplitude)
            ),
            // Off at rest, so the copy is never shown through an idle shader pass.
            isEnabled: time > 0
        )
    }
}
