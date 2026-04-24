#include <Cocoa/Cocoa.h>
#include <MetalKit/MetalKit.h>
#include <assert.h>
#include <float.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ufbx.h"

#include "shaders.h"


typedef struct mesh_gpu_data
{
	id<MTLAccelerationStructure> BLAS;
	id<MTLBuffer> VertexBuffer;
	id<MTLBuffer> IndexBuffer;
	id<MTLBuffer> ScratchBuffer;
} mesh_gpu_data;

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
	id<MTLFunction> RaytraceEntry;
	id<MTLComputePipelineState> RaytracePipeline;
	id<MTLTexture> OutputImage;
} renderer;

typedef struct vertex {
	simd_float3 Position;
	simd_float3 Normal;
} vertex;

typedef struct mesh_info {
	uint32_t VertexOffset;
	uint32_t IndexOffset;
	uint32_t NormalOffset;
	uint32_t _Pad;
} mesh_info;

typedef struct bounds3
{
	ufbx_vec3 Min;
	ufbx_vec3 Max;
	int HasPoints;
} bounds3;

static mesh_gpu_data G_Meshes[4096];
static id<MTLAccelerationStructure> G_BLASs[4096];

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

static void RendererInit(renderer *R, MTKView *View, id<MTLAccelerationStructure> Accel, id<MTLBuffer> TLASInstanceBuffer, id<MTLBuffer> TLASScratchBuffer, mesh_gpu_data *Meshes, size_t MeshCount, id<MTLBuffer> GlobalVertexBuffer, id<MTLBuffer> GlobalIndexBuffer, id<MTLBuffer> MeshInfoBuffer, id<MTLBuffer> InstanceNormalsBuffer, id<MTLFunction> RaytraceEntry, id<MTLTexture> OutputImage)
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
	R->RaytraceEntry = RaytraceEntry;
	R->OutputImage = OutputImage;
	View.clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);

	NSError *PipelineError = nil;
	R->RaytracePipeline = [R->Device newComputePipelineStateWithFunction:R->RaytraceEntry error:&PipelineError];
	if(!R->RaytracePipeline)
	{
		fprintf(stderr, "%s\n", PipelineError.localizedDescription.UTF8String);
		exit(1);
	}
}

static void RendererDraw(renderer *R, MTKView *View)
{
	static int FrameDebugCount = 0;
	id<MTLCommandBuffer> CommandBuffer = [R->Queue commandBuffer];
	MTLRenderPassDescriptor *Pass = View.currentRenderPassDescriptor;
	id<CAMetalDrawable> Drawable = View.currentDrawable;
	if(!Pass || !Drawable)
	{
		return;
	}
	if(FrameDebugCount < 3)
	{
		fprintf(stderr, "frame %d: output=%zux%zu drawable=%zux%zu framebufferOnly=%d\n",
				FrameDebugCount,
				R->OutputImage.width,
				R->OutputImage.height,
				Drawable.texture.width,
				Drawable.texture.height,
				View.framebufferOnly);
		FrameDebugCount++;
	}

	MTLComputePassDescriptor *ComputePassDescriptor = [[MTLComputePassDescriptor alloc] init];
	id<MTLComputeCommandEncoder> ComputeEncoder = [CommandBuffer computeCommandEncoderWithDescriptor:ComputePassDescriptor];
	[ComputeEncoder setAccelerationStructure:R->TLAS atBufferIndex:0];
	[ComputeEncoder setBuffer:R->GlobalVertexBuffer offset:0 atIndex:1];
	[ComputeEncoder setBuffer:R->GlobalIndexBuffer offset:0 atIndex:2];
	[ComputeEncoder setBuffer:R->MeshInfoBuffer offset:0 atIndex:3];
	[ComputeEncoder setBuffer:R->InstanceNormalsBuffer offset:0 atIndex:4];
	[ComputeEncoder setComputePipelineState:R->RaytracePipeline];
	[ComputeEncoder setTexture:R->OutputImage atIndex:0];
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

	NSUInteger CopyWidth = MIN(R->OutputImage.width, Drawable.texture.width);
	NSUInteger CopyHeight = MIN(R->OutputImage.height, Drawable.texture.height);

	id<MTLBlitCommandEncoder> BlitEncoder = [CommandBuffer blitCommandEncoder];
	[BlitEncoder copyFromTexture:R->OutputImage
					 sourceSlice:0
					 sourceLevel:0
					sourceOrigin:MTLOriginMake(0, 0, 0)
					  sourceSize:MTLSizeMake(CopyWidth, CopyHeight, 1)
					   toTexture:Drawable.texture
				destinationSlice:0
				destinationLevel:0
			   destinationOrigin:MTLOriginMake(0, 0, 0)];
	[BlitEncoder endEncoding];

	[CommandBuffer addCompletedHandler:^(id<MTLCommandBuffer> CompletedBuffer) {
		if(CompletedBuffer.status == MTLCommandBufferStatusError)
		{
			fprintf(stderr, "Frame command buffer failed: %s\n", CompletedBuffer.error.localizedDescription.UTF8String);
		}
	}];
	[CommandBuffer presentDrawable:Drawable];
	[CommandBuffer commit];
	[CommandBuffer waitUntilCompleted];
}

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
	View.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	View.framebufferOnly = NO;
	View.paused = YES;
	View.enableSetNeedsDisplay = NO;

	[Window setContentView:View];
	[Window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];

	*ViewOut = View;
	return Window;
}

