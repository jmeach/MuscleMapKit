#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Lit surface shader for the continuous muscle body.
///
/// Interpolated vertex colors already mix graphite, idle anatomy, and the
/// intensity ramp on the CPU. This shader preserves PBR lighting and adds a
/// restrained emissive glow only where the surface is red-dominant — the
/// same visual principle as the original SceneKit surface modifier.
[[visible]]
void muscleMapSurface(realitykit::surface_parameters params)
{
    float4 vertexColor = params.geometry().color();
    half3 color = half3(vertexColor.xyz);

    params.surface().set_base_color(color);
    params.surface().set_roughness(0.48h);
    params.surface().set_metallic(0.10h);

    half redness = color.r - max(color.g, color.b);
    half glow = clamp(redness * 1.5h, 0.0h, 0.55h);
    params.surface().set_emissive_color(color * glow);
}
