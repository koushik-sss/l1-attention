#include <torch/extension.h>
#include <ATen/native/cuda/KernelUtils.cuh>

#include <cuda.h>
#include <cuda_runtime.h>

#include <vector>
<<<<<<< HEAD
=======
#include <iostream>
>>>>>>> 11dc1eb (new files)

template <typename scalar_t>
__device__  __forceinline__ scalar_t sign(scalar_t x)
{ 
<<<<<<< HEAD
	scalar_t t = x < 0 ? -1 : 0;
	return x > 0 ? 1 : t;
=======
    scalar_t t = x < 0 ? -1 : 0;
    return x > 0 ? 1 : t;
>>>>>>> 11dc1eb (new files)
}

template <typename scalar_t>
__device__  __forceinline__ void fastAtomicAdd2(
<<<<<<< HEAD
	torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> out, 
	int i0, int i1, int i2, int i3, scalar_t v)
{
	// convenience wrapper function around
	// fastAtomicAdd for 4-D tensors. 
	int index = i0*out.stride(0) + i1*out.stride(1) + i2*out.stride(2) + i3*out.stride(3);
	at::native::fastAtomicAdd(out.data(), index, 1, v, true); 
=======
    torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> out, 
    int i0, int i1, int i2, int i3, scalar_t v)
{
    // convenience wrapper function around
    // fastAtomicAdd for 4-D tensors.
    int index = i0*out.stride(0) + i1*out.stride(1) + i2*out.stride(2) + i3*out.stride(3);
    at::native::fastAtomicAdd(out.data(), index, 1, v, true); 
>>>>>>> 11dc1eb (new files)
}

template <typename scalar_t>
__global__ void l1attn_cuda_forward_kernelX(
<<<<<<< HEAD
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		q,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		k,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		attn,
		const scalar_t scale, 
		const int bs, const int n_ctx, const int n_heads, const int width)
{
	__shared__ scalar_t acc[32];
	
	int tix = threadIdx.x; // [0 .. 31]. 
	// tix operates within across the width dimension (reduction dim) 
	int h = blockIdx.x % n_heads; 
	int t = blockIdx.x / n_heads; 
	int s = blockIdx.y; 
	int b = blockIdx.z; 
	
	int width32 = (width + 31) / 32; 
	scalar_t f = 0.0; 
	for(int w = 0; w < width32; w++) { 
		int o = w*32+tix; 
		if(o < width)
			f += abs(q[b][t][h][o] - k[b][s][h][o]); 
	}
	acc[tix] = f * scale; 
	if(tix < 16) { 
		acc[tix] += acc[tix + 16];
		__syncthreads(); // why is this needed ??? 
		acc[tix] += acc[tix + 8 ];
		__syncthreads(); // threads in a warp should be synchronous.
		acc[tix] += acc[tix + 4 ];
		__syncthreads(); // experiment: it's totally needed! 
		acc[tix] += acc[tix + 2 ];
		__syncthreads();
		acc[tix] += acc[tix + 1 ];
		__syncthreads();
		if(tix == 0){
			attn[b][s][t][h] = acc[tix]; 
		}
	}
}

#define	BLKSIZ 16
template <typename scalar_t>
__global__ void l1attn_cuda_forward_kernel16(
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		q,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		k,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		attn,
		const scalar_t scale, 
		const int bs, const int n_ctx, const int n_heads, const int width)
{
	// q and k must be bhtw and bhsw respectively
	// despite the name of this function, it only operates on 
	// width 32 q and k tensors, in blocks of 16 x 16
	// Larger would require more per-warp memory or use of registers: 
	// 2 x 16 x 32 x 4 bytes = 4096 kB per block, so each SM can have 12 blocks. 
	
	int w = threadIdx.x; // t thread [0 .. 15]. 
	int u = threadIdx.y; // t for q, s for k,  [0 .. 15]. 
	int tb = blockIdx.x; // t block
	int sb = blockIdx.y; // s block
	int h = blockIdx.z % n_heads; // head
	int b = blockIdx.z / n_heads; // block
	
	// each block computes a BLKSIZ x BLKSIZ block of the attention matrix
	// a block is 256 threads
	// so, each thread loads one value from each q,k
	__shared__ scalar_t qc[BLKSIZ][32]; // q cache 
	__shared__ scalar_t kc[BLKSIZ][32]; // k cache
	
	//reshape to 8 warps, 32 threads - better mem throughput
	int tid = u*BLKSIZ + w; 
	int cw = tid % 32; // cache w
	int cu = tid / 32; // cache u
	int t = tb * BLKSIZ + cu; 
	int s = sb * BLKSIZ + cu; 
	
	qc[cu  ][cw] = q[b][h][t][cw]; // each thread reads/writes one fp32
	qc[cu+8][cw] = q[b][h][t+8][cw];
	kc[cu  ][cw] = k[b][h][s][cw];
	kc[cu+8][cw] = k[b][h][s+8][cw];
	
	__syncthreads();
	
	// simple approach: each thread computes one attention value
	// redefine t and s
	t = u; // so q is shared between threads in the same warp
	s = w; 
	scalar_t f = 0.0; 
	for(int o=0; o < 32; o++){
		f += abs(qc[t][o] - kc[s][o]); // ultimately want these to be registers
	}
	// back to global
	t = tb * BLKSIZ + u; 
	s = sb * BLKSIZ + w; 
	attn[b][s][t][h] = f * scale; // this is unaligned. ought to fix.
}