static int WindowNotClosed(NSWindow *Window)
{
	return [Window isVisible];
}

static void UpdateWindow(NSWindow *Window)
{
	(void)Window;
	@autoreleasepool {
		for(;;)
		{
			NSEvent *Event = [NSApp nextEventMatchingMask:NSEventMaskAny
											   untilDate:[NSDate distantPast]
												  inMode:NSDefaultRunLoopMode
												 dequeue:YES];
			if(!Event)
			{
				break;
			}
			[NSApp sendEvent:Event];
		}
		[NSApp updateWindows];
	}
}

static void Render(renderer *Renderer, MTKView *View)
{
	RendererDraw(Renderer, View);
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

int main(void)
{

	ufbx_load_opts Opts = { 0 };
	ufbx_error Error;
	ufbx_scene *Scene = ufbx_load_file("/Users/olivercruickshank/Downloads/car.fbx", &Opts, &Error);
	if (!Scene) {
		fprintf(stderr, "Failed to load: %s\n", Error.description.data);
		exit(1);
	}

	id<MTLDevice> Device = MTLCreateSystemDefaultDevice();

	bounds3 CarBounds = BoundsFromScene(Scene);
	ufbx_vec3 CarCenter = CenterFromBounds(CarBounds);
	ufbx_vec3 CarExtents = ExtentsFromBounds(CarBounds);
	if(CarBounds.HasPoints)
	{
		printf("Car bounds min:    (%.3f, %.3f, %.3f)\n", CarBounds.Min.x, CarBounds.Min.y, CarBounds.Min.z);
		printf("Car bounds max:    (%.3f, %.3f, %.3f)\n", CarBounds.Max.x, CarBounds.Max.y, CarBounds.Max.z);
		printf("Car rough center:  (%.3f, %.3f, %.3f)\n", CarCenter.x, CarCenter.y, CarCenter.z);
		printf("Car rough extents: (%.3f, %.3f, %.3f)\n", CarExtents.x, CarExtents.y, CarExtents.z);
	}
	else
	{
		printf("Car rough center: no mesh vertices found, using shader defaults\n");
	}

	float GroundHeight = CarBounds.Min.y;
	printf("Ground plane height: %f\n", GroundHeight);

	printf("Node count: %zu\n", Scene->nodes.count);
	printf("Mesh count: %zu\n", Scene->meshes.count);
	printf("Material count: %zu\n", Scene->materials.count);
	printf("Texture count: %zu\n", Scene->textures.count);
	printf("Material count: %zu\n", Scene->materials.count);


	for(int Index = 0; Index < Scene->textures.count; Index++)
	{
		ufbx_texture *Texture = Scene->textures.data[Index];
		printf("File textures count: %zu\n", Texture->file_textures.count);
		printf("File texture filename: %.*s\n", (int)Texture->absolute_filename.length, Texture->absolute_filename.data);
	}

	for(int Index = 0; Index < Scene->meshes.count; Index++)
	{
		printf("Mesh triangle count: %zu\n", Scene->meshes.data[Index]->num_triangles);
	}

	typedef struct blas_info {
		int VertexOffset;
		int IndexOffset;
		int IndexCount;
	} blas_info;
	blas_info *BLASInfos = calloc(Scene->meshes.count, sizeof(blas_info));
	
	int TotalVertexCount = 0;
	int TotalIndexCount = 0;

	for(int MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];

		blas_info BLASInfo = {
			.VertexOffset = TotalVertexCount,
			.IndexOffset = TotalIndexCount,
			.IndexCount = Mesh->num_triangles * 3,
		};
		BLASInfos[MeshIndex] = BLASInfo;
		TotalVertexCount += Mesh->num_indices;
		TotalIndexCount += Mesh->num_triangles * 3;
	}


	uint32_t *Indices  = calloc(TotalIndexCount, sizeof(uint32_t));
	vertex *Vertices = calloc(TotalVertexCount, sizeof(vertex));
	for(int MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];
		blas_info BLASInfo = BLASInfos[MeshIndex];

		for (int Index = 0; Index < Mesh->num_indices; Index++)
		{
			ufbx_vec3 Position = ufbx_get_vertex_vec3(&Mesh->vertex_position, Index);
			ufbx_vec3 Normal = ufbx_get_vertex_vec3(&Mesh->vertex_normal, Index);
			
			vertex V = {0};
			V.Position = (simd_float3){ Position.x, Position.y, Position.z };
			V.Normal = (simd_float3){ Normal.x, Normal.y, Normal.z };

			Vertices[BLASInfo.VertexOffset + Index] = V;
		}

		uint32_t *MeshIndices = calloc(Mesh->max_face_triangles * 3, sizeof(uint32_t));
		int Index = BLASInfo.IndexOffset;
		for (int FaceIndex = 0; FaceIndex < Mesh->num_faces; FaceIndex++)
		{
			uint32_t TriangleCount = ufbx_triangulate_face(
				MeshIndices,
				Mesh->max_face_triangles * 3,
				Mesh,
				Mesh->faces.data[FaceIndex]);

			for (int CornerIndex = 0; CornerIndex < TriangleCount * 3; CornerIndex++)
			{
				Indices[Index++] = MeshIndices[CornerIndex];
			}
		}
		free(MeshIndices);
	}


	MTLCompileOptions *Options = [[MTLCompileOptions alloc] init];
	NSString *ShaderSource = [[NSString alloc] initWithBytes:G_RaytraceShader.Data
														length:G_RaytraceShader.Length
													  encoding:NSUTF8StringEncoding];
	if(!ShaderSource)
	{
		fprintf(stderr, "Failed to decode embedded shader source.\n");
		exit(1);
	}

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

	MTLTextureDescriptor *OutputImageDescriptor = [[MTLTextureDescriptor alloc] init];
	OutputImageDescriptor.width = 1600;
	OutputImageDescriptor.height = 1200;
	OutputImageDescriptor.textureType = MTLTextureType2D;
	OutputImageDescriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
	OutputImageDescriptor.storageMode = MTLStorageModePrivate;
	OutputImageDescriptor.usage = MTLTextureUsageShaderWrite;
	id<MTLTexture> OutputImage = [Device newTextureWithDescriptor:OutputImageDescriptor];

	int BLASCount = 0;



	id<MTLCommandQueue> Queue = [Device newCommandQueue];



	for(int MeshIndex = 0; MeshIndex < Scene->meshes.count; MeshIndex++)
	{
		ufbx_mesh *Mesh = Scene->meshes.data[MeshIndex];
		blas_info BLASInfo = BLASInfos[MeshIndex];
		G_Meshes[BLASCount] = BLASFromMesh(Device, Queue,
			Vertices + BLASInfo.VertexOffset, Mesh->num_indices,
			Indices + BLASInfo.IndexOffset, BLASInfo.IndexCount);
		G_BLASs[BLASCount] = G_Meshes[BLASCount].BLAS;
		BLASCount++;
	}


	MTLInstanceAccelerationStructureDescriptor *TLASDesc = [MTLInstanceAccelerationStructureDescriptor descriptor];

	TLASDesc.instancedAccelerationStructures = [NSArray arrayWithObjects:G_BLASs count:BLASCount];

	size_t TotalInstanceNormalCount = 0;
	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		if(!Node->mesh) continue;
		TotalInstanceNormalCount += Node->mesh->num_indices;
	}
	simd_float3 *InstanceNormals = calloc(TotalInstanceNormalCount, sizeof(simd_float3));
	size_t InstanceNormalCursor = 0;

	MTLAccelerationStructureInstanceDescriptor *InstanceDescs = calloc(Scene->nodes.count, sizeof(MTLAccelerationStructureInstanceDescriptor));
	mesh_info *MeshInfos = calloc(Scene->nodes.count, sizeof(mesh_info));
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
		MeshInfos[InstanceCount].VertexOffset = (uint32_t)BLASInfo.VertexOffset;
		MeshInfos[InstanceCount].IndexOffset  = (uint32_t)BLASInfo.IndexOffset;
		MeshInfos[InstanceCount].NormalOffset = (uint32_t)InstanceNormalCursor;
		InstanceNormalCursor += Mesh->num_indices;

		MTLAccelerationStructureInstanceDescriptor *Instance = InstanceDescs + InstanceCount++;
		Instance->transformationMatrix = PackedMatrixFromUfbx(Node->geometry_to_world);
		Instance->options = MTLAccelerationStructureInstanceOptionOpaque;
		Instance->mask = 0xff;
		Instance->intersectionFunctionTableOffset = 0;
		Instance->accelerationStructureIndex = Node->mesh->typed_id;
	}

	id<MTLBuffer> GlobalVertexBuffer = [Device newBufferWithBytes:Vertices
														   length:sizeof(vertex)*TotalVertexCount
														  options:MTLResourceStorageModeShared];
	id<MTLBuffer> GlobalIndexBuffer = [Device newBufferWithBytes:Indices
														  length:sizeof(uint32_t)*TotalIndexCount
														 options:MTLResourceStorageModeShared];
	id<MTLBuffer> MeshInfoBuffer = [Device newBufferWithBytes:MeshInfos
													   length:sizeof(mesh_info)*InstanceCount
													  options:MTLResourceStorageModeShared];
	id<MTLBuffer> InstanceNormalsBuffer = [Device newBufferWithBytes:InstanceNormals
															  length:sizeof(simd_float3)*TotalInstanceNormalCount
															 options:MTLResourceStorageModeShared];
	free(MeshInfos);
	free(InstanceNormals);

	printf("BLASCount: %d\n", BLASCount);
	printf("InstanceCount: %lu\n", InstanceCount);

	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		if(Node->mesh)
		{
			printf("instance %zu node=%.*s meshTyped=%u pos=(%.2f %.2f %.2f)\n",
				NodeIndex,
				(int)Node->name.length, Node->name.data,
				Node->mesh->typed_id,
				Node->geometry_to_world.m03,
				Node->geometry_to_world.m13,
				Node->geometry_to_world.m23);
		}
	}

	id<MTLBuffer> InstanceAS = [Device newBufferWithBytes:InstanceDescs
												   length:sizeof(MTLAccelerationStructureInstanceDescriptor)*InstanceCount
												  options:MTLResourceStorageModeShared];
	free(InstanceDescs);

	TLASDesc.instanceDescriptorBuffer = InstanceAS;

	TLASDesc.instanceDescriptorType = MTLAccelerationStructureInstanceDescriptorTypeDefault;
	TLASDesc.instanceDescriptorStride = sizeof(MTLAccelerationStructureInstanceDescriptor);
	TLASDesc.instanceCount = InstanceCount;

	MTLAccelerationStructureSizes Sizes = [Device accelerationStructureSizesWithDescriptor:TLASDesc];

	id<MTLAccelerationStructure> TLAS = [Device newAccelerationStructureWithSize:Sizes.accelerationStructureSize];

	id<MTLBuffer> scratch = [Device newBufferWithLength:Sizes.buildScratchBufferSize options:MTLResourceStorageModePrivate];

	id<MTLCommandBuffer> Cmd = [Queue commandBuffer];
	id<MTLAccelerationStructureCommandEncoder> ASCmd = [Cmd accelerationStructureCommandEncoder];
	[ASCmd buildAccelerationStructure:TLAS descriptor:TLASDesc scratchBuffer:scratch scratchBufferOffset:0];

	[ASCmd endEncoding];
	[Cmd commit];
	[Cmd waitUntilCompleted];

	MTKView *View = nil;
	NSWindow *Window = CreateWindow(Device, &View);

	renderer Renderer = {0};
	RendererInit(&Renderer,
				 View,
				 TLAS,
				 InstanceAS,
				 scratch,
				 G_Meshes,
				 BLASCount,
				 GlobalVertexBuffer,
				 GlobalIndexBuffer,
				 MeshInfoBuffer,
				 InstanceNormalsBuffer,
				 RaytraceEntry,
				 OutputImage);

	for(; WindowNotClosed(Window);)
	{
		UpdateWindow(Window);
		Render(&Renderer, View);
	}
	[Window close];

	return 0;
}
