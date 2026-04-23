#include "render.h"
#include <Metal/Metal.h>

void RendererInit(renderer *R, MTKView *View, id<MTLAccelerationStructure> Accel, id<MTLBuffer> TLASInstanceBuffer, id<MTLBuffer> TLASScratchBuffer, mesh_gpu_data *Meshes, size_t MeshCount, id<MTLFunction> RaytraceEntry, id<MTLTexture> OutputImage)
{
	R->Device = View.device;
	R->Queue = [R->Device newCommandQueue];
	R->TLAS = Accel;
	R->TLASInstanceBuffer = TLASInstanceBuffer;
	R->TLASScratchBuffer = TLASScratchBuffer;
	R->Meshes = Meshes;
	R->MeshCount = MeshCount;
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

void RendererDraw(renderer *R, MTKView *View)
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
