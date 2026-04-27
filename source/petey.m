#include <Cocoa/Cocoa.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <assert.h>
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ufbx.h"

#include "stb_image.h"

#include "shaders.h"


typedef struct mesh_gpu_data
{
	id<MTLAccelerationStructure> BLAS;
	id<MTLBuffer> VertexBuffer;
	id<MTLBuffer> IndexBuffer;
	id<MTLBuffer> ScratchBuffer;
} mesh_gpu_data;

#define MAX_MATERIAL_TEXTURES 127

typedef struct gpu_texture_list
{
	id<MTLTexture> Items[MAX_MATERIAL_TEXTURES];
	uint32_t Count;
} gpu_texture_list;

typedef struct renderer
{
	id<MTLDevice> Device;
	id<MTLCommandQueue> Queue;
	id<MTLAccelerationStructure> TLAS;
	id<MTLBuffer> TLASInstanceBuffer;
	id<MTLBuffer> TLASScratchBuffer;
	mesh_gpu_data *Meshes;
	size_t MeshCount;
	id<MTLBuffer> GlobalVertexBuffer;
	id<MTLBuffer> GlobalIndexBuffer;
	id<MTLBuffer> MeshInfoBuffer;
	id<MTLBuffer> InstanceNormalsBuffer;
	id<MTLBuffer> TriangleMaterialBuffer;
	id<MTLBuffer> MaterialsBuffer;
	id<MTLFunction> RaytraceEntry;
	id<MTLFunction> TonemapEntry;
	id<MTLComputePipelineState> RaytracePipeline;
	id<MTLComputePipelineState> TonemapPipeline;
	id<MTLTexture> OutputImage;
	gpu_texture_list Textures;
} renderer;

typedef struct vertex {
	simd_float3 Position;
	simd_float3 Normal;
	simd_float2 UV;
} vertex;

typedef struct mesh_info {
	uint32_t VertexOffset;
	uint32_t IndexOffset;
	uint32_t NormalOffset;
	uint32_t MaterialOffset;
	uint32_t _Pad;
} mesh_info;

typedef struct material {
	uint32_t    AlbedoIndex;
	simd_float4 AlbedoColour;
	uint32_t    RoughnessIndex;
	float       Roughness;
	uint32_t    _Pad[2];
} material;

typedef struct bounds3
{
	ufbx_vec3 Min;
	ufbx_vec3 Max;
	int HasPoints;
} bounds3;

typedef struct render_scene
{
	bounds3 Bounds;
	gpu_texture_list Textures;
	id<MTLAccelerationStructure> TLAS;
	id<MTLBuffer> TLASInstanceBuffer;
	id<MTLBuffer> TLASScratchBuffer;
	mesh_gpu_data *Meshes;
	size_t MeshCount;
	id<MTLBuffer> GlobalVertexBuffer;
	id<MTLBuffer> GlobalIndexBuffer;
	id<MTLBuffer> MeshInfoBuffer;
	id<MTLBuffer> InstanceNormalsBuffer;
	id<MTLBuffer> TriangleMaterialBuffer;
	id<MTLBuffer> MaterialsBuffer;
} render_scene;

static mesh_gpu_data G_Meshes[4096];
static id<MTLAccelerationStructure> G_BLASs[4096];
static id G_ViewDelegate;

static ufbx_string PrependPathToFilename(const char *Path, ufbx_string Filename)
{
	ufbx_string Result = {0};
	if(!Path)
	{
		Path = "";
	}
	if(!Filename.data)
	{
		Filename.data = "";
		Filename.length = 0;
	}

	const char *BaseName = Filename.data;
	for(size_t Index = 0; Index < Filename.length; Index++)
	{
		if(Filename.data[Index] == '/' || Filename.data[Index] == '\\')
		{
			BaseName = Filename.data + Index + 1;
		}
	}

	size_t BaseNameLength = (size_t)((Filename.data + Filename.length) - BaseName);
	size_t PathLength = strlen(Path);
	while(PathLength > 0 && (Path[PathLength - 1] == '/' || Path[PathLength - 1] == '\\'))
	{
		PathLength--;
	}

	size_t SeparatorLength = PathLength > 0 ? 1 : 0;
	size_t ResultLength = PathLength + SeparatorLength + BaseNameLength;
	char *Data = malloc(ResultLength + 1);
	if(!Data)
	{
		return Result;
	}

	size_t WriteOffset = 0;
	memcpy(Data + WriteOffset, Path, PathLength);
	WriteOffset += PathLength;
	if(SeparatorLength)
	{
		Data[WriteOffset++] = '/';
	}
	memcpy(Data + WriteOffset, BaseName, BaseNameLength);
	WriteOffset += BaseNameLength;
	Data[WriteOffset] = 0;

	Result.data = Data;
	Result.length = ResultLength;
	return Result;
}

