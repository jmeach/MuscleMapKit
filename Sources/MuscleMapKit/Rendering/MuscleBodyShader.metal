#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Surface shader for the continuous muscle body.
///
/// Interpolated vertex colors already mix graphite, idle anatomy, and the
/// intensity ramp on the CPU. RealityKit's `.lit` CustomMaterial pipeline
/// exceeds the simulator's 31 texture-binding limit, so this shader runs as
/// an unlit CustomMaterial and reconstructs the three-light wrap plus the
/// original red-dominant emissive glow in `set_emissive_color`.
[[visible]]
void muscleMapSurface(realitykit::surface_parameters params)
{
    float4 vertexColor = params.geometry().color();
    half3 color = half3(vertexColor.xyz);

    params.surface().set_base_color(color);
    params.surface().set_roughness(0.48h);
    params.surface().set_metallic(0.10h);

    float3 n = normalize(params.geometry().normal());
    float3 lKey = normalize(float3(-1.6, 1.6, 2.2));
    float3 lFill = normalize(float3(1.8, 0.4, 1.6));
    float3 lRim = normalize(float3(0.4, 1.4, -2.6));
    float diffuse = 0.14
        + 0.50 * saturate(dot(n, lKey))
        + 0.18 * saturate(dot(n, lFill))
        + 0.32 * saturate(dot(n, lRim));
    half3 shaded = color * half(saturate(diffuse));

    half redness = color.r - max(color.g, color.b);
    half glow = clamp(redness * 1.5h, 0.0h, 0.55h);
    params.surface().set_emissive_color(shaded + color * glow);
}