// template <typename scalar_t>
// __global__ void l1attn_cuda_backward_kernel_old(
// 		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
// 		d_attn,
// 		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
// 		q,
// 		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
// 		k,
// 		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
// 		d_q,
// 		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
// 		d_k,
// 		const scalar_t scale, 
// 		const int bs, const int n_ctx, const int n_heads, const int width ) 
// {
// 	// reduction (across s and t) has to be done within a thread warp: 
// 	// can't have different warps write the same memory. 
// 	// they will interfere / not give the correct answer!
// 	
// 	int indx = threadIdx.x + blockIdx.x * blockDim.x; // 1D
// 	
// 	if(indx < bs*n_ctx*n_ctx*n_heads){
// 		// again, output indexing b/c thread blocks can't overlap writes.
// 		// see note in forward kernel.
// 		int j = indx; 
// 		int h = j % n_heads; 
// 		j /= n_heads; 
// 		int s = j % n_ctx; 
// 		j /= n_ctx; 
// 		int t = j % n_ctx; 
// 		j /= n_ctx; 
// 		int b = j % bs; 
// 		
// 		scalar_t d_a = d_attn[b][s][t][h]; 
// 		for(int w = 0; w < width; w++){
// 			scalar_t ws = q[b][t][h][w] - k[b][s][h][w];
// 			ws = sign(ws) * scale; 
// 			// atomicAdd((scalar_t*)&(d_q[b][t][h][w]), ws * d_a);
// 			// atomicAdd((scalar_t*)&(d_k[b][s][h][w]), -1*ws * d_a);
// 			fastAtomicAdd2(d_q, b,t,h,w, ws * d_a);
// 			fastAtomicAdd2(d_k, b,s,h,w, -1*ws * d_a);
// 		}
// 	}
// } 

template <typename scalar_t>
__global__ void l1attn_cuda_backward_kernel(
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_attnq,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_attnk,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		q,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		k,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_q,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_k,
		const scalar_t scale, 
		const int bs, const int n_ctx, const int n_heads, const int width ) 
{
	__shared__ scalar_t acc_dq[32];
	__shared__ scalar_t acc_dk[32];
	
	int tix = threadIdx.x; // [0 .. 31].
	int h = blockIdx.x % n_heads; 
	int r = blockIdx.x / n_heads; // r is t for q, s for k.
	int w = blockIdx.y; 
	int b = blockIdx.z; 
		
	int ctx32 = (n_ctx + 31) / 32; 
	scalar_t dq = 0.0; 
	scalar_t dk = 0.0; 
	
	scalar_t qq = q[b][w][h][r]; 
	for(int o = 0; o < ctx32; o++) { 
		int s = o*32+tix; 
		if(s < n_ctx){ 
			// all this would work better if n_ctx were a multiple of 32. 
			scalar_t ws = qq - k[b][w][h][s];
			ws = sign(ws) * scale; 
			scalar_t d_a = d_attnq[b][r][h][s]; 
			dq += ws * d_a; 
		}
	}
	
	scalar_t kk = k[b][w][h][r]; 
	for(int o = 0; o < ctx32; o++) { 
		int t = o*32+tix; 
		if(t < n_ctx){
			scalar_t ws = q[b][w][h][t] - kk;
			ws = sign(ws) * scale; 
			scalar_t d_a = d_attnk[b][r][h][t]; 
			dk -= ws * d_a; 
		}
	}
	
	acc_dq[tix] = dq;
	acc_dk[tix] = dk;
	if(tix < 16) { 
		acc_dq[tix] += acc_dq[tix + 16];
		acc_dk[tix] += acc_dk[tix + 16];
		__syncthreads(); 
		acc_dq[tix] += acc_dq[tix + 8 ];
		acc_dk[tix] += acc_dk[tix + 8 ];
		__syncthreads(); 
		acc_dq[tix] += acc_dq[tix + 4 ];
		acc_dk[tix] += acc_dk[tix + 4 ];
		__syncthreads();
		acc_dq[tix] += acc_dq[tix + 2 ];
		acc_dk[tix] += acc_dk[tix + 2 ];
		__syncthreads();
		acc_dq[tix] += acc_dq[tix + 1 ];
		acc_dk[tix] += acc_dk[tix + 1 ];
		__syncthreads();
		if(tix == 0){
			d_q[b][r][h][w] = acc_dq[tix];
			d_k[b][r][h][w] = acc_dk[tix]; 
		}
	}
}