static void BoundsAddPoint(bounds3 *Bounds, ufbx_vec3 Point)
{
	if(!Bounds->HasPoints)
	{
		Bounds->Min = Point;
		Bounds->Max = Point;
		Bounds->HasPoints = 1;
		return;
	}

	Bounds->Min.x = Point.x < Bounds->Min.x ? Point.x : Bounds->Min.x;
	Bounds->Min.y = Point.y < Bounds->Min.y ? Point.y : Bounds->Min.y;
	Bounds->Min.z = Point.z < Bounds->Min.z ? Point.z : Bounds->Min.z;
	Bounds->Max.x = Point.x > Bounds->Max.x ? Point.x : Bounds->Max.x;
	Bounds->Max.y = Point.y > Bounds->Max.y ? Point.y : Bounds->Max.y;
	Bounds->Max.z = Point.z > Bounds->Max.z ? Point.z : Bounds->Max.z;
}

static bounds3 BoundsFromScene(ufbx_scene *Scene)
{
	bounds3 Result = {0};
	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		ufbx_mesh *Mesh = Node->mesh;
		if(!Mesh)
		{
			continue;
		}

		for(size_t VertexIndex = 0; VertexIndex < Mesh->vertices.count; VertexIndex++)
		{
			ufbx_vec3 Position = Mesh->vertices.data[VertexIndex];
			Position = ufbx_transform_position(&Node->geometry_to_world, Position);
			BoundsAddPoint(&Result, Position);
		}
	}
	return Result;
}

static ufbx_vec3 CenterFromBounds(bounds3 Bounds)
{
	ufbx_vec3 Result = {0};
	if(Bounds.HasPoints)
	{
		Result.x = 0.5 * (Bounds.Min.x + Bounds.Max.x);
		Result.y = 0.5 * (Bounds.Min.y + Bounds.Max.y);
		Result.z = 0.5 * (Bounds.Min.z + Bounds.Max.z);
	}
	return Result;
}

static ufbx_vec3 ExtentsFromBounds(bounds3 Bounds)
{
	ufbx_vec3 Result = {0};
	if(Bounds.HasPoints)
	{
		Result.x = Bounds.Max.x - Bounds.Min.x;
		Result.y = Bounds.Max.y - Bounds.Min.y;
		Result.z = Bounds.Max.z - Bounds.Min.z;
	}
	return Result;
}

static void RendererInit(renderer *R, MTKView *View, gpu_texture_list Textures, id<MTLAccelerationStructure> Accel, id<MTLBuffer> TLASInstanceBuffer, id<MTLBuffer> TLASScratchBuffer, mesh_gpu_data *Meshes, size_t MeshCount, id<MTLBuffer> GlobalVertexBuffer, id<MTLBuffer> GlobalIndexBuffer, id<MTLBuffer> MeshInfoBuffer, id<MTLBuffer> InstanceNormalsBuffer, id<MTLBuffer> TriangleMaterialBuffer, id<MTLBuffer> MaterialsBuffer, id<MTLFunction> RaytraceEntry, id<MTLFunction> TonemapEntry, id<MTLTexture> OutputImage)
{
	R->Device = View.device;
	R->Queue = [R->Device newCommandQueue];
	R->TLAS = Accel;
	R->TLASInstanceBuffer = TLASInstanceBuffer;
	R->TLASScratchBuffer = TLASScratchBuffer;
	R->Meshes = Meshes;
	R->MeshCount = MeshCount;
	R->GlobalVertexBuffer = GlobalVertexBuffer;
	R->GlobalIndexBuffer = GlobalIndexBuffer;
	R->MeshInfoBuffer = MeshInfoBuffer;
	R->InstanceNormalsBuffer = InstanceNormalsBuffer;
	R->TriangleMaterialBuffer = TriangleMaterialBuffer;
	R->MaterialsBuffer = MaterialsBuffer;
	R->RaytraceEntry = RaytraceEntry;
	R->TonemapEntry = TonemapEntry;
	R->OutputImage = OutputImage;
	R->Textures = Textures;
	View.clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);

	NSError *PipelineError = nil;
	R->RaytracePipeline = [R->Device newComputePipelineStateWithFunction:R->RaytraceEntry error:&PipelineError];
	if(!R->RaytracePipeline)
	{
		fprintf(stderr, "%s\n", PipelineError.localizedDescription.UTF8String);
		exit(1);
	}

	PipelineError = nil;
	R->TonemapPipeline = [R->Device newComputePipelineStateWithFunction:R->TonemapEntry error:&PipelineError];
	if(!R->TonemapPipeline)
	{
		fprintf(stderr, "%s\n", PipelineError.localizedDescription.UTF8String);
		exit(1);
	}
}

