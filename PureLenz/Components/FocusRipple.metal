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

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

/// A punched waterbed, as a `distortionEffect` on the viewfinder.
///
/// Returns, for each destination pixel, the position to sample the source from —
/// so displacing that sample point outward along the radius makes the scene
/// itself bulge, exactly the way a lens does. Nothing is drawn over the camera;
/// what moves is the camera image.
///
/// Every point sits still until the wavefront reaches it (`dist / speed`), then
/// oscillates once through a crest and a trough and settles. That delay is what
/// makes the wobble *spread* rather than the whole area pulsing together.
///
/// The spatial profile is the slope of a Gaussian dent of width `sigma`. A
/// membrane refracts by its slope, not its depth: the middle of the dent is its
/// flattest point, so the tap point itself stays optically still and the action
/// is a soft bulge ringing it, peaking at `sigma` and gone by ~2.5 `sigma`. This
/// is also what keeps the centre from acting as a black hole — near the origin
/// the offset grows like `amplitude · e^0.5 · dist / sigma`, so as long as
/// `sigma` stays comfortably above ~3× `amplitude`, sample positions can never
/// converge on or cross the tap point.
///
/// - Parameters:
///   - position: Destination pixel, in the view's own points.
///   - origin: The tap point, same space.
///   - time: Seconds since the tap.
///   - amplitude: Peak sample displacement, in points. Bounds `maxSampleOffset`.
///   - frequency: Oscillation rate, radians per second.
///   - decay: Temporal falloff; larger settles sooner.
///   - speed: How fast the wavefront travels outward, points per second.
///   - sigma: Width of the dent, in points — where the bulge peaks.
[[ stitchable ]] float2 focusRipple(
    float2 position,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed,
    float sigma
) {
    float2 delta = position - origin;
    float dist = length(delta);

    // Dead centre has no outward direction to displace along, and normalizing a
    // zero vector is undefined.
    if (dist < 0.001) {
        return position;
    }

    // The wavefront has not arrived here yet, so this point has not moved.
    float local = time - dist / speed;
    if (local <= 0.0) {
        return position;
    }

    // Slope of a Gaussian dent of width sigma, normalized to peak at 1 where
    // dist == sigma.
    float slope = (dist / sigma) * exp(0.5 - (dist * dist) / (2.0 * sigma * sigma));

    float offset = amplitude
        * sin(frequency * local)
        * exp(-decay * local)
        * slope;

    return position + (delta / dist) * offset;
}