template <typename scalar_t>
__global__ void l1attn_cuda_backward_kernel16(
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_attn,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		q,
		const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		k,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_q,
		torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
		d_k,
		const scalar_t scale, 
		const int bs, const int n_ctx, const int n_heads, const int width) 
{
	// q and k must be bhtw and bhsw respectively
	// d_attn must be bhts (usually bsth)
	// output is bhtzw / bhszw, where z is an extra reduction dim over 16x16 
	
	int v = threadIdx.x; // thread [0 .. 15]. 
	int r = threadIdx.y; // t for q, s for k,  [0 .. 15]. 
	int sb = blockIdx.x; // s block
	int tb = blockIdx.y; // t block
	int h = blockIdx.z % n_heads; // head
	int b = blockIdx.z / n_heads; // block
	
	// each block computes a BLKSIZ x 32 block of d_q, d_k
	// a block is 256 threads
	// so, each thread loads four values from each q,k
	// and one from d_attn
	__shared__ scalar_t dac[BLKSIZ][BLKSIZ]; // d_attn cache 
	__shared__ scalar_t qc[BLKSIZ][32]; // q cache 
	__shared__ scalar_t kc[BLKSIZ][32]; // k cache
	
	// this will be partly uncoalesced. 
	int s = sb * BLKSIZ + v; 
	int t = tb * BLKSIZ + r; 
	dac[r][v] = d_attn[b][h][t][s]; 
	
	int tid = r*BLKSIZ + v; 
	int cw = tid % 32; // cache w
	int cr = tid / 32; // cache r
	s = sb * BLKSIZ + cr; 
	t = tb * BLKSIZ + cr; 
	
	qc[cr  ][cw] = q[b][h][t][cw]; // each thread reads one fp32
	qc[cr+8][cw] = q[b][h][t+8][cw];
	kc[cr  ][cw] = k[b][h][s][cw]; // full 32-wide load
	kc[cr+8][cw] = k[b][h][s+8][cw];
	__syncthreads();
	
	scalar_t dq, dk, qq, kk;
	for(int p = 0; p < 32; p += 16){
		int w = v + p; 
		dq = 0.0;
		t = r; 
		qq = qc[t][w]; 
		for(s = 0; s < BLKSIZ; s++){
			scalar_t ws = qq - kc[s][w];
			ws = sign(ws) * scale; 
			dq += ws * dac[t][s]; 
		}
		t = tb * BLKSIZ + r;
		//d_q[b][t][h][z][w] = dq; 
		fastAtomicAdd2( d_q, b,h,t,w, dq ); // ouch. o/w need too much mem.
	
		dk = 0.0; 
		s = r; 
		kk = kc[s][w]; 
		for(t = 0; t < BLKSIZ; t++){
			scalar_t ws = qc[t][w] - kk;
			ws = sign(ws) * scale; 
			dk -= ws * dac[t][s]; 
		}
		s = sb * BLKSIZ + r; 
		//d_k[b][s][h][z][w] = dk; 
		fastAtomicAdd2( d_k, b,h,s,w, dk ); 
	}
}