static void RendererDraw(renderer *R, MTKView *View)
{
	static int FrameCount = 0;
	CFTimeInterval FrameStart = CACurrentMediaTime();
	static CFTimeInterval StartTime = 0.0;
	if(StartTime == 0.0)
	{
		StartTime = FrameStart;
	}
	float Time = (float)(FrameStart - StartTime);
	id<CAMetalDrawable> Drawable = View.currentDrawable;
	CFTimeInterval DrawableReady = CACurrentMediaTime();
	if(!Drawable)
	{
		return;
	}

	id<MTLCommandBuffer> CommandBuffer = [R->Queue commandBuffer];
	id<MTLComputeCommandEncoder> ComputeEncoder = [CommandBuffer computeCommandEncoder];
	[ComputeEncoder setAccelerationStructure:R->TLAS atBufferIndex:0];
	[ComputeEncoder setBuffer:R->GlobalVertexBuffer offset:0 atIndex:1];
	[ComputeEncoder setBuffer:R->GlobalIndexBuffer offset:0 atIndex:2];
	[ComputeEncoder setBuffer:R->MeshInfoBuffer offset:0 atIndex:3];
	[ComputeEncoder setBuffer:R->InstanceNormalsBuffer offset:0 atIndex:4];
	[ComputeEncoder setBuffer:R->TriangleMaterialBuffer offset:0 atIndex:5];
	[ComputeEncoder setBuffer:R->MaterialsBuffer offset:0 atIndex:6];
	[ComputeEncoder setBytes:&FrameCount length:sizeof(int) atIndex:7];
	[ComputeEncoder setBytes:&Time length:sizeof(float) atIndex:8];
	[ComputeEncoder setComputePipelineState:R->RaytracePipeline];
	[ComputeEncoder setTexture:R->OutputImage atIndex:0];
	for(uint32_t TextureIndex = 0; TextureIndex < R->Textures.Count; TextureIndex++)
	{
		id<MTLTexture> Texture = R->Textures.Items[TextureIndex];
		if(Texture)
		{
			[ComputeEncoder setTexture:Texture atIndex:1 + TextureIndex];
		}
	}
	[ComputeEncoder useResource:R->TLAS usage:MTLResourceUsageRead];
	for(size_t MeshIndex = 0; MeshIndex < R->MeshCount; MeshIndex++)
	{
		[ComputeEncoder useResource:R->Meshes[MeshIndex].BLAS usage:MTLResourceUsageRead];
	}

	MTLSize GridSize = MTLSizeMake(R->OutputImage.width, R->OutputImage.height, 1);
	NSUInteger ThreadWidth = R->RaytracePipeline.threadExecutionWidth;
	NSUInteger ThreadHeight = R->RaytracePipeline.maxTotalThreadsPerThreadgroup / ThreadWidth;
	if(ThreadHeight == 0)
	{
		ThreadHeight = 1;
	}
	MTLSize ThreadgroupSize = MTLSizeMake(ThreadWidth, ThreadHeight, 1);
	[ComputeEncoder dispatchThreads:GridSize threadsPerThreadgroup:ThreadgroupSize];
	[ComputeEncoder endEncoding];

	id<MTLComputeCommandEncoder> TonemapEncoder = [CommandBuffer computeCommandEncoder];
	[TonemapEncoder setComputePipelineState:R->TonemapPipeline];
	[TonemapEncoder setTexture:R->OutputImage atIndex:0];
	[TonemapEncoder setTexture:Drawable.texture atIndex:1];

	MTLSize TonemapGridSize = MTLSizeMake(Drawable.texture.width, Drawable.texture.height, 1);
	NSUInteger TonemapThreadWidth = R->TonemapPipeline.threadExecutionWidth;
	NSUInteger TonemapThreadHeight = R->TonemapPipeline.maxTotalThreadsPerThreadgroup / TonemapThreadWidth;
	if(TonemapThreadHeight == 0)
	{
		TonemapThreadHeight = 1;
	}
	MTLSize TonemapThreadgroupSize = MTLSizeMake(TonemapThreadWidth, TonemapThreadHeight, 1);
	[TonemapEncoder dispatchThreads:TonemapGridSize threadsPerThreadgroup:TonemapThreadgroupSize];
	[TonemapEncoder endEncoding];

	[CommandBuffer addCompletedHandler:^(id<MTLCommandBuffer> CompletedBuffer) {
		if(CompletedBuffer.status == MTLCommandBufferStatusError)
		{
			fprintf(stderr, "Frame command buffer failed: %s\n", CompletedBuffer.error.localizedDescription.UTF8String);
		}
	}];
	[CommandBuffer presentDrawable:Drawable];
	[CommandBuffer commit];
	[CommandBuffer waitUntilCompleted];
	CFTimeInterval FrameEnd = CACurrentMediaTime();
	if((FrameCount % 60) == 0)
	{
		double DrawableMs = (DrawableReady - FrameStart) * 1000.0;
		double TotalMs = (FrameEnd - FrameStart) * 1000.0;
		double GpuMs = 0.0;
		if(CommandBuffer.GPUEndTime > CommandBuffer.GPUStartTime)
		{
			GpuMs = (CommandBuffer.GPUEndTime - CommandBuffer.GPUStartTime) * 1000.0;
		}
		printf("frame %d: total %.2fms, drawable %.2fms, gpu %.2fms\n", FrameCount, TotalMs, DrawableMs, GpuMs);
	}
	FrameCount += 1;
}

@interface petey_mtk_view_delegate : NSObject <MTKViewDelegate>
{
@public
	renderer *Renderer;
}
@end

@implementation petey_mtk_view_delegate
- (void)drawInMTKView:(MTKView *)View
{
	@autoreleasepool {
		RendererDraw(Renderer, View);
	}
}

