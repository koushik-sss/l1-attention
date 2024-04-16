import math
import torch
import torch.nn.functional as F
from torch.autograd import Function
import l1attn
import pdb

class L1AttnSparse(torch.nn.Module):
	def __init__(self):
		super(L1AttnSparse, self).__init__()
		# there are no parameters, deterministic mapping

	def forward(self, v, q, k, coo, dst_mxlen, src_mxlen):
		'''
		q, k, v are the usual dense tensors 
			shape [batch_size, n_tok, n_heads, width]
			for Query, Key, and Value respectively. 
		coo is a vector size [cl,3]
			with elements coo[i,:] = [dst,src,sm_cnt] where
			dst indexes q
			src indexes k,v
			dst_cnt indexes softmax
				that is, for each dst it compresses/indexes src to be non-sparse.
				(otherwise we need to allocate a full softmax matrix)
			src_cnt index the gather for the backward pass.
		dst and src are in [0 .. n_tok)
		dst_cnt is in [0 .. dst_mxlen)
		src_cnt is in [0 .. src_mxlen)
		'''
		bs, n_tok, n_heads, width = q.shape
		cl = coo.shape[0] # tempted to name it cool (coo_length)
		qq = q.permute(0, 2, 1, 3) # batch, heads, n_ctx, width
		kk = k.permute(0, 2, 1, 3) 
		vv = v.permute(0, 2, 1, 3) 

		qq = qq[:,:,coo[:,0],:] # this should broadcast properly.
		kk = kk[:,:,coo[:,1],:]
		scale = -1 / math.sqrt(width) # -1 for subsequent softmax
		ww = torch.sum(torch.abs(qq - kk)*scale, -1)
		attn = torch.ones(bs, n_heads, n_tok, dst_mxlen+1, device=q.device, dtype=q.dtype)*-1e32 # -infty
		attn[:,:,coo[:,0], coo[:,2]] = ww[:,:,0:cl] # scatter op
		attn_sm = F.softmax(attn, -1)
		vw = torch.zeros(bs, n_heads, n_tok, dst_mxlen+1, width, device=q.device, dtype=q.dtype)
		vw[:,:,coo[:,0],coo[:,2],:] = vv[:,:,coo[:,1],:]
		vo = torch.einsum("bhds, bhdsw -> bdhw", attn_sm, vw) # sum over src
		# vout = torch.zeros_like(v)
		# vout[:,coo[:,0],:,:] = vo[:,coo[:,0],:,:]
		return vo