std::vector<torch::Tensor> l1attn_cuda_forward(
		torch::Tensor q,
		torch::Tensor k) {
  
	int bs = q.sizes()[0]; 
	int n_ctx = q.sizes()[1]; 
	int n_heads = q.sizes()[2]; 
	int width = q.sizes()[3];
	
	auto options = torch::TensorOptions()
		.dtype(q.dtype())
		.device(q.device())
		.requires_grad(q.requires_grad()); //better way to do this? 
	
	auto attn = torch::zeros({bs, n_ctx, n_ctx, n_heads}, options); 
	
	const dim3 numBlocks(n_heads*n_ctx, n_ctx, bs); // x, y, z
	const dim3 threadsPerBlock(32, 1, 1);
	
	double scale = -1.0 / sqrt(width); 
		
	AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_forward_kernel", ([&] {
		l1attn_cuda_forward_kernelX<scalar_t><<<numBlocks, threadsPerBlock>>>(
			q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			scale, bs, n_ctx, n_heads, width);
	}));
	
	return {attn};
}

std::vector<torch::Tensor> l1attn_cuda_forward16(
		torch::Tensor q,
		torch::Tensor k) {
  
	int bs = q.sizes()[0]; 
	int n_heads = q.sizes()[1];
	int n_ctx = q.sizes()[2]; 
	int width = q.sizes()[3];
	
	auto options = torch::TensorOptions()
		.dtype(q.dtype())
		.device(q.device())
		.requires_grad(q.requires_grad()); //better way to do this? 
	
	auto attn = torch::zeros({bs, n_ctx, n_ctx, n_heads}, options); 
	
	const dim3 numBlocks(n_ctx/BLKSIZ, n_ctx/BLKSIZ, bs*n_heads); // x, y, z
	const dim3 threadsPerBlock(BLKSIZ, BLKSIZ, 1);
	
	double scale = -1.0 / sqrt(width); 
		
	AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_forward_kernel16", ([&] {
		l1attn_cuda_forward_kernel16<scalar_t><<<numBlocks, threadsPerBlock>>>(
			q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			scale, bs, n_ctx, n_heads, width);
	}));
	
	// output is bhts; should be bsth to work with everything else.
	// attn = attn.transpose(1,3).contiguous(); 
	
	return {attn};
}

std::vector<torch::Tensor> l1attn_cuda_backward(
		torch::Tensor d_attnq,
		torch::Tensor d_attnk,
		torch::Tensor q,
		torch::Tensor k) 
{
	int bs = q.sizes()[0]; // permuted in python driver!!!
	int width = q.sizes()[1];
	int n_heads = q.sizes()[2]; 
	int n_ctx = q.sizes()[3]; 
	
	double scale = -1.0 / sqrt(width);
	
	auto options = torch::TensorOptions()
		.dtype(q.dtype())
		.device(q.device())
		.requires_grad(q.requires_grad());
	
	auto d_q = torch::zeros({bs, n_ctx, n_heads, width}, options);
	auto d_k = torch::zeros({bs, n_ctx, n_heads, width}, options);
	
	const dim3 numBlocks(n_heads*n_ctx, width, bs); // x, y, z
	const dim3 threadsPerBlock(32, 1, 1);
	
	AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_backward_kernel", ([&] {
		l1attn_cuda_backward_kernel<scalar_t><<<numBlocks, threadsPerBlock>>>(
			d_attnq.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			d_attnk.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			scale, bs, n_ctx, n_heads, width);
	}));
	
	return {d_q, d_k};
}

std::vector<torch::Tensor> l1attn_cuda_backward16(
		torch::Tensor d_attn,
		torch::Tensor q,
		torch::Tensor k) 
{
	int bs = q.sizes()[0]; 
	int n_heads = q.sizes()[1]; 
	int n_ctx = q.sizes()[2]; 
	int width = q.sizes()[3];
	
	double scale = -1.0 / sqrt(width);
	int zwidth = n_ctx / 16; 
	
	auto options = torch::TensorOptions()
		.dtype(q.dtype())
		.device(q.device())
		.requires_grad(q.requires_grad());
	
	auto d_q = torch::zeros({bs, n_heads, n_ctx, width}, options);
	auto d_k = torch::zeros({bs, n_heads, n_ctx, width}, options);
	
	// const dim3 dimBlocks(32, 8); // x, y, z
	const dim3 numBlocks(zwidth, zwidth, n_heads*bs); // x, y, z
	const dim3 threadsPerBlock(16, 16, 1); 
	
	AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_backward_kernel16", ([&] {
		l1attn_cuda_backward_kernel16<scalar_t><<<numBlocks, threadsPerBlock>>>(
			d_attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
			scale, bs, n_ctx, n_heads, width);
	}));
	
	// bhtw -> bthw -- really need to change everything in the lib! 
	d_q = d_q.transpose_(1,2).contiguous();
	d_k = d_k.transpose_(1,2).contiguous(); 
	
	return {d_q, d_k}; // reduce along the zsize dim