- (void)mtkView:(MTKView *)View drawableSizeWillChange:(CGSize)Size
{
	(void)View;
	(void)Size;
}
@end

static NSWindow *CreateWindow(id<MTLDevice> Device, MTKView **ViewOut)
{
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	[NSApp finishLaunching];

	NSRect Frame = NSMakeRect(0, 0, 800, 600);
	NSWindow *Window = [[NSWindow alloc]
		initWithContentRect:Frame
				  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
					backing:NSBackingStoreBuffered
					  defer:NO];
	[Window setReleasedWhenClosed:NO];
	[Window center];
	[Window setTitle:@"petey"];

	MTKView *View = [[MTKView alloc] initWithFrame:Frame device:Device];
	View.colorPixelFormat = MTLPixelFormatBGRA10_XR;
	View.framebufferOnly = NO;
	View.paused = NO;
	View.enableSetNeedsDisplay = NO;
	View.preferredFramesPerSecond = 120;

	[Window setContentView:View];
	[Window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];

	*ViewOut = View;
	return Window;
}

static MTLPackedFloat4x3 PackedMatrixFromUfbx(ufbx_matrix M)
{
	MTLPackedFloat4x3 Result;
	Result.columns[0] = MTLPackedFloat3Make(M.m00, M.m10, M.m20);
	Result.columns[1] = MTLPackedFloat3Make(M.m01, M.m11, M.m21);
	Result.columns[2] = MTLPackedFloat3Make(M.m02, M.m12, M.m22);
	Result.columns[3] = MTLPackedFloat3Make(M.m03, M.m13, M.m23);
	return Result;
}

mesh_gpu_data BLASFromMesh(id<MTLDevice> Device, id<MTLCommandQueue> Queue, vertex *Vertices, size_t VertexCount, uint32_t *Indices, size_t IndexCount)
{
	id<MTLBuffer> VertexBuffer = [Device newBufferWithBytes:Vertices
										length:sizeof(vertex)*VertexCount
									options:MTLResourceStorageModeShared];
	id<MTLBuffer> IndexBuffer = [Device newBufferWithBytes:Indices
														length:IndexCount*sizeof(Indices[0])
													options:MTLResourceStorageModeShared];

	MTLAccelerationStructureTriangleGeometryDescriptor *AccelTriangleDesc = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
	AccelTriangleDesc.vertexBuffer = VertexBuffer;
	AccelTriangleDesc.vertexBufferOffset = 0;
	AccelTriangleDesc.vertexStride = sizeof(vertex);
	AccelTriangleDesc.vertexFormat = MTLAttributeFormatFloat3;

	AccelTriangleDesc.indexBuffer = IndexBuffer;
	AccelTriangleDesc.indexBufferOffset = 0;
	AccelTriangleDesc.indexType = MTLIndexTypeUInt32;

	AccelTriangleDesc.triangleCount = IndexCount/3;
	AccelTriangleDesc.opaque = YES;

	MTLPrimitiveAccelerationStructureDescriptor *AccelDesc = [MTLPrimitiveAccelerationStructureDescriptor descriptor];
	AccelDesc.geometryDescriptors = @[AccelTriangleDesc];

	MTLAccelerationStructureSizes Sizes = [Device accelerationStructureSizesWithDescriptor:AccelDesc];

	id<MTLAccelerationStructure> Accel = [Device newAccelerationStructureWithSize:Sizes.accelerationStructureSize];

	id<MTLBuffer> Scratch = [Device newBufferWithLength:Sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];

	id<MTLCommandBuffer> Cmd = [Queue commandBuffer];
	id<MTLAccelerationStructureCommandEncoder> ASCmd = [Cmd accelerationStructureCommandEncoder];
	[ASCmd buildAccelerationStructure:Accel descriptor:AccelDesc scratchBuffer:Scratch scratchBufferOffset:0];
	[ASCmd endEncoding];
	[Cmd commit];
	[Cmd waitUntilCompleted];

	mesh_gpu_data Result = {0};
	Result.BLAS = Accel;
	Result.VertexBuffer = VertexBuffer;
	Result.IndexBuffer = IndexBuffer;
	Result.ScratchBuffer = Scratch;
	return Result;
}

