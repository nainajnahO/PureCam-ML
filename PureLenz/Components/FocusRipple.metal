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

/// A droplet ripple, as a `distortionEffect` on the viewfinder.
///
/// Returns, for each destination pixel, the position to sample the source from —
/// so displacing that sample point outward along the radius makes the scene
/// itself bulge, exactly the way a lens does. Nothing is drawn over the camera;
/// what moves is the camera image.
///
/// Every point sits still until the wavefront reaches it (`dist / speed`), then
/// oscillates once through a crest and a trough and settles. That delay is what
/// makes the ring *travel* rather than the whole area pulsing together.
///
/// Two independent decays keep it a local disturbance instead of a screen-wide
/// wobble: `decay` fades the oscillation over time at any given point, and
/// `radius` fades its amplitude with distance from the tap.
///
/// - Parameters:
///   - position: Destination pixel, in the view's own points.
///   - origin: The tap point, same space.
///   - time: Seconds since the tap.
///   - amplitude: Peak sample displacement, in points. Bounds `maxSampleOffset`.
///   - frequency: Oscillation rate, radians per second.
///   - decay: Temporal falloff; larger settles sooner.
///   - speed: How fast the wavefront travels outward, points per second.
///   - radius: Distance over which the ripple dies out, in points.
[[ stitchable ]] float2 focusRipple(
    float2 position,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed,
    float radius
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

    float offset = amplitude
        * sin(frequency * local)
        * exp(-decay * local)
        * exp(-dist / radius);

    return position + (delta / dist) * offset;
}
