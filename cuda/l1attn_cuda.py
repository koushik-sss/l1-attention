import torch
from torch import nn
from torch.autograd import Function
# torch must be imported before extension, o/w shared-object links to c10 etc don't work
import l1attn_cuda_drv

class L1AttnFn(Function):
	@staticmethod
	def forward(ctx, q, k):
		n_heads = q.shape[2]
		q = q.contiguous(); 
		k = k.contiguous();
		attn = l1attn_cuda_drv.forward(q, k)
		ctx.save_for_backward(q, k)
		return attn[0]

	@staticmethod
	def backward(ctx, d_attn):
		q, k = ctx.saved_variables[:2]
		n_heads = q.shape[2]
		# q & k are bthw & bshw
		# transpose in C++ driver
		d_q, d_k = l1attn_cuda_drv.backward(d_attn, q, k)
		return d_q, d_k # output has no transpose; writes can be cached.


class L1Attn(nn.Module):
	def __init__(self):
		super(L1Attn, self).__init__()

	def forward(self, q, k):
		return L1AttnFn.apply(q, k)
<<<<<<< HEAD
=======

def will_use_optimized_kernel(tensor_shape):
    n_ctx = tensor_shape[1]
    width = tensor_shape[3]
    return (n_ctx % 16 == 0) and (width in [16, 32, 64])
>>>>>>> 11dc1eb (new files)
