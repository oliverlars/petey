#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

constant float Pi = 3.14159265358979323846;
constant uint AASamplesPerFrame = 4;
constant bool AccumulateFrames = true;
constant uint InvalidMaterialIndex = 0xffffffffu;
constant uint InvalidTextureIndex = 0xffffffffu;


struct hit {
	bool   AnyHit;
	float3 Position;
	float3 Colour;
	float  Roughness;
	float3 Normal;
	uint InstanceID;
	uint PrimitiveID;
	float2 Barycentrics;
	bool IsMesh;
};

struct petey_vertex {
	float3 Position;
	float3 Normal;
	float2 UV;
};

struct material {
	float4 AlbedoColour;
	float4 EmissiveColour;
	uint AlbedoIndex;
	uint RoughnessIndex;
	float Roughness;
	uint  _Pad[3];
};

struct mesh_info {
	uint VertexOffset;
	uint IndexOffset;
	uint NormalOffset;
	uint MaterialOffset;
	uint _Pad;
};

inline void BasisFromNormal(float3 Normal, thread float3& T, thread float3& B, thread float3& N)
{
	N = normalize(Normal);
	float Sign = copysign(1.0, N.z);
	float A = -1.0 / (Sign + N.z);
	float C = N.x * N.y * A;
	T = float3(1.0f + Sign * N.x * N.x * A, Sign * C, -Sign * N.x);
	B = float3(C, Sign + N.y * N.y * A, -N.y);
}

inline float Rand(thread uint& State)
{
	State = State * 747796405u + 2891336453u;
	uint Word = ((State >> ((State >> 28u) + 4u)) ^ State) * 277803737u;
	Word = (Word >> 22u) ^ Word;
	return float(Word) * (1.0 / 4294967296.0f);
}

float GGXNormalDistribution( float NdotH, float Roughness)
{
	float A = max(Roughness * Roughness, 0.001);
	float A2 = A * A;
	float D = ((NdotH * A2 - NdotH) * NdotH + 1.0);
	return A2 / max(D * D * Pi, 0.0001);
}

float SchlickMaskingTerm(float NdotL, float NdotV, float Roughness)
{
	float R = Roughness + 1.0;
	float K = (R * R) / 8.0;

	float Gv = NdotV / max(NdotV*(1.0 - K) + K, 0.0001);
	float Gl = NdotL / max(NdotL*(1.0 - K) + K, 0.0001);
	return Gv * Gl;
}

float3 SchlickFresnel(float3 F0, float LDotH)
{
	return F0 + (float3(1.0, 1.0, 1.0) - F0) * pow(1.0 - LDotH, 5.0f);
}

inline float3 SRGBToLinear(float3 Colour)
{
	return pow(Colour, float3(2.2));
}

// When using this function to sample, the probability density is:
//      pdf = D * NdotH / (4 * HdotV)
float3 GGXMicrofacet(thread uint& RngState, float Roughness, float3 HitNormal)
{
	// Get our uniform random numbers
	float2 Rng = float2(Rand(RngState), Rand(RngState));

	// Get an orthonormal basis from the normal
	float3 T, B, N;
	BasisFromNormal(HitNormal, T, B, N);

	// GGX NDF sampling
	float A = max(Roughness * Roughness, 0.001);
	float A2 = A * A;
	float CosThetaH = sqrt(max(0.0, (1.0 - Rng.x) / ((A2 - 1.0) * Rng.x + 1.0)));
	float SinThetaH = sqrt(max(0.0, 1.0 - CosThetaH * CosThetaH));
	float PhiH = Rng.y * M_PI_F * 2.0;

	// Get our GGX NDF sample (i.e., the half vector)
	return normalize(T * (SinThetaH * cos(PhiH)) +
	                 B * (SinThetaH * sin(PhiH)) +
	                 N * CosThetaH);
}

inline float3 CosineSampleHemisphere(float2 U)
{
	float R = sqrt(U.x);
	float Theta = 2.0f * M_PI_F * U.y;

	float X = R * cos(Theta);
	float Y = R * sin(Theta);
	float Z = sqrt(max(0.0f, 1.0f - U.x));

	return float3(X, Y, Z);
}

inline float3 RandomCosineHemisphere(float3 Normal, thread uint& RngState)
{
	float2 U = float2(Rand(RngState), Rand(RngState));
	float3 Local = CosineSampleHemisphere(U);

	float3 T, Bitangent, N;
	BasisFromNormal(Normal, T, Bitangent, N);

	return normalize(Local.x * T + Local.y * Bitangent + Local.z * N);
}

