#ifndef DECODE_CUH
#define DECODE_CUH

//#include <helper_math.h>
//dealing with doubles
#include "BitStream.cuh"
#include <thrust/device_vector.h>
#define NBMASK 0xaaaaaaaaaaaaaaaaull
#define LDEXP(x, e) ldexp(x, e)

namespace cuZFP {

#ifdef __CUDA_ARCH__
template<class Int, class Scalar>
__device__
Scalar
dequantize(Int x, int e)
{
	return LDEXP((double)x, e - (CHAR_BIT * c_sizeof_scalar - 2));
}
#else
template<class Int, class Scalar, uint sizeof_scalar>
__host__
Scalar
dequantize(Int x, int e)
{
	return LDEXP((double)x, e - (CHAR_BIT * sizeof_scalar - 2));
}
#endif
/* inverse block-floating-point transform from signed integers */
template<class Int, class Scalar>
__host__ __device__
void
inv_cast(const Int* p, Scalar* q, int emax, uint mx, uint my, uint mz, uint sx, uint sy, uint sz)
{
	Scalar s;
#ifndef __CUDA_ARCH__
	s = dequantize<Int, Scalar, sizeof(Scalar)>(1, emax);
#else
	/* compute power-of-two scale factor s */
	s = dequantize<Int, Scalar>(1, emax);
#endif
	/* compute p-bit float x = s*y where |y| <= 2^(p-2) - 1 */
	//  do
	//    *fblock++ = (Scalar)(s * *iblock++);
	//  while (--n);
	for (int z = mz; z < mz + 4; z++)
		for (int y = my; y < my + 4; y++)
			for (int x = mx; x < mx + 4; x++, p++)
				q[z*sz + y*sy + x*sx] = (Scalar)(s * *p);

}

/* inverse lifting transform of 4-vector */
template<class Int, uint s>
__host__ __device__
static void
inv_lift(Int* p)
{
	Int x, y, z, w;
	x = *p; p += s;
	y = *p; p += s;
	z = *p; p += s;
	w = *p; p += s;

	/*
	** non-orthogonal transform
	**       ( 4  6 -4 -1) (x)
	** 1/4 * ( 4  2  4  5) (y)
	**       ( 4 -2  4 -5) (z)
	**       ( 4 -6 -4  1) (w)
	*/
	y += w >> 1; w -= y >> 1;
	y += w; w <<= 1; w -= y;
	z += x; x <<= 1; x -= z;
	y += z; z <<= 1; z -= y;
	w += x; x <<= 1; x -= w;

	p -= s; *p = w;
	p -= s; *p = z;
	p -= s; *p = y;
	p -= s; *p = x;
}

/* transform along z */
template<class Int>
 __device__
static void
inv_xform_yx(Int* p)
{
	inv_lift<Int, 16>(p + 1 * threadIdx.x + 4 * threadIdx.z);
	//uint x, y;
	//for (y = 0; y < 4; y++)
	//	for (x = 0; x < 4; x++)
	//		inv_lift(p + 1 * x + 4 * y, 16);

}

/* transform along y */
template<class Int>
 __device__
static void
inv_xform_xz(Int* p)
{
	inv_lift<Int, 4>(p + 16 * threadIdx.z + 1 * threadIdx.x);
	//uint x, z;
	//for (x = 0; x < 4; x++)
	//	for (z = 0; z < 4; z++)
	//		inv_lift(p + 16 * z + 1 * x, 4);

}

/* transform along x */
template<class Int>
 __device__
static void
inv_xform_zy(Int* p)
{
	inv_lift<Int, 1>(p + 4 * threadIdx.x + 16 * threadIdx.z);
	//uint y, z;
	//for (z = 0; z < 4; z++)
	//	for (y = 0; y < 4; y++)
	//		inv_lift(p + 4 * y + 16 * z, 1);

}

/* inverse decorrelating 3D transform */
template<class Int>
 __device__
static void
inv_xform(Int* p)
{

	inv_xform_yx(p);
	__syncthreads();
	inv_xform_xz(p);
	__syncthreads();
	inv_xform_zy(p);
	__syncthreads();
}

/* map two's complement signed integer to negabinary unsigned integer */
template<class Int, class UInt>
__host__ __device__
Int
uint2int(UInt x)
{
	return (x ^ NBMASK) - NBMASK;
}


__host__ __device__
int
read_bit(char &offset, uint &bits, Word &buffer, const Word *begin)
{
  uint bit;
  if (!bits) {
    buffer = begin[offset++];
    bits = wsize;
  }
  bits--;
  bit = (uint)buffer & 1u;
  buffer >>= 1;
  return bit;
}
/* read 0 <= n <= 64 bits */
template<uint BITSIZE = sizeof(unsigned long long) * CHAR_BIT>
__host__ __device__
unsigned long long
read_bits(uint n, char &offset, uint &bits, Word &buffer, const Word *begin)
{
#if 0
  /* read bits in LSB to MSB order */
  uint64 value = 0;
  for (uint i = 0; i < n; i++)
    value += (uint64)stream_read_bit(stream) << i;
  return value;
#elif 1
  unsigned long long value;
  /* because shifts by 64 are not possible, treat n = 64 specially */
	if (n == BITSIZE) {
    if (!bits)
      value = begin[offset++];//*ptr++;
    else {
      value = buffer;
      buffer = begin[offset++];//*ptr++;
      value += buffer << bits;
      buffer >>= n - bits;
    }
  }
  else {
    value = buffer;
    if (bits < n) {
      /* not enough bits buffered; fetch wsize more */
      buffer = begin[offset++];//*ptr++;
      value += buffer << bits;
      buffer >>= n - bits;
      bits += wsize;
    }
    else
      buffer >>= n;
    value -= buffer << n;
    bits -= n;
  }
  return value;
#endif
}

/* decompress sequence of unsigned integers */
template<class Int, class UInt>
static uint
decode_ints_old(BitStream* stream, uint minbits, uint maxbits, uint maxprec, UInt* data, uint size, unsigned long long count)
{
  BitStream s = *stream;
  uint intprec = CHAR_BIT * (uint)sizeof(UInt);
  uint kmin = intprec > maxprec ? intprec - maxprec : 0;
  uint bits = maxbits;
  uint i, k, m, n, test;
  unsigned long long x;

  /* initialize data array to all zeros */
  for (i = 0; i < size; i++)
    data[i] = 0;

  /* input one bit plane at a time from MSB to LSB */
  for (k = intprec, n = 0; k-- > kmin;) {
    /* decode bit plane k */
    UInt* p = data;
    for (m = n;;) {
      /* decode bit k for the next set of m values */
      m = MIN(m, bits);
      bits -= m;
      for (x = stream->read_bits(m); m; m--, x >>= 1)
        *p++ += (UInt)(x & 1u) << k;
      /* continue with next bit plane if there are no more groups */
      if (!count || !bits)
        break;
      /* perform group test */
      bits--;
      test = stream->read_bit();
      /* continue with next bit plane if there are no more significant bits */
      if (!test || !bits)
        break;
      /* decode next group of m values */
      m = count & 0xfu;
      count >>= 4;
      n += m;
    }
    /* exit if there are no more bits to read */
    if (!bits)
      goto exit;
  }

  /* read at least minbits bits */
  while (bits > maxbits - minbits) {
    bits--;
    stream->read_bit();
  }

exit:
  *stream = s;
  return maxbits - bits;
}

template<class UInt, uint bsize>
__device__ __host__
uint
decode_ints(Word *block, UInt* data, uint minbits, uint maxbits, uint maxprec, unsigned long long count, uint size)
{
	uint intprec = CHAR_BIT * (uint)sizeof(UInt);
	uint kmin = intprec > maxprec ? intprec - maxprec : 0;
	uint bits = maxbits;
	uint i, k, m, n, test;
	unsigned long long x;

  char offset = 0;
  uint sbits = 0;
  Word buffer = 0;

	/* initialize data array to all zeros */
	for (i = 0; i < size; i++)
		data[i] = 0;

	/* input one bit plane at a time from MSB to LSB */
	for (k = intprec, n = 0; k-- > kmin;) {
		/* decode bit plane k */
		UInt* p = data;
		for (m = n;;) {
			if (bits){
				/* decode bit k for the next set of m values */
				m = MIN(m, bits);
				bits -= m;
        for (x = read_bits(m, offset, sbits, buffer, block); m; m--, x >>= 1)
					*p++ += (UInt)(x & 1u) << k;
				/* continue with next bit plane if there are no more groups */
				if (!count || !bits)
					break;
				/* perform group test */
				bits--;
        test = read_bit(offset, sbits, buffer, block);
				/* continue with next bit plane if there are no more significant bits */
				if (!test || !bits)
					break;
				/* decode next group of m values */
				m = count & 0xfu;
				count >>= 4;
				n += m;
			}
		}
	}

	/* read at least minbits bits */
	while (bits > maxbits - minbits) {
		bits--;
    read_bit(offset, sbits, buffer, block);
	}

	return maxbits - bits;

}

template<typename Int, typename UInt, typename Scalar, uint bsize, int intprec>
__device__ 
void decode(const Word *blocks,
            unsigned char *smem,
            uint out_idx,
            Scalar *out)
{
	__shared__ uint *s_kmin;
	__shared__ unsigned long long *s_bit_cnt;
	__shared__ Int *s_iblock;
	__shared__ int *s_emax;
	__shared__ int *s_cont;

	s_bit_cnt = (unsigned long long*)&smem[0];
	s_iblock = (Int*)&s_bit_cnt[0];
	s_kmin = (uint*)&s_iblock[64];

	s_emax = (int*)&s_kmin[1];
	s_cont = (int *)&s_emax[1];

	UInt l_data = 0;

	uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;
	uint idx = (blockIdx.x + blockIdx.y * gridDim.x + blockIdx.z * gridDim.y * gridDim.x);
	out[out_idx] = 0;

	if (tid == 0){
		//Bit<bsize> stream(blocks + idx * bsize);
		uint sbits = 0;
		Word buffer = 0;
		char offset = 0;

		s_cont[0] = read_bit(offset, sbits, buffer, blocks);
	}__syncthreads();

	if (s_cont[0]){
		if (tid == 0){
			uint sbits = 0;
			Word buffer = 0;
			char offset = 0;
			//do it again, it won't hurt anything
			read_bit(offset, sbits, buffer, blocks);

			uint ebits = c_ebits + 1;
			s_emax[0] = read_bits(ebits - 1, offset, sbits, buffer, blocks) - c_ebias;
			int maxprec = precision(s_emax[0], c_maxprec, c_minexp);
			s_kmin[0] = intprec > maxprec ? intprec - maxprec : 0;
			uint bits = c_maxbits - ebits;
			for (uint k = intprec, n = 0; k-- > 0;){
				//					idx_n[k] = n;
				//					bit_rmn_bits[k] = bits;
				uint m = MIN(n, bits);
				bits -= m;
				s_bit_cnt[k] = read_bits(m, offset, sbits, buffer, blocks);
				for (; n < 64 && bits && (bits--, read_bit(offset, sbits, buffer, blocks)); s_bit_cnt[k] += (unsigned long long)1 << n++)
					for (; n < 64 - 1 && bits && (bits--, !read_bit(offset, sbits, buffer, blocks)); n++)
						;
			}

		}	__syncthreads();

#pragma unroll 64
		for (int i = 0; i < 64; i++)
			l_data += (UInt)((s_bit_cnt[i] >> tid) & 1u) << i;

		__syncthreads();
		s_iblock[c_perm[tid]] = uint2int<Int, UInt>(l_data);
		__syncthreads();
		inv_xform(s_iblock);
		__syncthreads();

		//inv_cast
		out[out_idx] = dequantize<Int, Scalar>(1, s_emax[0]);
		out[out_idx] *= (Scalar)(s_iblock[tid]);
	}
}
template<class Int, class UInt>
__global__
void cudaInvOrder(const UInt *p,
                  Int *q)
{
	int x = threadIdx.x + blockDim.x*blockIdx.x;
	int y = threadIdx.y + blockDim.y*blockIdx.y;
	int z = threadIdx.z + blockDim.z*blockIdx.z;
	int idx = z*gridDim.x*blockDim.x*gridDim.y*blockDim.y + y*gridDim.x*blockDim.x + x;
	q[c_perm[idx % 64] + idx - idx % 64] = uint2int<Int, UInt>(p[idx]);

}

template<class Int>
__global__
void cudaInvXForm(Int *iblock)
{
	int x = threadIdx.x + blockDim.x*blockIdx.x;
	int y = threadIdx.y + blockDim.y*blockIdx.y;
	int z = threadIdx.z + blockDim.z*blockIdx.z;
	int idx = z*gridDim.x*blockDim.x*gridDim.y*blockDim.y + y*gridDim.x*blockDim.x + x;
	inv_xform(iblock + idx * 64);

}


template<class Int>
__global__
void cudaInvXFormYX(Int *iblock)
{
	int i = threadIdx.x + blockDim.x*blockIdx.x;
	int j = threadIdx.y + blockDim.y*blockIdx.y;
	int k = threadIdx.z + blockDim.z*blockIdx.z;
	int idx = j*gridDim.x*blockDim.x + i;
	inv_lift(iblock + k % 16 + 64 * idx, 16);

}


template<class Int>
__global__
void cudaInvXFormXZ(Int *iblock)
{
	int i = threadIdx.x + blockDim.x*blockIdx.x;
	int j = threadIdx.y + blockDim.y*blockIdx.y;
	int k = threadIdx.z + blockDim.z*blockIdx.z;
	int idx = j*gridDim.x*blockDim.x + i;
	inv_lift(iblock + k % 4 + 16 * idx, 4);

}

template<class Int>
__global__
void cudaInvXFormZY(Int *p)
{
	int x = threadIdx.x + blockDim.x*blockIdx.x;
	int y = threadIdx.y + blockDim.y*blockIdx.y;
	int z = threadIdx.z + blockDim.z*blockIdx.z;
	int idx = z*gridDim.x*blockDim.x*gridDim.y*blockDim.y + y*gridDim.x*blockDim.x + x;
	inv_lift(p + 4 * idx, 1);
}




template<class Int, class UInt, class Scalar, uint bsize, int intprec>
__global__
void
__launch_bounds__(64,5)
cudaDecode(Word *blocks,
           Scalar *out,
           const unsigned long long orig_count)
{
	uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;
  uint idx = (blockIdx.x + blockIdx.y * gridDim.x + blockIdx.z * gridDim.y * gridDim.x);
  uint bdim = blockDim.x*blockDim.y*blockDim.z;
  uint bidx = idx*bdim;

	extern __shared__ unsigned char smem[];

	decode<Int, UInt, Scalar, bsize, intprec>(blocks + bsize*idx, 
                                            smem,
		                                        (threadIdx.z + blockIdx.z * 4)*gridDim.x * gridDim.y * blockDim.x * blockDim.y + (threadIdx.y + blockIdx.y * 4)*gridDim.x * blockDim.x + (threadIdx.x + blockIdx.x * 4),
                                            out);
	//inv_cast
}
template<class Int, class UInt, class Scalar, uint bsize, int intprec>
void decode(int nx, 
            int ny, 
            int nz,
            thrust::device_vector<Word > &stream,
            Scalar *d_data,
            unsigned long long group_count)
{
  //ErrorCheck ec;
  dim3 emax_size(nx / 4, ny / 4, nz / 4);

  dim3 block_size = dim3(4, 4, 4);
  dim3 grid_size = dim3(nx, ny, nz);
  grid_size.x /= block_size.x; grid_size.y /= block_size.y; grid_size.z /= block_size.z;

  const int some_magic_number = 64 * (8) + 4 + 4; 
  cudaDecode<Int, UInt, Scalar, bsize, intprec> << < grid_size, block_size, some_magic_number >> >(raw_pointer_cast(stream.data()),
		d_data,
		group_count);
	cudaStreamSynchronize(0);
  //ec.chk("cudaInvXformCast");

  //  cudaEventRecord(stop, 0);
  //  cudaEventSynchronize(stop);
  //  cudaEventElapsedTime(&millisecs, start, stop);
  //ec.chk("cudadecode");
}

template<class Int, class UInt, class Scalar, uint bsize, int intprec>
void decode (int nx, 
             int ny, 
             int nz,
             thrust::device_vector<Word > &block,
             thrust::device_vector<Scalar> &d_data,
             unsigned long long group_count)
{
	decode<Int, UInt, Scalar, bsize, intprec>(nx, 
                                            ny, 
                                            nz, 
                                            block,
                                            thrust::raw_pointer_cast(d_data.data()),
                                            group_count);
}

} // namespace cuZFP

#endif