=======
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        q,
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        k,
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        attn,
        const scalar_t scale, 
        const int bs, const int n_ctx, const int n_heads, const int width)
{
    __shared__ scalar_t acc[32];
    
    int tix = threadIdx.x; // [0 .. 31]. 
    // tix operates within across the width dimension (reduction dim) 
    int h = blockIdx.x % n_heads; 
    int t = blockIdx.x / n_heads; 
    int s = blockIdx.y; 
    int b = blockIdx.z; 
    
    int width32 = (width + 31) / 32; 
    scalar_t f = 0.0; 
    for(int w = 0; w < width32; w++) { 
        int o = w*32+tix; 
        if(o < width)
            f += abs(q[b][t][h][o] - k[b][s][h][o]); 
    }
    acc[tix] = f * scale; 
    if(tix < 16) { 
        acc[tix] += acc[tix + 16];
        __syncthreads(); // why is this needed ??? 
        acc[tix] += acc[tix + 8 ];
        __syncthreads(); // threads in a warp should be synchronous.
        acc[tix] += acc[tix + 4 ];
        __syncthreads(); // experiment: it's totally needed! 
        acc[tix] += acc[tix + 2 ];
        __syncthreads();
        acc[tix] += acc[tix + 1 ];
        __syncthreads();
        if(tix == 0){
            attn[b][s][t][h] = acc[tix]; 
        }
    }
}

#define BLKSIZ 16

#define FORWARD_KERNEL_IMPL(WIDTH) \
template <typename scalar_t> \
__global__ void l1attn_cuda_forward_kernel16_w##WIDTH( \
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> q, \
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> k, \
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> attn, \
        const scalar_t scale, \
        const int bs, const int n_ctx, const int n_heads, const int width) \
{ \
    /* q and k must be bhtw and bhsw respectively */ \
    /* despite the name of this function, it only operates on */ \
    /* width 32 q and k tensors, in blocks of 16 x 16 */ \
    /* Larger would require more per-warp memory or use of registers: */ \
    /* 2 x 16 x 32 x 4 bytes = 4096 kB per block, so each SM can have 12 blocks. */ \
    __shared__ scalar_t qc[BLKSIZ][WIDTH]; \
    __shared__ scalar_t kc[BLKSIZ][WIDTH]; \
    \
    int w = threadIdx.x; /* t thread [0 .. 15]. */ \
    int u = threadIdx.y; /* t for q, s for k,  [0 .. 15]. */ \
    int tb = blockIdx.x; /* t block */ \
    int sb = blockIdx.y; /* s block */ \
    int h = blockIdx.z % n_heads; /* head */ \
    int b = blockIdx.z / n_heads; /* block */ \
    \
    /* each block computes a BLKSIZ x BLKSIZ block of the attention matrix */ \
    /* a block is 256 threads */ \
    /* so, each thread loads one value from each q,k */ \
    int tid = u*BLKSIZ + w; \
    int cw = tid % WIDTH; /* cache w */ \
    int cu = tid / WIDTH; /* cache u */ \
    int t = tb * BLKSIZ + cu; \
    int s = sb * BLKSIZ + cu; \
    \
    if (cu < BLKSIZ) { \
        qc[cu][cw] = q[b][h][t][cw]; /* each thread reads/writes one fp32 */ \
        kc[cu][cw] = k[b][h][s][cw]; \
    } \
    \
    __syncthreads(); \
    \
    /* simple approach: each thread computes one attention value */ \
    /* redefine t and s */ \
    t = u; /* so q is shared between threads in the same warp */ \
    s = w; \
    scalar_t f = 0.0; \
    for(int o=0; o < WIDTH; o++){ \
        f += abs(qc[t][o] - kc[s][o]); /* ultimately want these to be registers */ \
    } \
    /* back to global */ \
    t = tb * BLKSIZ + u; \
    s = sb * BLKSIZ + w; \
    attn[b][s][t][h] = f * scale; /* this is unaligned. ought to fix. */ \
}