hit SceneIntersection(ray Ray,
                      instance_acceleration_structure Accel,
                      device const petey_vertex *Vertices,
                      device const uint *Indices,
                      device const mesh_info *MeshInfos,
                      device const float3 *InstanceNormals)
{
	hit Result = {};
	Result.Roughness = 1.0;
	{
		intersector<instancing, triangle_data> Intersector;
		intersection_result<instancing, triangle_data> Hit = Intersector.intersect(Ray, Accel);

		if (Hit.type != intersection_type::none)
		{
			uint InstanceID = Hit.instance_id;
			mesh_info M = MeshInfos[InstanceID];
			uint Tri = Hit.primitive_id;
			float2 B = Hit.triangle_barycentric_coord;
			Result.Colour = float3(1.0);
			Result.AnyHit = true;
			Result.IsMesh = true;
			Result.InstanceID = InstanceID;
			Result.PrimitiveID = Tri;
			Result.Barycentrics = B;
			Result.Position = Ray.origin + Hit.distance * Ray.direction;

			uint I0 = Indices[M.IndexOffset + Tri*3 + 0];
			uint I1 = Indices[M.IndexOffset + Tri*3 + 1];
			uint I2 = Indices[M.IndexOffset + Tri*3 + 2];
			float3 N0 = InstanceNormals[M.NormalOffset + I0];
			float3 N1 = InstanceNormals[M.NormalOffset + I1];
			float3 N2 = InstanceNormals[M.NormalOffset + I2];
			float W = 1.0 - B.x - B.y;
			Result.Normal = normalize(W*N0 + B.x*N1 + B.y*N2);
		}
	}

	return Result;
}

struct uniforms {
	float3   CameraOrigin;
	float3   CameraRight;
	float3   CameraUp;
	float3   CameraForward;
	float    CameraFOVTanX;
	float    CameraFOVTanY;
	int      Frame;
	float    Time;
};

