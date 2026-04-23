#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

constant float3 CameraTarget = float3(363.43, 6.94, -96.21);
constant float3 CameraOffset = float3(-850.0, 280.0, -650.0);
constant float3 CameraWorldUp = float3(0.0, 1.0, 0.0);
constant float CameraFocalLength = 1.45;


kernel void Raytrace(
    instance_acceleration_structure Accel [[buffer(0)]],
    texture2d<float, access::write> OutImage [[texture(0)]],
    uint2 PositionInGrid [[thread_position_in_grid]])
{
	if (PositionInGrid.x >= OutImage.get_width() || PositionInGrid.y >= OutImage.get_height())
		return;

	float2 UV = (float2(PositionInGrid) + 0.5) / float2(OutImage.get_width(), OutImage.get_height());
	float2 NDC  = UV * 2.0 - 1.0;
	float AspectRatio = float(OutImage.get_width()) / float(OutImage.get_height());
	float2 Screen = float2(NDC.x * AspectRatio, -NDC.y);

	ray Ray;
	float3 CameraPosition = CameraTarget + CameraOffset;
	float3 Forward = normalize(CameraTarget - CameraPosition);
	float3 Right = normalize(cross(Forward, CameraWorldUp));
	float3 Up = normalize(cross(Right, Forward));

	Ray.origin = CameraPosition;
	Ray.direction = normalize(Forward * CameraFocalLength + Right * Screen.x + Up * Screen.y);
	Ray.min_distance = 0.001;
	Ray.max_distance = 1e6;

	float3 Color = float3(UV.x, UV.y, 0.15);

	intersector<instancing, triangle_data> Intersector;
	intersection_result<instancing, triangle_data> Hit = Intersector.intersect(Ray, Accel);

	if (Hit.type != intersection_type::none)
	{
		uint InstanceID = Hit.instance_id;
		Color = 0.25 + 0.75 * float3(float(((InstanceID + 1u) * 97u) & 255u) / 255.0,
									 float(((InstanceID + 1u) * 57u) & 255u) / 255.0,
									 float(((InstanceID + 1u) * 23u) & 255u) / 255.0);
	}

	OutImage.write(float4(Color, 1.0), PositionInGrid);
}
