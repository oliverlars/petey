#include <Cocoa/Cocoa.h>
#include <Foundation/Foundation.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#include "ufbx.h"

#include "render.h"
#include "shaders.h"


typedef struct app_state {
	renderer Renderer;
} app_state;

static void AppDraw(app_state *State, MTKView *View)
{
	RendererDraw(&State->Renderer, View);
}

@interface petey_view_delegate : NSObject <MTKViewDelegate> {
@public
	app_state *State;
}
@end

@implementation petey_view_delegate
- (void)drawInMTKView:(MTKView *)view { AppDraw(State, view); }
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { (void)view; (void)size; }
@end

typedef struct vertex {
	simd_float3 Position;
	simd_float3 Normal;
} vertex;

static mesh_gpu_data G_Meshes[4096];
static id<MTLAccelerationStructure> G_BLASs[4096];

static MTLPackedFloat4x3 PackedMatrixFromUfbx(ufbx_matrix M)
{
	MTLPackedFloat4x3 Result;
	Result.columns[0] = MTLPackedFloat3Make(M.m00, M.m10, M.m20);
	Result.columns[1] = MTLPackedFloat3Make(M.m01, M.m11, M.m21);
	Result.columns[2] = MTLPackedFloat3Make(M.m02, M.m12, M.m22);
	Result.columns[3] = MTLPackedFloat3Make(M.m03, M.m13, M.m23);
	return Result;
}

