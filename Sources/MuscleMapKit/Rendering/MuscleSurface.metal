#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

[[visible]]
void muscleMapSurface(realitykit::surface_parameters params)
{
    auto geo = params.geometry();
    float4 vertexColor = geo.color();
    half3 color = half3(vertexColor.xyz);

    params.surface().set_base_color(color);

    float redness = vertexColor.x - max(vertexColor.y, vertexColor.z);
    float glow = saturate(redness * 1.5) * 0.55;
    params.surface().set_emissive_color(color * half(glow));

    params.surface().set_roughness(half(0.48));
    params.surface().set_metallic(half(0.10));
    params.surface().set_specular(half(0.45));
}