FORWARD_KERNEL_IMPL(16)
FORWARD_KERNEL_IMPL(32)
FORWARD_KERNEL_IMPL(64)

template <typename scalar_t>
__global__ void l1attn_cuda_backward_kernel(
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        d_attnq,
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        d_attnk,
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        q,
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        k,
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        d_q,
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> 
        d_k,
        const scalar_t scale, 
        const int bs, const int n_ctx, const int n_heads, const int width ) 
{
    __shared__ scalar_t acc_dq[32];
    __shared__ scalar_t acc_dk[32];
    
    int tix = threadIdx.x; // [0 .. 31].
    int h = blockIdx.x % n_heads; 
    int r = blockIdx.x / n_heads; // r is t for q, s for k.
    int w = blockIdx.y; 
    int b = blockIdx.z; 
        
    int ctx32 = (n_ctx + 31) / 32; 
    scalar_t dq = 0.0; 
    scalar_t dk = 0.0; 
    
    scalar_t qq = q[b][w][h][r]; 
    for(int o = 0; o < ctx32; o++) { 
        int s = o*32+tix; 
        if(s < n_ctx){ 
            // all this would work better if n_ctx were a multiple of 32. 
            scalar_t ws = qq - k[b][w][h][s];
            ws = sign(ws) * scale; 
            scalar_t d_a = d_attnq[b][r][h][s]; 
            dq += ws * d_a; 
        }
    }
    
    scalar_t kk = k[b][w][h][r]; 
    for(int o = 0; o < ctx32; o++) { 
        int t = o*32+tix; 
        if(t < n_ctx){
            scalar_t ws = q[b][w][h][t] - kk;
            ws = sign(ws) * scale; 
            scalar_t d_a = d_attnk[b][r][h][t]; 
            dk -= ws * d_a; 
        }
    }
    
    acc_dq[tix] = dq;
    acc_dk[tix] = dk;
    if(tix < 16) { 
        acc_dq[tix] += acc_dq[tix + 16];
        acc_dk[tix] += acc_dk[tix + 16];
        __syncthreads(); 
        acc_dq[tix] += acc_dq[tix + 8 ];
        acc_dk[tix] += acc_dk[tix + 8 ];
        __syncthreads(); 
        acc_dq[tix] += acc_dq[tix + 4 ];
        acc_dk[tix] += acc_dk[tix + 4 ];
        __syncthreads();
        acc_dq[tix] += acc_dq[tix + 2 ];
        acc_dk[tix] += acc_dk[tix + 2 ];
        __syncthreads();
        acc_dq[tix] += acc_dq[tix + 1 ];
        acc_dk[tix] += acc_dk[tix + 1 ];
        __syncthreads();
        if(tix == 0){
            d_q[b][r][h][w] = acc_dq[tix];
            d_k[b][r][h][w] = acc_dk[tix]; 
        }
    }
}