static render_scene LoadRenderSceneFromFbx(ufbx_scene *Scene, const char *TextureRoot, id<MTLDevice> Device, id<MTLCommandQueue> Queue)
{
	render_scene Result = {0};

	bounds3 SceneBounds = BoundsFromScene(Scene);
	ufbx_vec3 SceneCenter = CenterFromBounds(SceneBounds);
	ufbx_vec3 SceneExtents = ExtentsFromBounds(SceneBounds);
	Result.Bounds = SceneBounds;

	if(SceneBounds.HasPoints)
	{
		printf("Car bounds min:    (%.3f, %.3f, %.3f)\n", SceneBounds.Min.x, SceneBounds.Min.y, SceneBounds.Min.z);
		printf("Car bounds max:    (%.3f, %.3f, %.3f)\n", SceneBounds.Max.x, SceneBounds.Max.y, SceneBounds.Max.z);
		printf("Car rough center:  (%.3f, %.3f, %.3f)\n", SceneCenter.x, SceneCenter.y, SceneCenter.z);
		printf("Car rough extents: (%.3f, %.3f, %.3f)\n", SceneExtents.x, SceneExtents.y, SceneExtents.z);
	}
	else
	{
		printf("Car rough center: no mesh vertices found, using shader defaults\n");
	}

	printf("Ground plane height: %f\n", SceneBounds.Min.y);
	printf("Node count: %zu\n", Scene->nodes.count);
	printf("Mesh count: %zu\n", Scene->meshes.count);
	printf("Material count: %zu\n", Scene->materials.count);
	printf("Texture count: %zu\n", Scene->textures.count);
	printf("Lights count: %zu\n", Scene->lights.count);
	printf("Cameras count: %zu\n", Scene->cameras.count);

	gpu_texture_list Textures = {0};
	uint32_t *TextureToGpuIndex = calloc(Scene->textures.count, sizeof(uint32_t));
	for(size_t TextureIndex = 0; TextureIndex < Scene->textures.count; TextureIndex++)
	{
		TextureToGpuIndex[TextureIndex] = UINT32_MAX;
	}

	for(size_t TextureIndex = 0; TextureIndex < Scene->textures.count; TextureIndex++)
	{
		ufbx_texture *UFBXTexture = Scene->textures.data[TextureIndex];
		uint32_t TextureSlot = UFBXTexture->typed_id;
		if(TextureSlot >= MAX_MATERIAL_TEXTURES || TextureSlot >= Scene->textures.count)
		{
			fprintf(stderr, "Skipping texture %zu: texture slot %u is out of range.\n", TextureIndex, TextureSlot);
			continue;
		}

		ufbx_string Filename = PrependPathToFilename(TextureRoot, UFBXTexture->absolute_filename);
		printf("Texture %zu: %.*s\n", TextureIndex, (int)Filename.length, Filename.data);

		int Width = 0;
		int Height = 0;
		int Channels = 0;
		stbi_uc *Pixels = stbi_load(Filename.data, &Width, &Height, &Channels, 4);
		if(!Pixels)
		{
			fprintf(stderr, "Failed to load texture: %.*s\n", (int)Filename.length, Filename.data);
			free((void *)Filename.data);
			continue;
		}

		MTLTextureDescriptor *Desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
																						width:Width
																					   height:Height
																					mipmapped:NO];
		Desc.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> Texture = [Device newTextureWithDescriptor:Desc];
		if(!Texture)
		{
			fprintf(stderr, "Failed to create Metal texture: %.*s\n", (int)Filename.length, Filename.data);
			stbi_image_free(Pixels);
			free((void *)Filename.data);
			continue;
		}

		MTLRegion Region = MTLRegionMake2D(0, 0, Width, Height);
		[Texture replaceRegion:Region
					mipmapLevel:0
					  withBytes:Pixels
					bytesPerRow:Width * 4];

		stbi_image_free(Pixels);
		free((void *)Filename.data);

		TextureToGpuIndex[TextureSlot] = TextureSlot;
		Textures.Items[TextureSlot] = Texture;
		if(Textures.Count <= TextureSlot)
		{
			Textures.Count = TextureSlot + 1;
		}
	}

	typedef struct blas_info {
		uint32_t VertexOffset;
		uint32_t IndexOffset;
		uint32_t IndexCount;
	} blas_info;

	blas_info *BLASInfos = calloc(Scene->meshes.count, sizeof(blas_info));
	uint32_t TotalVertexCount = 0;
	uint32_t TotalIndexCount = 0;

	for(size_t MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];
		printf("Mesh triangle count: %zu\n", Mesh->num_triangles);

		BLASInfos[MeshIndex] = (blas_info){
			.VertexOffset = TotalVertexCount,
			.IndexOffset = TotalIndexCount,
			.IndexCount = (uint32_t)(Mesh->num_triangles * 3),
		};
		TotalVertexCount += (uint32_t)Mesh->num_indices;
		TotalIndexCount += (uint32_t)(Mesh->num_triangles * 3);
	}

	vertex *Vertices = calloc(TotalVertexCount, sizeof(vertex));
	uint32_t *Indices = calloc(TotalIndexCount, sizeof(uint32_t));
	for(size_t MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];
		blas_info BLASInfo = BLASInfos[MeshIndex];

		for(size_t Index = 0; Index < Mesh->num_indices; Index++)
		{
			ufbx_vec3 Position = ufbx_get_vertex_vec3(&Mesh->vertex_position, Index);
			ufbx_vec3 Normal = ufbx_get_vertex_vec3(&Mesh->vertex_normal, Index);
			ufbx_vec2 UV = {0};
			if(Mesh->vertex_uv.exists)
			{
				UV = ufbx_get_vertex_vec2(&Mesh->vertex_uv, Index);
			}
			UV.y = 1.0 - UV.y;

			Vertices[BLASInfo.VertexOffset + Index] = (vertex){
				.Position = (simd_float3){ Position.x, Position.y, Position.z },
				.Normal = (simd_float3){ Normal.x, Normal.y, Normal.z },
				.UV = (simd_float2){ UV.x, UV.y },
			};
		}

		uint32_t *MeshIndices = calloc(Mesh->max_face_triangles * 3, sizeof(uint32_t));
		uint32_t IndexCursor = BLASInfo.IndexOffset;
		for(size_t FaceIndex = 0; FaceIndex < Mesh->num_faces; FaceIndex++)
		{
			uint32_t TriangleCount = ufbx_triangulate_face(
				MeshIndices,
				Mesh->max_face_triangles * 3,
				Mesh,
				Mesh->faces.data[FaceIndex]);

			for(uint32_t CornerIndex = 0; CornerIndex < TriangleCount * 3; CornerIndex++)
			{
				Indices[IndexCursor++] = MeshIndices[CornerIndex];
			}
		}
		free(MeshIndices);
	}

	int BLASCount = 0;
	for(size_t MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];
		blas_info BLASInfo = BLASInfos[MeshIndex];
		G_Meshes[BLASCount] = BLASFromMesh(Device, Queue,
			Vertices + BLASInfo.VertexOffset, Mesh->num_indices,
			Indices + BLASInfo.IndexOffset, BLASInfo.IndexCount);
		G_BLASs[BLASCount] = G_Meshes[BLASCount].BLAS;
		BLASCount++;
	}

	size_t TotalInstanceNormalCount = 0;
	size_t TotalInstanceTriangleCount = 0;
	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		if(Node->camera)
		{
			simd_float3 Position = (simd_float3){ Node->node_to_world.m03, Node->node_to_world.m13, Node->node_to_world.m23 };
			printf("OMG CAMERA FOUND!: [%f %f %f]\n", Position.x, Position.y, Position.z);
		}
		if(!Node->mesh) continue;
		printf("Node name: %.*s\n", Node->name.length, Node->name.data);
		TotalInstanceNormalCount += Node->mesh->num_indices;
		TotalInstanceTriangleCount += Node->mesh->num_triangles;
	}

	simd_float3 *InstanceNormals = calloc(TotalInstanceNormalCount, sizeof(simd_float3));
	uint32_t *TriangleMaterialIDs = calloc(TotalInstanceTriangleCount, sizeof(uint32_t));
	MTLAccelerationStructureInstanceDescriptor *InstanceDescs = calloc(Scene->nodes.count, sizeof(MTLAccelerationStructureInstanceDescriptor));
	mesh_info *MeshInfos = calloc(Scene->nodes.count, sizeof(mesh_info));

	size_t InstanceNormalCursor = 0;
	size_t TriangleMaterialCursor = 0;
	NSUInteger InstanceCount = 0;
	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		if(!Node->mesh)
		{
			continue;
		}

		assert(Node->mesh->typed_id < (uint32_t)BLASCount);
		assert(Scene->meshes.data[Node->mesh->typed_id] == Node->mesh);
		ufbx_mesh *Mesh = Node->mesh;

		ufbx_matrix Inv = ufbx_matrix_invert(&Node->geometry_to_world);
		for(size_t Idx = 0; Idx < Mesh->num_indices; Idx++)
		{
			ufbx_vec3 N = ufbx_get_vertex_vec3(&Mesh->vertex_normal, Idx);
			simd_float3 W;
			W.x = (float)(Inv.m00*N.x + Inv.m10*N.y + Inv.m20*N.z);
			W.y = (float)(Inv.m01*N.x + Inv.m11*N.y + Inv.m21*N.z);
			W.z = (float)(Inv.m02*N.x + Inv.m12*N.y + Inv.m22*N.z);
			InstanceNormals[InstanceNormalCursor + Idx] = simd_normalize(W);
		}

		blas_info BLASInfo = BLASInfos[Node->mesh->typed_id];
		MeshInfos[InstanceCount].VertexOffset = BLASInfo.VertexOffset;
		MeshInfos[InstanceCount].IndexOffset = BLASInfo.IndexOffset;
		MeshInfos[InstanceCount].NormalOffset = (uint32_t)InstanceNormalCursor;
		MeshInfos[InstanceCount].MaterialOffset = (uint32_t)TriangleMaterialCursor;
		InstanceNormalCursor += Mesh->num_indices;

		uint32_t *FaceIndices = calloc(Mesh->max_face_triangles * 3, sizeof(uint32_t));
		for(size_t FaceIndex = 0; FaceIndex < Mesh->num_faces; FaceIndex++)
		{
			uint32_t MaterialID = UINT32_MAX;
			uint32_t MaterialSlot = 0;
			if(Mesh->face_material.count > FaceIndex)
			{
				MaterialSlot = Mesh->face_material.data[FaceIndex];
			}
			if(MaterialSlot < Node->materials.count && Node->materials.data[MaterialSlot])
			{
				MaterialID = Node->materials.data[MaterialSlot]->typed_id;
			}
			else if(MaterialSlot < Mesh->materials.count && Mesh->materials.data[MaterialSlot])
			{
				MaterialID = Mesh->materials.data[MaterialSlot]->typed_id;
			}

			uint32_t TriangleCount = ufbx_triangulate_face(
				FaceIndices,
				Mesh->max_face_triangles * 3,
				Mesh,
				Mesh->faces.data[FaceIndex]);

			for(uint32_t TriangleIndex = 0; TriangleIndex < TriangleCount; TriangleIndex++)
			{
				TriangleMaterialIDs[TriangleMaterialCursor++] = MaterialID;
			}
		}
		free(FaceIndices);

		MTLAccelerationStructureInstanceDescriptor *Instance = InstanceDescs + InstanceCount++;
		Instance->transformationMatrix = PackedMatrixFromUfbx(Node->geometry_to_world);
		Instance->options = MTLAccelerationStructureInstanceOptionOpaque;
		Instance->mask = 0xff;
		Instance->intersectionFunctionTableOffset = 0;
		Instance->accelerationStructureIndex = Node->mesh->typed_id;
	}

	material *Materials = calloc(Scene->materials.count, sizeof(material));
	for(size_t MaterialIndex = 0; MaterialIndex < Scene->materials.count; MaterialIndex++)
	{
		Materials[MaterialIndex].AlbedoIndex = UINT32_MAX;
		Materials[MaterialIndex].AlbedoColour = (simd_float4){1.0f, 1.0f, 1.0f, 1.0f};
		Materials[MaterialIndex].RoughnessIndex = UINT32_MAX;
		Materials[MaterialIndex].Roughness = 0.5f;

		ufbx_material *Material = Scene->materials.data[MaterialIndex];
		ufbx_material_map Albedo = Material->pbr.base_color;
		if(!Albedo.has_value && (!Albedo.texture || !Albedo.texture_enabled))
		{
			Albedo = Material->fbx.diffuse_color;
		}

		if(Albedo.has_value)
		{
			Materials[MaterialIndex].AlbedoColour = (simd_float4) {
				(float)Albedo.value_vec4.x,
				(float)Albedo.value_vec4.y,
				(float)Albedo.value_vec4.z,
				Albedo.value_components >= 4 ? (float)Albedo.value_vec4.w : 1.0f,
			};
		}

		if(Albedo.texture && Albedo.texture_enabled && Albedo.texture->typed_id < Scene->textures.count)
		{
			Materials[MaterialIndex].AlbedoIndex = TextureToGpuIndex[Albedo.texture->typed_id];
		}

		ufbx_material_map Roughness = Material->pbr.roughness;
		if(Roughness.has_value)
		{
			Materials[MaterialIndex].Roughness = Roughness.value_real;
		}

		if(Roughness.texture && Roughness.texture_enabled && Roughness.texture->typed_id < Scene->textures.count)
		{
			if(!Roughness.has_value)
			{
				Materials[MaterialIndex].Roughness = 1.0f;
			}
			Materials[MaterialIndex].RoughnessIndex = TextureToGpuIndex[Roughness.texture->typed_id];
		}
	}

	Result.Textures = Textures;
	Result.Meshes = G_Meshes;
	Result.MeshCount = (size_t)BLASCount;
	Result.GlobalVertexBuffer = [Device newBufferWithBytes:Vertices length:sizeof(vertex)*TotalVertexCount options:MTLResourceStorageModeShared];
	Result.GlobalIndexBuffer = [Device newBufferWithBytes:Indices length:sizeof(uint32_t)*TotalIndexCount options:MTLResourceStorageModeShared];
	Result.MeshInfoBuffer = [Device newBufferWithBytes:MeshInfos length:sizeof(mesh_info)*InstanceCount options:MTLResourceStorageModeShared];
	Result.InstanceNormalsBuffer = [Device newBufferWithBytes:InstanceNormals length:sizeof(simd_float3)*TotalInstanceNormalCount options:MTLResourceStorageModeShared];
	Result.TriangleMaterialBuffer = [Device newBufferWithBytes:TriangleMaterialIDs length:sizeof(uint32_t)*TotalInstanceTriangleCount options:MTLResourceStorageModeShared];
	Result.MaterialsBuffer = [Device newBufferWithBytes:Materials length:sizeof(material)*Scene->materials.count options:MTLResourceStorageModeShared];

	MTLInstanceAccelerationStructureDescriptor *TLASDesc = [MTLInstanceAccelerationStructureDescriptor descriptor];
	TLASDesc.instancedAccelerationStructures = [NSArray arrayWithObjects:G_BLASs count:BLASCount];
	Result.TLASInstanceBuffer = [Device newBufferWithBytes:InstanceDescs
													length:sizeof(MTLAccelerationStructureInstanceDescriptor)*InstanceCount
												   options:MTLResourceStorageModeShared];
	TLASDesc.instanceDescriptorBuffer = Result.TLASInstanceBuffer;
	TLASDesc.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeDefault;
	TLASDesc.instanceDescriptorStride = sizeof(MTLAccelerationStructureInstanceDescriptor);
	TLASDesc.instanceCount = InstanceCount;

	MTLAccelerationStructureSizes Sizes = [Device accelerationStructureSizesWithDescriptor:TLASDesc];
	Result.TLAS = [Device newAccelerationStructureWithSize:Sizes.accelerationStructureSize];
	Result.TLASScratchBuffer = [Device newBufferWithLength:Sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];

	id<MTLCommandBuffer> Cmd = [Queue commandBuffer];
	id<MTLAccelerationStructureCommandEncoder> ASCmd = [Cmd accelerationStructureCommandEncoder];
	[ASCmd buildAccelerationStructure:Result.TLAS descriptor:TLASDesc scratchBuffer:Result.TLASScratchBuffer scratchBufferOffset:0];
	[ASCmd endEncoding];
	[Cmd commit];
	[Cmd waitUntilCompleted];

	printf("BLASCount: %d\n", BLASCount);
	printf("InstanceCount: %lu\n", InstanceCount);

	free(TextureToGpuIndex);
	free(BLASInfos);
	free(Vertices);
	free(Indices);
	free(InstanceNormals);
	free(TriangleMaterialIDs);
	free(InstanceDescs);
	free(MeshInfos);
	free(Materials);

	return Result;
}

