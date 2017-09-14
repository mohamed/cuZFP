#ifndef CUZFP_ENCODE_CUH
#define CUZFP_ENCODE_CUH

//#include <helper_math.h>
#include "shared.h"
#include "ull128.h"
#include "BitStream.cuh"
#include "WriteBitter.cuh"
#include "shared.h"
#include <thrust/functional.h>
#include <thrust/device_vector.h>

#include <cuZFP.h>
#include <debug_utils.cuh>
#include <type_info.cuh>

#define LDEXP(x, e) ldexp(x, e)
#define FREXP(x, e) frexp(x, e)
#define FABS(x) fabs(x)


namespace cuZFP{

// map two's complement signed integer to negabinary unsigned integer
inline __device__ __host__
unsigned long long int int2uint(const long long int x)
{
    return (x + (unsigned long long int)0xaaaaaaaaaaaaaaaaull) ^ 
                (unsigned long long int)0xaaaaaaaaaaaaaaaaull;
}

inline __device__ __host__
unsigned int int2uint(const int x)
{
    return (x + (unsigned int)0xaaaaaaaau) ^ 
                (unsigned int)0xaaaaaaaau;
}

template<class Scalar>
__host__ __device__
static int
exponent(Scalar x)
{
  if (x > 0) {
    int e;
    FREXP(x, &e);
    // clamp exponent in case x is denormalized
    return MAX(e, 1 - get_ebias<Scalar>());
  }
  return -get_ebias<Scalar>();
}


// lifting transform of 4-vector
template <class Int, uint s>
__device__ __host__
static void
fwd_lift(Int* p)
{
  Int x = *p; p += s;
  Int y = *p; p += s;
  Int z = *p; p += s;
  Int w = *p; p += s;

  // default, non-orthogonal transform (preferred due to speed and quality)
  //        ( 4  4  4  4) (x)
  // 1/16 * ( 5  1 -1 -5) (y)
  //        (-4  4  4 -4) (z)
  //        (-2  6 -6  2) (w)
  x += w; x >>= 1; w -= x;
  z += y; z >>= 1; y -= z;
  x += z; x >>= 1; z -= x;
  w += y; w >>= 1; y -= w;
  w += y >> 1; y -= w >> 1;

  p -= s; *p = w;
  p -= s; *p = z;
  p -= s; *p = y;
  p -= s; *p = x;
}
// forward decorrelating transform
template<class Int>
__device__ __host__
static void
fwd_xform_zy(Int* p)
{
	fwd_lift<Int,1>(p + 4 * threadIdx.x + 16 * threadIdx.z);
}
// forward decorrelating transform
template<class Int>
__device__ __host__
static void
fwd_xform_xz(Int* p)
{
	fwd_lift<Int, 4>(p + 16 * threadIdx.z + 1 * threadIdx.x);
}
// forward decorrelating transform
template<class Int>
__device__ __host__
static void
fwd_xform_yx(Int* p)
{
	fwd_lift<Int, 16>(p + 1 * threadIdx.x + 4 * threadIdx.z);
}

// forward decorrelating transform
template<class Int>
__device__ 
static void
fwd_xform(Int* p)
{
  fwd_xform_zy(p);
	__syncthreads();
	fwd_xform_xz(p);
	__syncthreads();
	fwd_xform_yx(p);
}

template<typename Scalar>
Scalar
inline __device__
quantize_factor(const int &exponent, Scalar);

template<>
float
inline __device__
quantize_factor<float>(const int &exponent, float)
{
	return  LDEXP(1.0, get_precision<float>() - 2 - exponent);
}

template<>
double
inline __device__
quantize_factor<double>(const int &exponent, double)
{
	return  LDEXP(1.0, get_precision<double>() - 2 - exponent);
}

template<typename Scalar, typename Int>
void 
inline __device__ floating_point_ops(const int &tid,
                                     Int *sh_q,
                                     uint *s_emax_bits,
                                     const Scalar *sh_data,
                                     Scalar *sh_reduce,
                                     int *sh_emax,
                                     const Scalar &thread_val,
                                     Word *blocks,
                                     uint &blk_idx)
{

  /** FLOATING POINT ONLY ***/
  get_max_exponent(tid, sh_data, sh_reduce, sh_emax);
	__syncthreads();
  /*** FLOATING POINT ONLY ***/
	Scalar w = quantize_factor(sh_emax[0], Scalar());
  /*** FLOATING POINT ONLY ***/
  // block tranform
  sh_q[tid] = (Int)(thread_val * w); // sh_q  = signed integer representation of the floating point value
  /*** FLOATING POINT ONLY ***/
	if (tid == 0)
  {
		s_emax_bits[0] = 1;

		int maxprec = precision(sh_emax[0], get_precision<Scalar>(), get_min_exp<Scalar>());

		uint e = maxprec ? sh_emax[0] + get_ebias<Scalar>() : 0;
		if(e)
    {
			blocks[blk_idx] = 2 * e + 1; // the bit count?? for this block
			s_emax_bits[0] = get_ebits<Scalar>() + 1;// this c_ebit = ebias
		}
	}
}


template<>
void 
inline __device__ floating_point_ops<int,int>(const int &tid,
                                     int *sh_q,
                                     uint *s_emax_bits,
                                     const int *sh_data,
                                     int *sh_reduce,
                                     int *sh_emax,
                                     const int &thread_val,
                                     Word *blocks,
                                     uint &blk_idx)
{
  s_emax_bits[0] = 0;
  sh_q[tid] = thread_val;
}


template<>
void 
inline __device__ floating_point_ops<long long int, long long int>(const int &tid,
                                     long long int *sh_q,
                                     uint *s_emax_bits,
                                     const long long int*sh_data,
                                     long long int *sh_reduce,
                                     int *sh_emax,
                                     const long long int &thread_val,
                                     Word *blocks,
                                     uint &blk_idx)
{
  s_emax_bits[0] = 0;
  sh_q[tid] = thread_val;
}

template<typename Scalar>
void
inline __device__
get_max_exponent(const int &tid, 
                      const Scalar *sh_data,
                      Scalar *sh_reduce, 
                      int *max_exponent)
{
	if (tid < 32)
  {
		sh_reduce[tid] = max(fabs(sh_data[tid]), fabs(sh_data[tid + 32]));
  }
	if (tid < 16)
  {
		sh_reduce[tid] = max(sh_reduce[tid], sh_reduce[tid + 16]);
  }
	if (tid < 8)
  {
		sh_reduce[tid] = max(sh_reduce[tid], sh_reduce[tid + 8]);
  }
	if (tid < 4)
  {
		sh_reduce[tid] = max(sh_reduce[tid], sh_reduce[tid + 4]);
  }
	if (tid < 2)
  {
		sh_reduce[tid] = max(sh_reduce[tid], sh_reduce[tid + 2]);
  }
	if (tid == 0)
  {
		sh_reduce[0] = max(sh_reduce[tid], sh_reduce[tid + 1]);
		max_exponent[0] = exponent(sh_reduce[0]);
	}
}

template<typename Scalar>
__device__
void 
encode (Scalar *sh_data,
	      const uint bsize, 
        unsigned char *smem,
        uint blk_idx,
        Word *blocks)
{
  typedef typename zfp_traits<Scalar>::UInt UInt;
  typedef typename zfp_traits<Scalar>::Int Int;
  const int intprec = get_precision<Scalar>();

  // number of bits in the incoming type
  const uint size = sizeof(Scalar) * 8; 
  const uint vals_per_block = 64;
  //shared mem that depends on scalar size
	__shared__ Scalar *sh_reduce;
	__shared__ Int *sh_q;
	__shared__ UInt *sh_p;

  // shared mem that always has the same size
	__shared__ int *sh_emax;
	__shared__ uint *sh_m, *sh_n;
	__shared__ unsigned char *sh_sbits;
	__shared__ Bitter *sh_bitters;
	__shared__ uint *s_emax_bits;

  //
  // These memory locations do not overlap (in time)
  // so we will re-use the same buffer to
  // conserve precious shared mem space
  //
	sh_reduce = &sh_data[0];
	sh_q = (Int*)&sh_data[0];
	sh_p = (UInt*)&sh_data[0];

	sh_sbits = &smem[0];
	sh_bitters = (Bitter*)&sh_sbits[vals_per_block];
	sh_m = (uint*)&sh_bitters[vals_per_block];
	sh_n = (uint*)&sh_m[vals_per_block];
	s_emax_bits = (uint*)&sh_n[vals_per_block];
	sh_emax = (int*)&s_emax_bits[1];

	uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;
  //printf("block idx %d tid %d\n", (int)blk_idx, (int)tid);

	Bitter bitter = make_bitter(0, 0);
	unsigned char sbit = 0;
	//uint kmin = 0;
	if (tid < bsize)
		blocks[blk_idx + tid] = 0; 

  Scalar thread_val = sh_data[tid];
	__syncthreads();
  
  //
  // this is basically a no-op for int types
  //
  floating_point_ops(tid,
                     sh_q,
                     s_emax_bits,
                     sh_data,
                     sh_reduce,
                     sh_emax,
                     thread_val,
                     blocks,
                     blk_idx);
 
	__syncthreads();

  // Decorrelation
	fwd_xform(sh_q);

	__syncthreads();

  // get negabinary representation
  // fwd_order in cpu code
	sh_p[tid] = int2uint(sh_q[c_perm[tid]]);

  /**********************Begin encode block *************************/
	/* extract bit plane k to x[k] */
	long long unsigned y = 0;
	const long long unsigned mask = 1;
#pragma unroll 64
	for (uint i = 0; i < vals_per_block; i++)
  {
    // TODO: this is the main bottlenect in terms 
    // of # of instructions. We could could change
    // this to a lookup table or some sort of
    // binary matrix transpose.
		y += ((sh_p[i] >> tid) & mask) << i;
  }
  
	long long unsigned x = y;
  //
  // From this point on for 32 bit types,
  // only tids < 32 have valid data
  //
  
  //Print(tid, y, "bit plane");

	__syncthreads();
	sh_m[tid] = 0;   
	sh_n[tid] = 0;

	// temporarily use sh_n as a buffer
  // these are setting up indices to things that have value
  // find the first 1 (in terms of most significant 
  // __clzll -- intrinsic for count the # of leading zeros 	
  sh_n[tid] = 64 - __clzll(x);
  //Print(tid, sh_n[tid], "sh_n ");
	if (tid < 63)
  {
		sh_m[tid] = sh_n[tid + 1];
	}

	__syncthreads();
  // this is basically a scan
	if (tid == 0)
  {
		for (int i = intprec - 1; i-- > 0;)
    {
			if (sh_m[i] < sh_m[i + 1])
      {
				sh_m[i] = sh_m[i + 1];
      }
		}
	}

  //Print(tid, sh_m[tid], "sh_m ");

	__syncthreads();
	int bits = 128; // same for both 32 and 64 bit values 
	int n = 0;
	/* step 2: encode first n bits of bit plane */
	bits -= sh_m[tid];
	x >>= sh_m[tid];
	x = (sh_m[tid] != 64) * x;
	n = sh_m[tid];
	/* step 3: unary run-length encode remainder of bit plane */
	for (; n < size && bits && (bits--, !!x); x >>= 1, n++)
  {
		for (; n < size - 1 && bits && (bits--, !(x & 1u)); x >>= 1, n++);
  }
	__syncthreads();

	bits = (128 - bits);
	sh_n[tid] = min(sh_m[tid], bits);

	/* step 2: encode first n bits of bit plane */
	//y[tid] = stream[bidx].write_bits(y[tid], sh_m[tid]);
	y = write_bitters(bitter, make_bitter(y, 0), sh_m[tid], sbit);
	n = sh_n[tid];
	/* step 3: unary run-length encode remainder of bit plane */
	for (; n < size && bits && (bits-- && write_bitter(bitter, !!y, sbit)); y >>= 1, n++)
  {
		for (; n < size - 1 && bits && (bits-- && !write_bitter(bitter, y & 1u, sbit)); y >>= 1, n++);
  }

	__syncthreads();
  

  // First use of both bitters and sbits
  if(tid < intprec)
  {
    sh_bitters[intprec - 1 - tid] = bitter;
    sh_sbits[intprec - 1 - tid] = sbit;
    //Print(tid, sh_sbits[intprec - 1 -tid], "sbits ");
  }
	__syncthreads();

  // Bitter is a ulonglong2. It is just a way to have a single type
  // that contains 128bits
  // write out x writes to the first 64 bits and write out y writes to the second

	if (tid == 0)
  {
		uint tot_sbits = s_emax_bits[0];// sbits[0];
		uint rem_sbits = s_emax_bits[0];// sbits[0];
		uint offset = 0;
    const uint maxbits = bsize * vals_per_block; 
    //printf("total bits %d\n", (int)tot_sbits);
    //printf("rem bits %d\n", (int)rem_sbits);
    //printf("max bits %d\n", (int)maxbits);
		for (int i = 0; i < intprec && tot_sbits < maxbits; i++)
    {
      //printf(" %d bits in %d\n", (int) sh_sbits[i], i);
			if (sh_sbits[i] <= 64)
      {
				write_outx(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, sh_sbits[i], bsize);
			}
			else
      {
        // I think  the 64 here is just capping out the bits it writes?
				write_outx(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, 64, bsize);
        if (tot_sbits < maxbits)
        {
          write_outy(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, sh_sbits[i] - 64, bsize);
        }
			}
		}
    //printf("end total bits %d\n", (int)tot_sbits);
	} // end serial write

}


//
//  Encode 1D array
//
template<typename Scalar>
__device__
void 
encode1(Scalar *sh_data,
	      const uint bsize, 
        unsigned char *smem,
        uint blk_idx,
        Word *blocks)
{
  typedef typename zfp_traits<Scalar>::UInt UInt;
  typedef typename zfp_traits<Scalar>::Int Int;
  const int intprec = get_precision<Scalar>();

  // number of bits in the incoming type
  const uint size = sizeof(Scalar) * 8; 
  const uint vals_per_block = 4;
  const uint vals_per_cuda_block = 64;
  //shared mem that depends on scalar size
	__shared__ Scalar *sh_reduce;
	__shared__ Int *sh_q;
	__shared__ UInt *sh_p;

  // shared mem that always has the same size
	__shared__ int *sh_emax;
	__shared__ uint *sh_m, *sh_n;
	__shared__ unsigned char *sh_sbits;
	__shared__ Bitter *sh_bitters;
	__shared__ uint *s_emax_bits;

  //
  // These memory locations do not overlap (in time)
  // so we will re-use the same buffer to
  // conserve precious shared mem space
  //
	sh_reduce = &sh_data[0];
	sh_q = (Int*)&sh_data[0];
	sh_p = (UInt*)&sh_data[0];

	sh_sbits = &smem[0];
	sh_bitters = (Bitter*)&sh_sbits[vals_per_cuda_block];
	sh_m = (uint*)&sh_bitters[vals_per_cuda_block];
	sh_n = (uint*)&sh_m[vals_per_cuda_block];
	s_emax_bits = (uint*)&sh_n[vals_per_cuda_block];
  //TODO: this is different for 1D
	sh_emax = (int*)&s_emax_bits[1];

	uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;

	Bitter bitter = make_bitter(0, 0);
	unsigned char sbit = 0;
	//uint kmin = 0;
	if (tid < bsize)
		blocks[blk_idx + tid] = 0; 

  Scalar thread_val = sh_data[tid];
	__syncthreads();
  printf("val %f\n", thread_val); 
  return;
  //
  // this is basically a no-op for int types
  //
  floating_point_ops(tid,
                     sh_q,
                     s_emax_bits,
                     sh_data,
                     sh_reduce,
                     sh_emax,
                     thread_val,
                     blocks,
                     blk_idx);
 
	__syncthreads();
  //printf("block idx %d tid %d\n", (int)blk_idx, (int)tid);

  // Decorrelation
	fwd_xform(sh_q);

	__syncthreads();

  // get negabinary representation
  // fwd_order in cpu code
	sh_p[tid] = int2uint(sh_q[c_perm[tid]]);

  /**********************Begin encode block *************************/
	/* extract bit plane k to x[k] */
	long long unsigned y = 0;
	for (uint i = 0; i < vals_per_block; i++)
  {
		y += ((sh_p[i] >> tid) & (long long unsigned)1) << i;
  }
  
	long long unsigned x = y;
  //
  // From this point on for 32 bit types,
  // only tids < 32 have valid data
  //
  
  //Print(tid, y, "bit plane");

	__syncthreads();
	sh_m[tid] = 0;   
	sh_n[tid] = 0;

	// temporarily use sh_n as a buffer
  // these are setting up indices to things that have value
  // find the first 1 (in terms of most significant 
  // bit
	for (int i = 0; i < 64; i++)
  {
		if (!!(x >> i)) // !! is this bit zero
    {
			sh_n[tid] = i + 1;
    }
	}
  
  //Print(tid, sh_n[tid], "sh_n ");
  // shift
	if (tid < 63)
  {
		sh_m[tid] = sh_n[tid + 1];
	}

	__syncthreads();
  // this is basically a scan
	if (tid == 0)
  {
		for (int i = intprec - 1; i-- > 0;)
    {
			if (sh_m[i] < sh_m[i + 1])
      {
				sh_m[i] = sh_m[i + 1];
      }
		}
	}

  //Print(tid, sh_m[tid], "sh_m ");

	__syncthreads();
	int bits = 128; // same for both 32 and 64 bit values 
	int n = 0;
	/* step 2: encode first n bits of bit plane */
	bits -= sh_m[tid];
	x >>= sh_m[tid];
	x = (sh_m[tid] != 64) * x;
	n = sh_m[tid];
	/* step 3: unary run-length encode remainder of bit plane */
	for (; n < size && bits && (bits--, !!x); x >>= 1, n++)
  {
		for (; n < size - 1 && bits && (bits--, !(x & 1u)); x >>= 1, n++);
  }
	__syncthreads();

	bits = (128 - bits);
	sh_n[tid] = min(sh_m[tid], bits);

	/* step 2: encode first n bits of bit plane */
	//y[tid] = stream[bidx].write_bits(y[tid], sh_m[tid]);
	y = write_bitters(bitter, make_bitter(y, 0), sh_m[tid], sbit);
	n = sh_n[tid];
	/* step 3: unary run-length encode remainder of bit plane */
	for (; n < size && bits && (bits-- && write_bitter(bitter, !!y, sbit)); y >>= 1, n++)
  {
		for (; n < size - 1 && bits && (bits-- && !write_bitter(bitter, y & 1u, sbit)); y >>= 1, n++);
  }

	__syncthreads();
  

  // First use of both bitters and sbits
  if(tid < intprec)
  {
    sh_bitters[intprec - 1 - tid] = bitter;
    sh_sbits[intprec - 1 - tid] = sbit;
    //Print(tid, sh_sbits[intprec - 1 -tid], "sbits ");
  }
	__syncthreads();

  // Bitter is a ulonglong2. It is just a way to have a single type
  // that contains 128bits
  // write out x writes to the first 64 bits and write out y writes to the second

	if (tid == 0)
  {
		uint tot_sbits = s_emax_bits[0];// sbits[0];
		uint rem_sbits = s_emax_bits[0];// sbits[0];
		uint offset = 0;
    const uint maxbits = bsize * vals_per_block; 
    //printf("total bits %d\n", (int)tot_sbits);
    //printf("rem bits %d\n", (int)rem_sbits);
    //printf("max bits %d\n", (int)maxbits);
		for (int i = 0; i < intprec && tot_sbits < maxbits; i++)
    {
			if (sh_sbits[i] <= 64)
      {
				write_outx(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, sh_sbits[i], bsize);
			}
			else
      {
        // I think  the 64 here is just capping out the bits it writes?
				write_outx(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, 64, bsize);
        if (tot_sbits < maxbits)
        {
          write_outy(sh_bitters, blocks + blk_idx, rem_sbits, tot_sbits, offset, i, sh_sbits[i] - 64, bsize);
        }
			}
		}
    //printf("end total bits %d\n", (int)tot_sbits);
	} // end serial write

}

template<class Scalar>
__global__
void __launch_bounds__(64,5)
cudaEncode(const uint  bsize,
           const Scalar* data,
           Word *blocks,
           const int3 dims)
{
  extern __shared__ unsigned char smem[];
	__shared__ Scalar *sh_data;
	unsigned char *new_smem;

	sh_data = (Scalar*)&smem[0];
	new_smem = (unsigned char*)&sh_data[64];

  uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;
  uint idx = (blockIdx.x + blockIdx.y * gridDim.x + blockIdx.z * gridDim.y * gridDim.x);

  //
  //  The number of threads launched can be larger than total size of
  //  the array in cases where it cannot be devided into perfect block
  //  sizes. To account for this, we will clamp the values in each block
  //  to the bounds of the data set. 
  //

  const uint x_coord = min(threadIdx.x + blockIdx.x * 4, dims.x - 1);
  const uint y_coord = min(threadIdx.y + blockIdx.y * 4, dims.y - 1);
  const uint z_coord = min(threadIdx.z + blockIdx.z * 4, dims.z - 1);
      
	uint id = z_coord * dims.x * dims.y
          + y_coord * dims.x
          + x_coord;

	sh_data[tid] = data[id];
  //printf("tid %d data  %d\n",tid, sh_data[tid]);
	__syncthreads();
  //if(tid == 0) printf("\n");
	encode< Scalar>(sh_data,
                  bsize, 
                  new_smem,
                  idx * bsize,
                  blocks);

  __syncthreads();

}

template<class Scalar>
__global__
void __launch_bounds__(128,5)
cudaEncode1(const uint  bsize,
            const Scalar* data,
            Word *blocks,
            const int dim)
{
  extern __shared__ unsigned char smem[];
	__shared__ Scalar *sh_data;
	unsigned char *new_smem;

	sh_data = (Scalar*)&smem[0];
  //share data over 32 blocks( 4 vals * 32 blocks= 128) 
	new_smem = (unsigned char*)&sh_data[128];

  const uint idx = blockIdx.x * blockDim.x + threadIdx.x;

  //
  //  The number of threads launched can be larger than total size of
  //  the array in cases where it cannot be devided into perfect block
  //  sizes. To account for this, we will clamp the values in each block
  //  to the bounds of the data set. 
  //

  const uint id = min(idx, dim - 1);
      
  const uint tid = threadIdx.x;
	sh_data[tid] = data[id];
  printf("tid %d data  %d\n",tid, sh_data[tid]);
	__syncthreads();
  const uint zfp_block_id = 
  //if(tid == 0) printf("\n");
	encode1<Scalar>(sh_data,
                  bsize, 
                  new_smem,
                  idx * bsize, 
                  blocks);

  __syncthreads();

}


void allocate_device_mem3d(const int3 encoded_dims, 
                           const int bsize, 
                           thrust::device_vector<Word> &stream)
{
  const size_t vals_per_block = 64;
  const size_t size = encoded_dims.x * encoded_dims.y * encoded_dims.z; 
  size_t total_blocks = size / vals_per_block; 
  const size_t bits_per_block = vals_per_block * bsize;
  const size_t bits_per_word = sizeof(Word) * 8;
  const size_t total_bits = bits_per_block * total_blocks;
  const size_t alloc_size = total_bits / bits_per_word;
  stream.resize(alloc_size);
}

void allocate_device_mem1d(const int encoded_dim, 
                           const int bsize, 
                           thrust::device_vector<Word> &stream)
{
  const size_t vals_per_block = 4;
  const size_t size = encoded_dim; 
  size_t total_blocks = size / vals_per_block; 
  const size_t bits_per_block = vals_per_block * bsize;
  const size_t bits_per_word = sizeof(Word) * 8;
  const size_t total_bits = bits_per_block * total_blocks;
  const size_t alloc_size = total_bits / bits_per_word;
  stream.resize(alloc_size);
}

//
// Launch the encode kernel
//
template<class Scalar>
void encode1(int dim, 
             const Scalar *d_data,
             thrust::device_vector<Word> &stream,
             const int bsize)
{
  dim3 block_size, grid_size;
  const int cuda_block_size = 128;
  block_size = dim3(block_size, 0, 1);
  grid_size = dim3(dim, 0, 0);

  grid_size.x /= block_size.x; 

  // Check to see if we need to increase the block sizes
  // in the case where dim[x] is not a multiple of 4

  int encoded_dim = dim;

  if(dim % cuda_block_size != 0) 
  {
    grid_size.x++;
    encoded_dim = grid_size.x * cuda_block_size;
  }

  allocate_device_mem1d(encoded_dim, bsize, stream);

  std::size_t shared_mem_size = sizeof(Scalar) * cuda_block_size 
                              + sizeof(Bitter) * cuda_block_size 
                              + sizeof(unsigned char) * cuda_block_size 
                              + sizeof(unsigned int) * 128 
                              + 2 * sizeof(int);

	cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  std:::cout<<"Running kernel\n";
  cudaEventRecord(start);
	cudaEncode1<Scalar> << <grid_size, block_size, shared_mem_size>> >
    (bsize,
     d_data,
     thrust::raw_pointer_cast(stream.data()),
     dim);

  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
  cudaStreamSynchronize(0);

  float miliseconds = 0;
  cudaEventElapsedTime(&miliseconds, start, stop);
  float seconds = miliseconds / 1000.f;
  printf("Encode elapsed time: %.5f (s)\n", seconds);
  float rate = (float(dim) * sizeof(Scalar) ) / seconds;
  rate /= 1024.f;
  rate /= 1024.f;
  printf("Encode rate: %.2f (MB / sec)\n", rate);
}
//
// Launch the encode kernel
//
template<class Scalar>
void encode (int3 dims, 
             const Scalar *d_data,
             thrust::device_vector<Word> &stream,
             const int bsize)
{
  dim3 block_size, grid_size;
  block_size = dim3(4, 4, 4);
  grid_size = dim3(dims.x, dims.y, dims.z);

  grid_size.x /= block_size.x; 
  grid_size.y /= block_size.y;  
  grid_size.z /= block_size.z;

  // Check to see if we need to increase the block sizes
  // in the case where dim[x] is not a multiple of 4

  int3 encoded_dims = dims;

  if(dims.x % 4 != 0) 
  {
    grid_size.x++;
    encoded_dims.x = grid_size.x * 4;
  }
  if(dims.y % 4 != 0) 
  {
    grid_size.y++;
    encoded_dims.y = grid_size.y * 4;
  }
  if(dims.z % 4 != 0)
  {
    grid_size.z++;
    encoded_dims.z = grid_size.z * 4;
  }

  allocate_device_mem3d(encoded_dims, bsize, stream);

  std::size_t shared_mem_size = sizeof(Scalar) * 64 +  sizeof(Bitter) * 64 + sizeof(unsigned char) * 64
                                + sizeof(unsigned int) * 128 + 2 * sizeof(int);

	cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start);
	cudaEncode<Scalar> << <grid_size, block_size, shared_mem_size>> >
    (bsize,
     d_data,
     thrust::raw_pointer_cast(stream.data()),
     dims);

  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
  cudaStreamSynchronize(0);

