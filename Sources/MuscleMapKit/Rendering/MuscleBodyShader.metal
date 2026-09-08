#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Selected-muscle halo color. Close to `MuscleBodyStyle.selectedColor` in both
/// palettes so selection reads as a brighter member of the existing red family
/// rather than a new hue.
constant half3 kSelectionTint = half3(1.0h, 0.22h, 0.18h);
/// Flat glow across the selected region so front-facing geometry still reads as
/// selected where the silhouette rim is weak.
constant half kSelectionInterior = 0.20h;
/// Edge halo along the selected region's silhouette and contours.
constant half kSelectionRim = 0.85h;

/// Surface shader for the continuous muscle body.
///
/// Interpolated vertex colors already mix graphite, idle anatomy, and the
/// intensity ramp on the CPU. RealityKit's `.lit` CustomMaterial pipeline
/// exceeds the simulator's 31 texture-binding limit, so this shader runs as
/// an unlit CustomMaterial and reconstructs the three-light wrap plus the
/// original red-dominant emissive glow in `set_emissive_color`.
///
/// The vertex color's fourth component is a private data channel, not opacity:
/// `MuscleBodyMaterial.writeVertexColors` writes the selected-muscle mask there.
/// The selection halo derives only from that mask, so an intensely worked but
/// unselected muscle never looks selected.
[[visible]]
void muscleMapSurface(realitykit::surface_parameters params)
{
    float4 vertexColor = params.geometry().color();
    half3 color = half3(vertexColor.xyz);
    half selection = half(saturate(vertexColor.w));

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
    half3 emissive = shaded + color * glow;

    if (selection > 0.0h) {
        float3 viewDirection = normalize(params.geometry().view_direction());
        half fresnel = half(pow(saturate(1.0 - abs(dot(n, viewDirection))), 2.0));
        half halo = selection * (kSelectionInterior + fresnel * kSelectionRim);
        emissive += kSelectionTint * halo;
    }

    params.surface().set_emissive_color(emissive);
}