kernel void Raytrace(
    instance_acceleration_structure Accel  [[buffer(0)]],
    device const petey_vertex *Vertices    [[buffer(1)]],
	device const uint *Indices             [[buffer(2)]],
	device const mesh_info *MeshInfos      [[buffer(3)]],
	device const float3 *InstanceNormals   [[buffer(4)]],
	device const uint *TriangleMaterialIDs [[buffer(5)]],
	device const material *Materials       [[buffer(6)]],
	constant uniforms *Uniforms            [[buffer(7)]],
	texture2d<float, access::read_write> OutImage [[texture(0)]],
	array<texture2d<float>, 127> Textures [[texture(1)]],
	uint2 PositionInGrid [[thread_position_in_grid]])
{
	if (PositionInGrid.x >= OutImage.get_width() || PositionInGrid.y >= OutImage.get_height())
		return;

	float2 ImageSize = float2(OutImage.get_width(), OutImage.get_height());

	float3 Forward = Uniforms->CameraForward;
	float3 Right = Uniforms->CameraRight;
	float3 Up = Uniforms->CameraUp;

	uint FrameIndex = uint(Uniforms->Frame);
	uint PixelIndex = PositionInGrid.x + PositionInGrid.y * OutImage.get_width();
	uint SampleCount = max(AASamplesPerFrame, 1u);
	float3 Radiance = float3(0.0);
	constexpr sampler TextureSampler(address::repeat, mag_filter::linear, min_filter::linear);

	for(uint SampleIndex = 0; SampleIndex < SampleCount; SampleIndex++)
	{
		uint RNG = PixelIndex ^ (FrameIndex * 747796405u) ^ ((SampleIndex + 1u) * 2891336453u) ^ 0x9e3779b9u;

		float2 UV = (float2(PositionInGrid) + float2(Rand(RNG), Rand(RNG))) / ImageSize;
		float2 NDC = UV * 2.0 - 1.0;
		float2 Screen = float2(NDC.x, -NDC.y);

		ray CameraRay;
		CameraRay.origin = Uniforms->CameraOrigin;
		CameraRay.direction = normalize(Forward +
			Right * Screen.x * Uniforms->CameraFOVTanX +
			Up * Screen.y * Uniforms->CameraFOVTanY);
		CameraRay.min_distance = 0.0001;
		CameraRay.max_distance = 1e6;

		int BounceCount = 4;
		ray Ray = CameraRay;
		float3 SampleRadiance = float3(0.0);
		float3 Throughput = float3(1.0);
		for(int I = 0; I < BounceCount; I++)
		{
			hit Hit = SceneIntersection(Ray, Accel, Vertices, Indices, MeshInfos, InstanceNormals);
			if(!Hit.AnyHit)
			{
				SampleRadiance += Throughput * float3(0.0);
				break;
			}
			if(Hit.IsMesh)
			{
				mesh_info M = MeshInfos[Hit.InstanceID];
				uint Tri = Hit.PrimitiveID;
				uint I0 = Indices[M.IndexOffset + Tri*3 + 0];
				uint I1 = Indices[M.IndexOffset + Tri*3 + 1];
				uint I2 = Indices[M.IndexOffset + Tri*3 + 2];
				float2 B = Hit.Barycentrics;
				float W = 1.0 - B.x - B.y;
				float2 UV0 = Vertices[M.VertexOffset + I0].UV;
				float2 UV1 = Vertices[M.VertexOffset + I1].UV;
				float2 UV2 = Vertices[M.VertexOffset + I2].UV;
				float2 SurfaceUV = W*UV0 + B.x*UV1 + B.y*UV2;

				uint MaterialID = TriangleMaterialIDs[M.MaterialOffset + Tri];
				if(MaterialID != InvalidMaterialIndex)
				{
					material Material = Materials[MaterialID];
					Hit.Colour = Material.AlbedoColour.xyz;
					if(Material.AlbedoIndex != InvalidTextureIndex)
					{
						Hit.Colour *= SRGBToLinear(Textures[Material.AlbedoIndex].sample(TextureSampler, SurfaceUV).rgb);
					}
					SampleRadiance += Throughput * Material.EmissiveColour.rgb;
					Hit.Roughness = saturate(Material.Roughness);
					if(Material.RoughnessIndex != InvalidTextureIndex)
					{
						Hit.Roughness *= Textures[Material.RoughnessIndex].sample(TextureSampler, SurfaceUV).r;
					}
					Hit.Roughness = clamp(Hit.Roughness, 0.02, 1.0);
				}
			}
			if(0)
			{
				float3 SunDirection = normalize(float3(1.0, 0.5, 0.0));
				float3 SunColour = float3(0.8, 0.4, 0.1);
				float NdotL = max(dot(Hit.Normal, SunDirection), 0.0);
				if(NdotL > 0.0)
				{
					ray ShadowRay;
					ShadowRay.origin = Hit.Position + SunDirection * 0.0001;
					ShadowRay.direction = SunDirection;
					ShadowRay.min_distance = 0.0001;
					ShadowRay.max_distance = 1e6;

					hit ShadowHit = SceneIntersection(ShadowRay, Accel, Vertices, Indices, MeshInfos, InstanceNormals);
					if(!ShadowHit.AnyHit)
					{
						SampleRadiance += Throughput * Hit.Colour * SunColour * NdotL * (1.0 / Pi);
					}
				}
			}
			
			if(0)
			{
				float3 PointLightPosition = float3(5, 3, 2);
				float3 PointLightColour = float3(250);

				float3 ToLight = PointLightPosition - Hit.Position;
				float DistanceToLight = length(ToLight);
				float3 LightDirection = ToLight / DistanceToLight;
				float NdotL = max(dot(Hit.Normal, LightDirection), 0.0);
				if(NdotL > 0.0)
				{
					ray ShadowRay;
					ShadowRay.direction = LightDirection;
					ShadowRay.origin = Hit.Position + LightDirection * 0.001;
					ShadowRay.min_distance = 0.001;
					ShadowRay.max_distance = max(DistanceToLight - 0.002, 0.001);

					float3 ViewDirection = -Ray.direction;
					float3 H = normalize(ViewDirection + LightDirection);
					float NdotH = saturate(dot(Hit.Normal, H));
					float LdotH = saturate(dot(LightDirection, H));
					float NdotV = saturate(dot(Hit.Normal, ViewDirection));

					float  D = GGXNormalDistribution(NdotH, Hit.Roughness);
					float  G = SchlickMaskingTerm(NdotL, NdotV, Hit.Roughness);
					float3 F = SchlickFresnel(float3(0.04), LdotH);
					float3 Specular = (D * G * F) / max(4.0 * NdotL * NdotV, 0.0001);
					float3 Diffuse = (float3(1.0) - F) * Hit.Colour * (1.0 / Pi);
					float3 Brdf = Diffuse + Specular;

					hit ShadowHit = SceneIntersection(ShadowRay, Accel, Vertices, Indices, MeshInfos, InstanceNormals);
					if(!ShadowHit.AnyHit)
					{
						SampleRadiance += Throughput * Brdf * PointLightColour * NdotL / (DistanceToLight * DistanceToLight);
					}
				}
			}

			Throughput *= Hit.Colour;
			Ray.origin = Hit.Position + Hit.Normal * 0.001;
			Ray.direction = RandomCosineHemisphere(Hit.Normal, RNG);
		}
		Radiance += SampleRadiance;
	}

	Radiance /= float(SampleCount);
	if(AccumulateFrames && FrameIndex > 0)
	{
		float3 PreviousRadiance = OutImage.read(PositionInGrid).xyz;
		float Blend = 1.0 / float(FrameIndex + 1u);
		Radiance = mix(PreviousRadiance, Radiance, Blend);
	}
	OutImage.write(float4(Radiance, 1.0), PositionInGrid);
}