mesh_gpu_data BLASFromMesh(ufbx_mesh *Mesh, id<MTLDevice> Device, id<MTLCommandQueue> Queue)
{
	vertex *Vertices = calloc(Mesh->num_triangles * 3, sizeof(vertex));
	size_t VertexCount = 0;

	// Reserve space for the maximum triangle indices.
	size_t TriangleIndexCount = Mesh->max_face_triangles * 3;
	uint32_t *TriangleIndices = calloc(TriangleIndexCount, sizeof(uint32_t));

	// Iterate over each face using the specific material.
	for (size_t FaceIndex = 0; FaceIndex < Mesh->num_faces; FaceIndex++) {
		ufbx_face Face = Mesh->faces.data[FaceIndex];

		// Triangulate the face into `TriangleIndices[]`.
		uint32_t TriangleCount = ufbx_triangulate_face(TriangleIndices, TriangleIndexCount, Mesh, Face);

		// Iterate over each triangle corner contiguously.
		for (size_t Index = 0; Index < TriangleCount * 3; Index++) {
			uint32_t index = TriangleIndices[Index];

			vertex *V = Vertices + VertexCount++;
			ufbx_vec3 Position = ufbx_get_vertex_vec3(&Mesh->vertex_position, index);
			ufbx_vec3 Normal = ufbx_get_vertex_vec3(&Mesh->vertex_normal, index);
			V->Position = (simd_float3){Position.x, Position.y, Position.z};
			V->Normal = (simd_float3){Normal.x, Normal.y, Normal.z};
		}
	}

	// Should have written all the vertices.
	free(TriangleIndices);
	assert(VertexCount == Mesh->num_triangles * 3);

	size_t IndexCount = VertexCount;
	uint32_t *Indices = calloc(IndexCount, sizeof(uint32_t));
	for(size_t Index = 0; Index < IndexCount; Index++)
	{
		Indices[Index] = (uint32_t)Index;
	}


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

mesh_gpu_data BLASFromScene(ufbx_scene *Scene, id<MTLDevice> Device, id<MTLCommandQueue> Queue)
{
	size_t TriangleCountTotal = 0;
	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		if(Node->mesh)
		{
			TriangleCountTotal += Node->mesh->num_triangles;
		}
	}

	size_t VertexCapacity = TriangleCountTotal * 3;
	vertex *Vertices = calloc(VertexCapacity, sizeof(vertex));
	uint32_t *Indices = calloc(VertexCapacity, sizeof(uint32_t));
	uint32_t *TriangleIndices = NULL;
	size_t TriangleIndexCapacity = 0;
	size_t VertexCount = 0;

	for(size_t NodeIndex = 0; NodeIndex < Scene->nodes.count; NodeIndex++)
	{
		ufbx_node *Node = Scene->nodes.data[NodeIndex];
		ufbx_mesh *Mesh = Node->mesh;
		if(!Mesh)
		{
			continue;
		}

		size_t NeededTriangleIndices = Mesh->max_face_triangles * 3;
		if(NeededTriangleIndices > TriangleIndexCapacity)
		{
			free(TriangleIndices);
			TriangleIndexCapacity = NeededTriangleIndices;
			TriangleIndices = calloc(TriangleIndexCapacity, sizeof(uint32_t));
		}

		for(size_t FaceIndex = 0; FaceIndex < Mesh->num_faces; FaceIndex++)
		{
			ufbx_face Face = Mesh->faces.data[FaceIndex];
			uint32_t TriangleCount = ufbx_triangulate_face(TriangleIndices, TriangleIndexCapacity, Mesh, Face);

			for(size_t Index = 0; Index < TriangleCount * 3; Index++)
			{
				uint32_t MeshIndex = TriangleIndices[Index];
				ufbx_vec3 Position = ufbx_get_vertex_vec3(&Mesh->vertex_position, MeshIndex);
				ufbx_vec3 Normal = ufbx_get_vertex_vec3(&Mesh->vertex_normal, MeshIndex);
				Position = ufbx_transform_position(&Node->geometry_to_world, Position);

				vertex *V = Vertices + VertexCount;
				V->Position = (simd_float3){Position.x, Position.y, Position.z};
				V->Normal = (simd_float3){Normal.x, Normal.y, Normal.z};
				Indices[VertexCount] = (uint32_t)VertexCount;
				VertexCount++;
			}
		}
	}
	free(TriangleIndices);

	id<MTLBuffer> VertexBuffer = [Device newBufferWithBytes:Vertices
													 length:sizeof(vertex)*VertexCount
													options:MTLResourceStorageModeShared];
	id<MTLBuffer> IndexBuffer = [Device newBufferWithBytes:Indices
													length:sizeof(uint32_t)*VertexCount
												   options:MTLResourceStorageModeShared];
	free(Vertices);
	free(Indices);

	MTLAccelerationStructureTriangleGeometryDescriptor *AccelTriangleDesc = [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
	AccelTriangleDesc.vertexBuffer = VertexBuffer;
	AccelTriangleDesc.vertexBufferOffset = 0;
	AccelTriangleDesc.vertexStride = sizeof(vertex);
	AccelTriangleDesc.vertexFormat = MTLAttributeFormatFloat3;
	AccelTriangleDesc.indexBuffer = IndexBuffer;
	AccelTriangleDesc.indexBufferOffset = 0;
	AccelTriangleDesc.indexType = MTLIndexTypeUInt32;
	AccelTriangleDesc.triangleCount = VertexCount / 3;
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

	printf("Node count: %zu\n", Scene->nodes.count);
	printf("Mesh count: %zu\n", Scene->meshes.count);
	printf("Material count: %zu\n", Scene->materials.count);
	printf("Texture count: %zu\n", Scene->textures.count);
	printf("Material count: %zu\n", Scene->materials.count);


	for(int Index = 0; Index < Scene->textures.count; Index++)
	{
		ufbx_texture *Texture = Scene->textures.data[Index];
		printf("File textures count: %zu\n", Texture->file_textures.count);
		printf("File texture filename: %.*s\n", Texture->absolute_filename.length, Texture->absolute_filename.data);
	}
	exit(0);

	for(int Index = 0; Index < Scene->meshes.count; Index++)
	{
		printf("Mesh triangle count: %zu\n", Scene->meshes.data[Index]->num_triangles);
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
		G_Meshes[BLASCount] = BLASFromMesh(Scene->meshes.data[MeshIndex], Device, Queue);
		G_BLASs[BLASCount] = G_Meshes[BLASCount].BLAS;
		BLASCount++;
	}

	

	MTLInstanceAccelerationStructureDescriptor *TLASDesc = [MTLInstanceAccelerationStructureDescriptor descriptor];

	TLASDesc.instancedAccelerationStructures = [NSArray arrayWithObjects:G_BLASs count:BLASCount];

	MTLAccelerationStructureInstanceDescriptor *InstanceDescs = calloc(Scene->nodes.count, sizeof(MTLAccelerationStructureInstanceDescriptor));
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

		MTLAccelerationStructureInstanceDescriptor *Instance = InstanceDescs + InstanceCount++;
		Instance->transformationMatrix = PackedMatrixFromUfbx(Node->geometry_to_world);
		Instance->options = MTLAccelerationStructureInstanceOptionOpaque;
		Instance->mask = 0xff;
		Instance->intersectionFunctionTableOffset = 0;
		Instance->accelerationStructureIndex = Node->mesh->typed_id;
	}

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

	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

		NSRect Frame = NSMakeRect(0, 0, 800, 600);
		NSWindow *Window = [[NSWindow alloc]
			initWithContentRect:Frame
						styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
						backing:NSBackingStoreBuffered
							defer:NO];
		[Window center];
		[Window setTitle:@"petey"];

		MTKView *View = [[MTKView alloc] initWithFrame:Frame device:Device];
		View.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
		View.framebufferOnly = NO;

		static app_state State = {0};
		RendererInit(&State.Renderer, View, TLAS, InstanceAS, scratch, G_Meshes, BLASCount, RaytraceEntry, OutputImage);

		petey_view_delegate *Delegate = [[petey_view_delegate alloc] init];
		Delegate->State = &State;
		View.delegate = Delegate;

		[Window setContentView:View];
		[Window makeKeyAndOrderFront:nil];
		[NSApp activateIgnoringOtherApps:YES];
		[NSApp run];
	}
	return 0;
}