#define BACKWARD_KERNEL_IMPL(WIDTH) \
template <typename scalar_t> \
__global__ void l1attn_cuda_backward_kernel16_w##WIDTH( \
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> d_attn, \
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> q, \
        const torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> k, \
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> d_q, \
        torch::PackedTensorAccessor32<scalar_t,4,torch::RestrictPtrTraits> d_k, \
        const scalar_t scale, \
        const int bs, const int n_ctx, const int n_heads, const int width) \
{ \
    /* q and k must be bhtw and bhsw respectively */ \
    /* d_attn must be bhts (usually bsth) */ \
    /* output is bhtzw / bhszw, where z is an extra reduction dim over 16x16 */ \
    __shared__ scalar_t dac[BLKSIZ][BLKSIZ]; /* d_attn cache */ \
    __shared__ scalar_t qc[BLKSIZ][WIDTH]; /* q cache */ \
    __shared__ scalar_t kc[BLKSIZ][WIDTH]; /* k cache */ \
    \
    int v = threadIdx.x; /* thread [0 .. 15]. */ \
    int r = threadIdx.y; /* t for q, s for k,  [0 .. 15]. */ \
    int sb = blockIdx.x; /* s block */ \
    int tb = blockIdx.y; /* t block */ \
    int h = blockIdx.z % n_heads; /* head */ \
    int b = blockIdx.z / n_heads; /* block */ \
    \
    /* this will be partly uncoalesced. */ \
    int s = sb * BLKSIZ + v; \
    int t = tb * BLKSIZ + r; \
    dac[r][v] = d_attn[b][h][t][s]; \
    \
    int tid = r*BLKSIZ + v; \
    int cw = tid % WIDTH; /* cache w */ \
    int cr = tid / WIDTH; /* cache r */ \
    s = sb * BLKSIZ + cr; \
    t = tb * BLKSIZ + cr; \
    \
    if (cr < BLKSIZ) { \
        qc[cr][cw] = q[b][h][t][cw]; /* each thread reads one fp32 */ \
        kc[cr][cw] = k[b][h][s][cw]; /* full 32-wide load */ \
    } \
    __syncthreads(); \
    \
    scalar_t dq, dk, qq, kk; \
    for(int p = 0; p < WIDTH; p += BLKSIZ){ \
        int w = v + p; \
        if (w < width) { \
            dq = 0.0; \
            t = r; \
            qq = qc[t][w]; \
            for(s = 0; s < BLKSIZ; s++){ \
                scalar_t ws = qq - kc[s][w]; \
                ws = sign(ws) * scale; \
                dq += ws * dac[t][s]; \
            } \
            t = tb * BLKSIZ + r; \
            fastAtomicAdd2(d_q, b,h,t,w, dq); \
        \
            dk = 0.0; \
            s = r; \
            kk = kc[s][w]; \
            for(t = 0; t < BLKSIZ; t++){ \
                scalar_t ws = qc[t][w] - kk; \
                ws = sign(ws) * scale; \
                dk -= ws * dac[t][s]; \
            } \
            s = sb * BLKSIZ + r; \
            fastAtomicAdd2(d_k, b,h,s,w, dk); \
        } \
    } \
}

BACKWARD_KERNEL_IMPL(16)
BACKWARD_KERNEL_IMPL(32)
BACKWARD_KERNEL_IMPL(64)

std::vector<torch::Tensor> l1attn_cuda_forward(
        torch::Tensor q,
        torch::Tensor k) {
  
    int bs = q.sizes()[0]; 
    int n_ctx = q.sizes()[1]; 
    int n_heads = q.sizes()[2]; 
    int width = q.sizes()[3];
    
    auto options = torch::TensorOptions()
        .dtype(q.dtype())
        .device(q.device())
        .requires_grad(q.requires_grad()); //better way to do this?
    
    auto attn = torch::zeros({bs, n_ctx, n_ctx, n_heads}, options); 
    
    const dim3 numBlocks(n_heads*n_ctx, n_ctx, bs); // x, y, z
    const dim3 threadsPerBlock(32, 1, 1);
    
    double scale = -1.0 / sqrt(width); 
        
    AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_forward_kernel", ([&] {
        // std::cout << "CUDA: Executing general forward kernel" << std::endl;
        l1attn_cuda_forward_kernelX<scalar_t><<<numBlocks, threadsPerBlock>>>(
            q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            scale, bs, n_ctx, n_heads, width);
    }));
    
    return {attn};
}