int main(void)
{
	ufbx_load_opts Opts = { 0 };
	Opts.use_blender_pbr_material = true;
	ufbx_error Error;
	const char *FbxPath = "/Users/olivercruickshank/Downloads/mustang/mustang2.fbx";
	const char *TextureRoot = "/Users/olivercruickshank/Downloads/mustang/textures/";
	ufbx_scene *Scene = ufbx_load_file(FbxPath, &Opts, &Error);
	if(!Scene)
	{
		fprintf(stderr, "Failed to load: %s\n", Error.description.data);
		exit(1);
	}

	id<MTLDevice> Device = MTLCreateSystemDefaultDevice();
	id<MTLCommandQueue> SceneQueue = [Device newCommandQueue];
	render_scene SceneData = LoadRenderSceneFromFbx(Scene, TextureRoot, Device, SceneQueue);

	MTLCompileOptions *Options = [[MTLCompileOptions alloc] init];
	NSString *RaytraceShaderSource = [[NSString alloc] initWithBytes:G_RaytraceShader.Data
														  length:G_RaytraceShader.Length
														encoding:NSUTF8StringEncoding];
	NSString *TonemapShaderSource = [[NSString alloc] initWithBytes:G_TonemapShader.Data
														 length:G_TonemapShader.Length
													   encoding:NSUTF8StringEncoding];
	if(!RaytraceShaderSource || !TonemapShaderSource)
	{
		fprintf(stderr, "Failed to decode embedded shader source.\n");
		exit(1);
	}
	NSString *ShaderSource = [RaytraceShaderSource stringByAppendingFormat:@"\n%@", TonemapShaderSource];

	NSError *ShaderError = nil;
	id<MTLLibrary> Library = [Device newLibraryWithSource:ShaderSource options:Options error:&ShaderError];
	if(!Library)
	{
		fprintf(stderr, "%s\n", ShaderError.localizedDescription.UTF8String);
		exit(1);
	}
	id<MTLFunction> RaytraceEntry = [Library newFunctionWithName:@"Raytrace"];
	if(!RaytraceEntry)
	{
		fprintf(stderr, "Failed to find Raytrace entry point in compiled shader library.\n");
		exit(1);
	}
	id<MTLFunction> TonemapEntry = [Library newFunctionWithName:@"Tonemap"];
	if(!TonemapEntry)
	{
		fprintf(stderr, "Failed to find Tonemap entry point in compiled shader library.\n");
		exit(1);
	}

	MTLTextureDescriptor *OutputImageDescriptor = [[MTLTextureDescriptor alloc] init];
	OutputImageDescriptor.width = 1600;
	OutputImageDescriptor.height = 1200;
	OutputImageDescriptor.textureType = MTLTextureType2D;
	OutputImageDescriptor.pixelFormat = MTLPixelFormatRGBA16Float;
	OutputImageDescriptor.storageMode = MTLStorageModePrivate;
	OutputImageDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	id<MTLTexture> OutputImage = [Device newTextureWithDescriptor:OutputImageDescriptor];

	MTKView *View = nil;
	NSWindow *Window = CreateWindow(Device, &View);

	renderer Renderer = {0};
	RendererInit(&Renderer,
		View,
		SceneData.Textures,
		SceneData.TLAS,
		SceneData.TLASInstanceBuffer,
		SceneData.TLASScratchBuffer,
		SceneData.Meshes,
		SceneData.MeshCount,
		SceneData.GlobalVertexBuffer,
		SceneData.GlobalIndexBuffer,
		SceneData.MeshInfoBuffer,
		SceneData.InstanceNormalsBuffer,
		SceneData.TriangleMaterialBuffer,
		SceneData.MaterialsBuffer,
		RaytraceEntry,
		TonemapEntry,
		OutputImage);

	petey_mtk_view_delegate *ViewDelegate = [petey_mtk_view_delegate new];
	ViewDelegate->Renderer = &Renderer;
	G_ViewDelegate = ViewDelegate;
	View.delegate = G_ViewDelegate;

	[NSApp run];

	return 0;
}
