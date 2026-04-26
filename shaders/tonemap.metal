#include <metal_stdlib>
using namespace metal;

constant float3x3 AgxInsetMatrix = float3x3(
	float3(0.856627153315983, 0.137318972929847, 0.11189821299995),
	float3(0.0951212405381588, 0.761241990602591, 0.0767994186031903),
	float3(0.0482516061458583, 0.101439036467562, 0.811302368396859));

constant float3x3 AgxOutsetMatrix = float3x3(
	float3(1.1271005818144368, -0.1413297634984383, -0.14132976349843826),
	float3(-0.11060664309660323, 1.157823702216272, -0.11060664309660294),
	float3(-0.016493938717834573, -0.016493938717834257, 1.2519364065950405));

inline float3 AgxDefaultContrastApprox(float3 X)
{
	float3 X2 = X * X;
	float3 X4 = X2 * X2;

	return 15.5 * X4 * X2
		- 40.14 * X4 * X
		+ 31.96 * X4
		- 6.868 * X2 * X
		+ 0.4298 * X2
		+ 0.1191 * X
		- 0.00232;
}

inline float3 AgxTonemap(float3 Colour)
{
	const float MinEv = -12.47393;
	const float MaxEv = 4.026069;

	Colour = max(Colour, float3(0.0));
	Colour = AgxInsetMatrix * Colour;
	Colour = clamp(log2(max(Colour, float3(1e-10))), MinEv, MaxEv);
	Colour = (Colour - MinEv) / (MaxEv - MinEv);
	Colour = AgxDefaultContrastApprox(Colour);
	Colour = AgxOutsetMatrix * Colour;
	Colour = pow(max(Colour, float3(0.0)), float3(2.2));

	return saturate(Colour);
}

inline float3 LinearToSrgb(float3 Linear)
{
	Linear = saturate(Linear);
	float3 Low = 12.92 * Linear;
	float3 High = 1.055 * pow(Linear, float3(1.0 / 2.4)) - 0.055;
	return select(High, Low, Linear <= 0.0031308);
}

kernel void Tonemap(texture2d<float, access::read> HdrTexture [[texture(0)]],
                    texture2d<float, access::write> Framebuffer [[texture(1)]],
                    uint2 PositionInGrid [[thread_position_in_grid]])
{
	if(PositionInGrid.x >= HdrTexture.get_width() ||
	   PositionInGrid.y >= HdrTexture.get_height() ||
	   PositionInGrid.x >= Framebuffer.get_width() ||
	   PositionInGrid.y >= Framebuffer.get_height())
	{
		return;
	}

	float4 Hdr = HdrTexture.read(PositionInGrid);
	float3 Tonemapped = LinearToSrgb(AgxTonemap(Hdr.rgb));
	Framebuffer.write(float4(Tonemapped, Hdr.a), PositionInGrid);
}
