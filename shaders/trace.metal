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
};

hit SceneIntersection(ray Ray,
                      instance_acceleration_structure Accel,
                      device const petey_vertex *Vertices,
                      device const uint *Indices,
                      device const mesh_info *MeshInfos)
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
			float3 N0 = Vertices[M.VertexOffset + I0].Normal;
			float3 N1 = Vertices[M.VertexOffset + I1].Normal;
			float3 N2 = Vertices[M.VertexOffset + I2].Normal;
			float2 B = Hit.triangle_barycentric_coord;
			float W = 1.0 - B.x - B.y;
			Result.Normal = normalize(W*N0 + B.x*N1 + B.y*N2);
			Result.Colour = Result.Normal;
		}

		float GroundHeight = 7.975258;
		float GroundDenominator = dot(float3(0, 1, 0), Ray.direction);
		if(abs(GroundDenominator) > 0.0001)
		{
			float T = dot((float3(0, GroundHeight, 0) - Ray.origin), float3(0, 1, 0)) / GroundDenominator;
			if (T >= 0.0 && T < Hit.distance) {
				Result.Colour = float3(1, 0, 0);
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
    texture2d<float, access::write> OutImage [[texture(0)]],
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
	
	ray CameraRay;
	CameraRay.origin = CameraPosition;
	CameraRay.direction = normalize(Forward * CameraFocalLength + Right * Screen.x + Up * Screen.y);
	CameraRay.min_distance = 0.001;
	CameraRay.max_distance = 1e6;

	hit CameraHit = SceneIntersection(CameraRay, Accel, Vertices, Indices, MeshInfos);


	float3 SunDirection = normalize(float3(1.0, 0.5, 0.0));
	ray ShadowRay;
	ShadowRay.origin = CameraHit.Position + SunDirection * 0.0001;
	ShadowRay.direction = SunDirection;
	ShadowRay.min_distance = 0.001;
	ShadowRay.max_distance = 1e6;

	hit ShadowHit = SceneIntersection(ShadowRay, Accel, Vertices, Indices, MeshInfos);

	float3 Color = CameraHit.Colour;
	if(ShadowHit.AnyHit)
	{
		Color *= 0.5;
	}

	int BounceCount = 8;
	for(int I = 0; I < BounceCount; I++)
	{

	}

	OutImage.write(float4(Color, 1.0), PositionInGrid);
}