class L1AttnSparseFn(Function):
	@staticmethod
	def forward(ctx, v, q, k, coo, dst_mxlen, src_mxlen):
		'''
		q, k, v are the usual dense tensors
			shape [batch_size, n_tok, n_heads, width]
			for Query, Key, and Value respectively.
		coo is a vector size [cl,3]
			with elements coo[i,:] = [dst,src,sm_cnt]
			where dst indexes q
			and src indexes k,v
			and sm_cnt indexes softmax
				that is, for each dst it compresses/indexes src to be non-sparse.
				(otherwise we need to allocate a full softmax matrix)
		dst and src are in [0 .. n_tok)
		sm_cnt is in [0 .. coo_cnt_max)
		'''
		bs, n_tok, n_heads, width = q.shape
		cl = coo.shape[0] # tempted to name it cool (coo_length)

		qq = q[:,coo[:,0],:,:] # this should broadcast properly.
		kk = k[:,coo[:,1],:,:]
		scale = -1 / math.sqrt(width) # -1 for subsequent softmax
		ww = torch.sum(torch.abs(qq - kk)*scale, -1)
		attn = torch.ones((bs, n_tok, dst_mxlen+1, n_heads),\
			device=q.device, dtype=q.dtype)*-1e12 # -infty
		attn[:,coo[:,0],coo[:,2],:] = ww[:,0:cl,:] # scatter op
		attn_sm = F.softmax(attn, 2)
		vw = torch.zeros((bs, n_tok, dst_mxlen+1, n_heads, width),\
			device=q.device, dtype=q.dtype) # uff, large matrix
		vw[:,coo[:,0],coo[:,2],:,:] = v[:,coo[:,1],:,:]
		vo = torch.einsum("bdrh, bdrhw -> bdhw", attn_sm, vw) # sum over src
		# dest must be full -- all locations written!

		ctx.save_for_backward(v, q, k, attn_sm, coo, torch.tensor(dst_mxlen), torch.tensor(src_mxlen))

		return vo

	@staticmethod
	def backward(ctx, dvo):
		v,q,k,attn_sm,coo,dst_mxlen,src_mxlen = ctx.saved_tensors[:7]
		dst_mxlen = dst_mxlen.item()
		src_mxlen = src_mxlen.item()
		bs, n_tok, n_heads, width = q.shape
		cl = coo.shape[0]

		# scale dvo by attn matrix
		dvw = torch.einsum("bdrh, bdhw -> bdrhw", attn_sm, dvo)
		# gather and sum
		dvp = torch.zeros((bs, n_tok, src_mxlen+1, n_heads, width), \
			device=q.device, dtype=q.dtype)
		dvp[:,coo[:,1],coo[:,3],:] = dvw[:,coo[:,0],coo[:,2],:]
		dv = torch.sum(dvp, 2)

		# calculate derivative wrt softmax
		vw = torch.zeros((bs, n_tok, dst_mxlen+1, n_heads, width), \
			device=q.device, dtype=q.dtype)
		vw[:,coo[:,0],coo[:,2],:,:] = v[:,coo[:,1],:,:]
		dattn_sm = torch.einsum("bdrhw, bdrhw -> bdrh ", vw, dvw)

		# calculate the jacobian of the softmax
		j = -1*torch.einsum("bdrh, bdqh -> bdrqh", attn_sm, attn_sm)
		# diagonal elements
		j[:,:,coo[:,1],coo[:,1],:] = \
			attn_sm[:,:,coo[:,1],:] * (1-attn_sm[:,:,coo[:,1],:])
		# note: jacobian is symmetric, so this might be transposed
		dattn = torch.einsum("bdrqh, bdrh -> bdqh", j, dattn_sm)

		# now for q
		qq = q[:,coo[:,0],:,:] # bdhw
		kk = k[:,coo[:,1],:,:]
		scale = -1 / math.sqrt(width) # -1 for subsequent softmax
		ws = torch.sign(qq - kk)*scale
		wss = torch.zeros((bs, n_tok, dst_mxlen+1, n_heads, width), \
			device=q.device, dtype=q.dtype)
		wss[:,coo[:,0],coo[:,2],:,:] = ws[:,coo[:,1],:,:]
		dq = torch.einsum("bdrhw, bdrh -> bdhw", wss, dattn)
		dk = torch.einsum("bdrhw, bdrh -> bdhw", wss, -1*dattn)

		return dv, dq, dk, None, None, None

class LinFun(Function):
	# make sure I understand the dumb simple case.
	@staticmethod
	def forward(ctx, x, w):
		y = torch.einsum("brc, br -> bc", w, x)
		ctx.save_for_backward(x, w)
		return y

	@staticmethod
	def backward(ctx, dy):
		x,w = ctx.saved_tensors[:2]
		dx = torch.einsum("brc, bc -> br", w, dy)
		dw = torch.einsum("bc, br -> brc", dy, x)
		return dx, dw