std::vector<torch::Tensor> l1attn_cuda_forward16(
        torch::Tensor q,
        torch::Tensor k) {
  
    int bs = q.sizes()[0]; 
    int n_heads = q.sizes()[1];
    int n_ctx = q.sizes()[2]; 
    int width = q.sizes()[3];
    
    auto options = torch::TensorOptions()
        .dtype(q.dtype())
        .device(q.device())
        .requires_grad(q.requires_grad()); //better way to do this?
    
    auto attn = torch::zeros({bs, n_ctx, n_ctx, n_heads}, options); 
    
    const dim3 numBlocks(n_ctx/BLKSIZ, n_ctx/BLKSIZ, bs*n_heads); // x, y, z
    const dim3 threadsPerBlock(BLKSIZ, BLKSIZ, 1);
    
    double scale = -1.0 / sqrt(width); 
        
    AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_forward_kernel16", ([&] {
        if (width == 16) {
            // std::cout << "CUDA: Executing forward kernel for width 16" << std::endl;
            l1attn_cuda_forward_kernel16_w16<scalar_t><<<numBlocks, threadsPerBlock>>>(
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else if (width == 32) {
            // std::cout << "CUDA: Executing forward kernel for width 32" << std::endl;
            l1attn_cuda_forward_kernel16_w32<scalar_t><<<numBlocks, threadsPerBlock>>>(
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else if (width == 64) {
            // std::cout << "CUDA: Executing forward kernel for width 64" << std::endl;
            l1attn_cuda_forward_kernel16_w64<scalar_t><<<numBlocks, threadsPerBlock>>>(
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else {
            throw std::runtime_error("Unsupported width for l1attn_cuda_forward16");
        }
    }));
    
    return {attn};
}

std::vector<torch::Tensor> l1attn_cuda_backward(
        torch::Tensor d_attnq,
        torch::Tensor d_attnk,
        torch::Tensor q,
        torch::Tensor k) 
{
    int bs = q.sizes()[0]; // permuted in python driver!!!
    int width = q.sizes()[1];
    int n_heads = q.sizes()[2]; 
    int n_ctx = q.sizes()[3]; 
    
    double scale = -1.0 / sqrt(width);
    
    auto options = torch::TensorOptions()
        .dtype(q.dtype())
        .device(q.device())
        .requires_grad(q.requires_grad());
    
    auto d_q = torch::zeros({bs, n_ctx, n_heads, width}, options);
    auto d_k = torch::zeros({bs, n_ctx, n_heads, width}, options);
    
    const dim3 numBlocks(n_heads*n_ctx, width, bs); // x, y, z
    const dim3 threadsPerBlock(32, 1, 1);
    
    AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_backward_kernel", ([&] {
        // std::cout << "CUDA: Executing general backward kernel" << std::endl;
        l1attn_cuda_backward_kernel<scalar_t><<<numBlocks, threadsPerBlock>>>(
            d_attnq.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            d_attnk.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
            scale, bs, n_ctx, n_heads, width);
    }));
    
    return {d_q, d_k};
}

std::vector<torch::Tensor> l1attn_cuda_backward16(
        torch::Tensor d_attn,
        torch::Tensor q,
        torch::Tensor k) 
{
    int bs = q.sizes()[0]; 
    int n_heads = q.sizes()[1]; 
    int n_ctx = q.sizes()[2]; 
    int width = q.sizes()[3];
    
    double scale = -1.0 / sqrt(width);
    
    auto options = torch::TensorOptions()
        .dtype(q.dtype())
        .device(q.device())
        .requires_grad(q.requires_grad());
    
    auto d_q = torch::zeros({bs, n_heads, n_ctx, width}, options);
    auto d_k = torch::zeros({bs, n_heads, n_ctx, width}, options);
    
    const dim3 numBlocks(n_ctx/BLKSIZ, n_ctx/BLKSIZ, n_heads*bs); // x, y, z
    const dim3 threadsPerBlock(BLKSIZ, BLKSIZ, 1); 
    
    AT_DISPATCH_FLOATING_TYPES(q.scalar_type(), "l1attn_cuda_backward_kernel16", ([&] {
        if (width == 16) {
            // std::cout << "CUDA: Executing backward kernel for width 16" << std::endl;
            l1attn_cuda_backward_kernel16_w16<scalar_t><<<numBlocks, threadsPerBlock>>>(
                d_attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else if (width == 32) {
            // std::cout << "CUDA: Executing backward kernel for width 32" << std::endl;
            l1attn_cuda_backward_kernel16_w32<scalar_t><<<numBlocks, threadsPerBlock>>>(
                d_attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else if (width == 64) {
            // std::cout << "CUDA: Executing backward kernel for width 64" << std::endl;
            l1attn_cuda_backward_kernel16_w64<scalar_t><<<numBlocks, threadsPerBlock>>>(
                d_attn.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_q.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                d_k.packed_accessor32<scalar_t,4,torch::RestrictPtrTraits>(),
                scale, bs, n_ctx, n_heads, width);
        } else {
            throw std::runtime_error("Unsupported width for l1attn_cuda_backward16");
        }
    }));
    
    // bhtw -> bthw -- really need to change everything in the lib! 
    d_q = d_q.transpose_(1,2).contiguous();
    d_k = d_k.transpose_(1,2).contiguous(); 
    
    return {d_q, d_k}; // reduce along the zsize dim
>>>>>>> 11dc1eb (new files)
}
