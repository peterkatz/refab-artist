#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// MatCap (material-capture / lit-sphere) surface shader for the imported model.
//
// A MatCap reads sculptural form far better than PBR+lighting because the shade
// is sampled from a pre-lit sphere image by the *view-space* surface normal — it
// needs no scene lights, no environment, and no UVs (exactly what ZBrush, Blender
// sculpt mode, and Sketchfab use).
//
// The bound texture is a NEUTRAL (grayscale) lit sphere that encodes only the
// surface character (matte / satin / glossy / toon). The base-color tint is the
// user's object colour. To let ANY colour work with a believable finish, the tint
// is applied to the diffuse/shadow tones only; the bright specular hotspot stays
// achromatic white (a red ball still has a white highlight, not a red one). This
// is a "split-tone" MatCap — one neutral capture recolours to any hue.
//
// Built with: tools/shaders/build_matcap.sh  →  Resources/matcap.metallib
[[visible]]
void neoMatcapSurface(realitykit::surface_parameters params)
{
    float3 nWorld = normalize(params.geometry().normal());
    float4x4 w2v = params.uniforms().world_to_view();
    float3 nView = normalize(float3x3(w2v.columns[0].xyz,
                                      w2v.columns[1].xyz,
                                      w2v.columns[2].xyz) * nWorld);

    // View-space normal → lit-sphere UV (Metal samples from the top-left).
    float2 uv = float2(nView.x * 0.5 + 0.5, 1.0 - (nView.y * 0.5 + 0.5));

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    // Neutral capture: grayscale, so any channel is the shading luminance.
    half L = params.textures().base_color().sample(s, uv).r;
    half3 tint = half3(params.material_constants().base_color_tint());

    // Keep the specular hotspot white — but only to the extent the object colour
    // is actually saturated. A near-neutral clay barely desaturates (so it reads
    // like the plain plaster look, not a field of white facet glints), while a
    // saturated colour gets a proper white highlight instead of a coloured one.
    half chroma = max(tint.r, max(tint.g, tint.b)) - min(tint.r, min(tint.g, tint.b));
    half hotspot = smoothstep(0.86h, 1.0h, L) * clamp(chroma * 2.2h, 0.0h, 1.0h);
    half3 tone = mix(tint, half3(1.0h), hotspot);

    // Fixed gain: the viewport tone-maps the unlit emissive down, so lift it back.
    // Tuned so a neutral capture × plaster colour matches the pre-redesign look.
    const half kEmissiveGain = 1.32h;

    // Unlit model: the displayed colour comes from emissive (see RealityKit docs).
    params.surface().set_emissive_color(tone * L * kEmissiveGain);
    params.surface().set_base_color(half3(0.0h));
}