def expandCoo(co):
	'''
	take a coordinate vector 'co'
	consisting of [dst,src] pairs
	- add a third dimension for the softmax
		over source, per dest.
	- add a fourth dimension for the backward pass
		over dest, per source
	'''
	coo = torch.zeros((co.shape[0], 4), dtype=torch.int32, device=co.device)
	dst_cntr = {}
	src_cntr = {}
	dst_mxlen = 0
	src_mxlen = 0
	dst_max = 0
	src_max = 0
	for i in range(co.shape[0]):
		dst = co[i,0].item()
		src = co[i,1].item()
		if dst in dst_cntr:
			dst_cntr[dst] = dst_cntr[dst] + 1
		else:
			dst_cntr[dst] = 0
		if src in src_cntr:
			src_cntr[src] = src_cntr[src] + 1
		else:
			src_cntr[src] = 0
		coo[i,0] = dst
		coo[i,1] = src
		coo[i,2] = dst_cntr[dst]
		coo[i,3] = src_cntr[src]
		dst_mxlen = max(dst_mxlen, dst_cntr[dst])
		src_mxlen = max(src_mxlen, src_cntr[src])
		dst_max = max(dst_max, dst)
		src_max = max(src_max, dst)
	# go back and make sure all destinations are written -
	# that is, all destinations have at least one source.
	for i in range(dst_max):
		if i not in dst_cntr:
			print(f'degenerate sparse head - {i} not written')
	for i in range(src_max):
		if i not in src_cntr:
			print(f'degenerate sparse head - {i} not read')
	print('coo', coo)
	return coo, dst_mxlen, src_mxlen

def testL1AttnSparse(q, k, v, co):
	coo, dst_mxlen, src_mxlen = expandCoo(co)
	m = L1AttnSparse()
	vout = m(v, q, k, coo, dst_mxlen, src_mxlen)
	print('q', torch.squeeze(q))
	print('k', torch.squeeze(k))
	print('v', torch.squeeze(v))
	print('coo', coo)
	print('vout', torch.squeeze(vout))
	return vout

if __name__ == "__main__":
	batch_size = 1
	n_ctx = 3
	n_heads = 1
	width = 3
	
	q = torch.zeros(batch_size, n_ctx, n_heads, width)
	q[:,0,:,0] = 0
	q[:,0,:,1] = 1
	q[:,0,:,2] = 2
	q[:,1,:,0] = 2
	q[:,1,:,1] = 1
	q[:,1,:,2] = 0
	q[:,2,:,0] = 0
	q[:,2,:,1] = 0
	q[:,2,:,2] = 0
	
	k = torch.zeros(batch_size, n_ctx, n_heads, width)
	k[:,0,:,0] = 2
	k[:,0,:,1] = 1
	k[:,0,:,2] = 0
	k[:,1,:,0] = 0
	k[:,1,:,1] = 1
	k[:,1,:,2] = 2
	k[:,2,:,0] = 0
	k[:,2,:,1] = 1
	k[:,2,:,2] = 2
	
	v = torch.zeros(batch_size, n_ctx, n_heads, width)
	v[:,0,:,0] = -2
	v[:,0,:,1] = 2
	v[:,0,:,2] = 3
	v[:,1,:,0] = 2
	v[:,1,:,1] = -2
	v[:,1,:,2] = 2
	v[:,2,:,0] = 3
	v[:,2,:,1] = 2
	v[:,2,:,2] = -2

	co = torch.tensor([[0,0],[0,1],[1,0],[1,1],[2,2]])

	testL1AttnSparse(q, k, v, co)

	# try full non-sparse attention
	co = torch.tensor([[0,0],[0,1],[0,2],[1,0],[1,1],[1,2],[2,0],[2,1],[2,2]])
	vs = testL1AttnSparse(q, k, v, co)
	# compare it with non-sparse L1 attention.
	m = l1attn.L1Attn()
	a = m.forward(q, k)
	a_sm = F.softmax(a, -2)
	vf = torch.einsum('bhsd, bshw -> bdhw', a_sm, v)
	print('full / default attn')
	print('vout', vf)
	print('diff', vs-vf)
	assert torch.allclose(vs, vf)

	# same thing, but permute the coo vector
	indx = torch.randperm(co.shape[0])
	co = co[indx, :]
	vs = testL1AttnSparse(q, k, v, co)
	assert torch.allclose(vs, vf)
	
	print('assertions passed')
