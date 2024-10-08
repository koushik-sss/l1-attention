#include <torch/extension.h>
#include <vector>
#include <iostream>

// CUDA forward declarations

std::vector<torch::Tensor> l1attn_cuda_forward(
        torch::Tensor q,
        torch::Tensor k );

std::vector<torch::Tensor> l1attn_cuda_forward16(
        torch::Tensor q,
        torch::Tensor k );

std::vector<torch::Tensor> l1attn_cuda_backward(
        torch::Tensor d_attnq,
        torch::Tensor d_attnk,
        torch::Tensor q,
        torch::Tensor k);

std::vector<torch::Tensor> l1attn_cuda_backward16(
        torch::Tensor d_attn,
        torch::Tensor q,
        torch::Tensor k);

// C++ interface
#define CHECK_CUDA(x) TORCH_CHECK(x.device().is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x) TORCH_CHECK(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) CHECK_CUDA(x); CHECK_CONTIGUOUS(x)

std::vector<torch::Tensor> l1attn_forward(
        torch::Tensor q,
        torch::Tensor k ) {
    CHECK_INPUT(q);
    CHECK_INPUT(k);
    
    int n_ctx = q.sizes()[1]; 
    int width = q.sizes()[3];
    
    if((n_ctx % 16 == 0) && (width == 16 || width == 32 || width == 64)){
        // std::cout << "C++: Using optimized forward kernel for width " << width << std::endl;
        // q & k come in bthw -> bhtw for better memory access? 
        q = q.transpose(1, 2).contiguous(); //doesn't seem to make much diff
        k = k.transpose(1, 2).contiguous();
        return l1attn_cuda_forward16(q, k);
    } else {
        // std::cout << "C++: Using general forward kernel" << std::endl;
        return l1attn_cuda_forward(q, k);
    }
}

std::vector<torch::Tensor> l1attn_backward(
        torch::Tensor d_attn,
        torch::Tensor q,
        torch::Tensor k) {
    CHECK_INPUT(d_attn);
    CHECK_INPUT(q);
    CHECK_INPUT(k);
    
    // std::cout << "l1attn_cuda intermediate tensor c" << std::endl;
	// std::cout << c << std::endl;
	
	// int bs = q.sizes()[0]; 
    int n_ctx = q.sizes()[1];
    // int n_heads = q.sizes()[2]; 
    int width = q.sizes()[3];
    if((n_ctx % 16 == 0) && (width == 16 || width == 32 || width == 64)){
        // std::cout << "C++: Using optimized backward kernel for width " << width << std::endl;
        d_attn = d_attn.transpose(1,3).contiguous();
        q = q.transpose(1,2).contiguous(); // bthw -> bhtw
        k = k.transpose(1,2).contiguous(); // bshw -> bhsw
        return l1attn_cuda_backward16(d_attn, q, k); 
    } else {
        // std::cout << "C++: Using general backward kernel" << std::endl;
        auto d_attnq = d_attn.transpose(1,3).transpose_(1,2).contiguous();
                    // bsth -> bhts -> bths
        auto d_attnk = d_attn.transpose(2,3).contiguous();
        			// bsth -> bsht
		// q & k are bthw & bshw
		// transpose them so memory access across t,s is coalesced
        q = q.transpose(1,3).contiguous(); // bthw -> bwht
        k = k.transpose(1,3).contiguous(); // bshw -> bwhs
        return l1attn_cuda_backward(d_attnq, d_attnk, q, k); 
    }
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("forward", &l1attn_forward, "L1Attn forward (CUDA)");
  m.def("backward", &l1attn_backward, "L1Attn backward (CUDA)");
}