  float miliseconds = 0;
  cudaEventElapsedTime(&miliseconds, start, stop);
  float seconds = miliseconds / 1000.f;
  printf("Encode elapsed time: %.5f (s)\n", seconds);
  float rate = (float(dims.x * dims.y * dims.z) * sizeof(Scalar) ) / seconds;
  rate /= 1024.f;
  rate /= 1024.f;
  printf("Encode rate: %.2f (MB / sec)\n", rate);
}

//***********************************3d encoding**********************************
//
// Just pass the raw pointer to the "real" encode
//
template<class Scalar>
void encode(int3 dims, 
             thrust::device_vector<Scalar> &d_data,
             thrust::device_vector<Word > &stream,
             const int bsize)
{
  encode<Scalar>(dims, thrust::raw_pointer_cast(d_data.data()), stream, bsize);
}

//
// Encode a host vector and output a encoded device vector
//
template<class Scalar>
void encode(int3 dims,
            const thrust::host_vector<Scalar> &h_data,
            thrust::device_vector<Word> &stream,
            const int bsize)
{
  thrust::device_vector<Scalar> d_data = h_data;
  encode<Scalar>(dims, d_data, stream, bsize);
}

//
//  Encode a host vector and output and encoded host vector
//
template<class Scalar>
void encode(int3 dims,
            const thrust::host_vector<Scalar> &h_data,
            thrust::host_vector<Word> &stream,
            const int bsize)
{
  thrust::device_vector<Word > d_stream = stream;
  encode<Scalar>(dims, h_data, d_stream, bsize);
  stream = d_stream;
}

//***********************************1d encoding**********************************

//
// Encode a host vector and output a encoded device vector
//
template<class Scalar>
void encode1(int dim,
             thrust::device_vector<Scalar> &d_data,
             thrust::device_vector<Word> &stream,
             const int bsize)
{
  encode1<Scalar>(dim, d_data, stream, bsize);
}

template<class Scalar>
void encode1(int dim,
             thrust::host_vector<Scalar> &h_data,
             thrust::host_vector<Word> &stream,
             const int bsize)
{
  thrust::device_vector<Word > d_stream = stream;
  thrust::device_vector<Scalar> d_data = stream;
  encode<Scalar>(dim, d_data, d_stream, bsize);
  stream = d_stream;
}

}

#endif
