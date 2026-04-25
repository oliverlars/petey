#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

constant float3 CameraTarget = float3(535.803, 159.221, -129.582);
constant float3 CameraPosition = float3(1500, 300, 800);
constant float3 CameraWorldUp = float3(0.0, 1.0, 0.0);
constant float CameraVerticalFOVDegrees = 45.0;
constant float Pi = 3.14159265358979323846;


struct hit {
	bool   AnyHit;
	float3 Position;
	float3 Colour;
	float3 Normal;
};

struct petey_vertex {
	float3 Position;
	float3 Normal;
};

struct mesh_info {
	uint VertexOffset;
	uint IndexOffset;
	uint NormalOffset;
	uint _Pad;
};

inline float Rand(thread uint& State)
{
	State = State * 747796405u + 2891336453u;
	uint Word = ((State >> ((State >> 28u) + 4u)) ^ State) * 277803737u;
	Word = (Word >> 22u) ^ Word;
	return float(Word) * (1.0 / 4294967296.0f);
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

	float3 N = normalize(Normal);
	float Sign = copysign(1.0f, N.z);
	float A = -1.0f / (Sign + N.z);
	float B = N.x * N.y * A;
	float3 T = float3(1.0f + Sign * N.x * N.x * A, Sign * B, -Sign * N.x);
	float3 Bitangent = float3(B, Sign + N.y * N.y * A, -N.y);

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
	{
		intersector<instancing, triangle_data> Intersector;
		intersection_result<instancing, triangle_data> Hit = Intersector.intersect(Ray, Accel);

		if (Hit.type != intersection_type::none)
		{
			uint InstanceID = Hit.instance_id;
			Result.Colour = 0.25 + 0.75 * float3(float(((InstanceID + 1u) * 97u) & 255u) / 255.0,
										float(((InstanceID + 1u) * 57u) & 255u) / 255.0,
										float(((InstanceID + 1u) * 23u) & 255u) / 255.0);
			Result.AnyHit = true;
			Result.Position = Ray.origin + Hit.distance * Ray.direction;

			mesh_info M = MeshInfos[InstanceID];
			uint Tri = Hit.primitive_id;
			uint I0 = Indices[M.IndexOffset + Tri*3 + 0];
			uint I1 = Indices[M.IndexOffset + Tri*3 + 1];
			uint I2 = Indices[M.IndexOffset + Tri*3 + 2];
			float3 N0 = InstanceNormals[M.NormalOffset + I0];
			float3 N1 = InstanceNormals[M.NormalOffset + I1];
			float3 N2 = InstanceNormals[M.NormalOffset + I2];
			float2 B = Hit.triangle_barycentric_coord;
			float W = 1.0 - B.x - B.y;
			Result.Normal = normalize(W*N0 + B.x*N1 + B.y*N2);
			Result.Colour = float3(0.9);
		}

		float GroundHeight = 7.975258;
		float GroundDenominator = dot(float3(0, 1, 0), Ray.direction);
		if(abs(GroundDenominator) > 0.0001)
		{
			float T = dot((float3(0, GroundHeight, 0) - Ray.origin), float3(0, 1, 0)) / GroundDenominator;
			if (T >= 0.0 && T < Hit.distance) {
				Result.Colour = float3(0.5);
				Result.AnyHit = true;
				Result.Position = Ray.origin + T * Ray.direction;
				Result.Normal = float3(0, 1, 0);
			}
		}
	}

	return Result;
}

kernel void Raytrace(
    instance_acceleration_structure Accel [[buffer(0)]],
    device const petey_vertex *Vertices   [[buffer(1)]],
    device const uint *Indices            [[buffer(2)]],
    device const mesh_info *MeshInfos     [[buffer(3)]],
    device const float3 *InstanceNormals  [[buffer(4)]],
	device const int *Frame               [[buffer(5)]],
    texture2d<float, access::read_write> OutImage [[texture(0)]],
    uint2 PositionInGrid [[thread_position_in_grid]])
{
	if (PositionInGrid.x >= OutImage.get_width() || PositionInGrid.y >= OutImage.get_height())
		return;

	float2 UV = (float2(PositionInGrid) + 0.5) / float2(OutImage.get_width(), OutImage.get_height());
	float2 NDC  = UV * 2.0 - 1.0;
	float AspectRatio = float(OutImage.get_width()) / float(OutImage.get_height());
	float2 Screen = float2(NDC.x * AspectRatio, -NDC.y);

	float3 Forward = normalize(CameraTarget - CameraPosition);
	float3 UpSeed = abs(dot(Forward, CameraWorldUp)) > 0.98 ? float3(0.0, 0.0, 1.0) : CameraWorldUp;
	float3 Right = normalize(cross(Forward, UpSeed));
	float3 Up = normalize(cross(Right, Forward));
	float CameraVerticalFOVRadians = CameraVerticalFOVDegrees * (Pi / 180.0);
	float CameraFocalLength = 1.0 / tan(CameraVerticalFOVRadians * 0.5);

	uint RNG = (Frame[0]*(PositionInGrid.x + PositionInGrid.y * OutImage.get_width())) ^ 0x9e3779b9u;
	
	ray CameraRay;
	CameraRay.origin = CameraPosition;
	Screen += float2(Rand(RNG)/OutImage.get_width(), Rand(RNG)/OutImage.get_height());
	CameraRay.direction = normalize(Forward * CameraFocalLength + Right * Screen.x + Up * Screen.y);
	CameraRay.min_distance = 0.001;
	CameraRay.max_distance = 1e6;


	int BounceCount = 8;
	ray Ray = CameraRay;
	float3 Radiance = float3(0.0);
	float3 Throughput = float3(1.0);
	for(int I = 0; I < BounceCount; I++)
	{
		hit Hit = SceneIntersection(Ray, Accel, Vertices, Indices, MeshInfos, InstanceNormals);
		if(!Hit.AnyHit)
		{
			Radiance += Throughput * float3(0.1, 0.4, 0.8);
			break;
		}
		float3 SunDirection = normalize(float3(1.0, 0.5, 0.0));
		float3 SunColour = float3(0.8, 0.4, 0.1);
		float NdotL = max(dot(Hit.Normal, SunDirection), 0.0);
		if(NdotL > 0.0)
		{
			ray ShadowRay;
			ShadowRay.origin = Hit.Position + SunDirection * 0.0001;
			ShadowRay.direction = SunDirection;
			ShadowRay.min_distance = 0.001;
			ShadowRay.max_distance = 1e6;

			hit ShadowHit = SceneIntersection(ShadowRay, Accel, Vertices, Indices, MeshInfos, InstanceNormals);
			if(!ShadowHit.AnyHit)
			{
				Radiance += Throughput * Hit.Colour * SunColour * NdotL * (1.0 / Pi);
			}
		}

		Throughput *= Hit.Colour;
		Ray.origin = Hit.Position + Hit.Normal * 0.001;
		Ray.direction = RandomCosineHemisphere(Hit.Normal, RNG);

	}

	if(Frame[0] > 0)
	{
		Radiance = Radiance/(Frame[0] + 1) + OutImage.read(PositionInGrid).xyz;
	}
	OutImage.write(float4(Radiance, 1.0), PositionInGrid);
}