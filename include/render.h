#pragma once

#include <MetalKit/MetalKit.h>

typedef struct mesh_gpu_data {
	id<MTLAccelerationStructure> BLAS;
	id<MTLBuffer> VertexBuffer;
	id<MTLBuffer> IndexBuffer;
	id<MTLBuffer> ScratchBuffer;
} mesh_gpu_data;

typedef struct renderer {
	id<MTLDevice> Device;
	id<MTLCommandQueue> Queue;
	id<MTLAccelerationStructure> TLAS;
	id<MTLBuffer> TLASInstanceBuffer;
	id<MTLBuffer> TLASScratchBuffer;
	mesh_gpu_data *Meshes;
	size_t MeshCount;
	id<MTLFunction> RaytraceEntry;
	id<MTLComputePipelineState> RaytracePipeline;
	id<MTLTexture> OutputImage;
} renderer;

void RendererInit(renderer *R, MTKView *View, id<MTLAccelerationStructure> Accel, id<MTLBuffer> TLASInstanceBuffer, id<MTLBuffer> TLASScratchBuffer, mesh_gpu_data *Meshes, size_t MeshCount, id<MTLFunction> RaytraceEntry, id<MTLTexture> OutputImage);
void RendererDraw(renderer *R, MTKView *View);
