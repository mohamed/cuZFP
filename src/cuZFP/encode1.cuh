#ifndef CUZFP_ENCODE1_CUH
#define CUZFP_ENCODE1_CUH

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

#define CUDA_BLK_SIZE_1D 128
#define ZFP_BLK_PER_BLK_1D 32 

namespace cuZFP
{

template<typename T>
__device__ void print_bits(const T &bits)
{
  const int bit_size = sizeof(T) * 8;

  for(int i = bit_size - 1; i >= 0; --i)
  {
    T one = 1;
    T mask = one << i;
    T val = (bits & mask) >> i ;
    printf("%d", (int) val);
  }
  printf("\n");
}

struct BitStream32
{
  int current_bits; 
  unsigned int bits;
  __device__ BitStream32()
    : current_bits(0), bits(0)
  {
  }

  inline __device__ 
  unsigned short write_bits(const unsigned int &src, 
                            const uint &n_bits)
  {
    // set the first n bits to 0
    unsigned int left = (src >> n_bits) << n_bits;
    unsigned int b = src - left;
    b = b << current_bits;  
    current_bits += n_bits;
    bits += b;
    unsigned int res = left >> n_bits;
    return res;
  }

  inline __device__ 
  unsigned short write_bit(const unsigned short bit)
  {
    bits += bit << current_bits;   
    current_bits += 1;
    return bit;
  }

};

template<int block_size>
struct BlockWriter
{
  int m_word_index;
  int m_start_bit;
  const int m_bsize; 
  Word *m_words;
  bool m_valid_block;
  __device__ BlockWriter(Word *b, const int &bsize, const int &block_idx, const int &num_blocks)
    : m_words(b), m_bsize(bsize), m_valid_block(true)
  {
    if(block_idx >= num_blocks) m_valid_block = false;

    m_word_index = (block_idx * bsize * block_size)  / (sizeof(Word) * 8); 
    m_start_bit = (block_idx * bsize * block_size) % (sizeof(Word) * 8); 
  }

  inline __device__ 
  void write_bits(const unsigned int &bits, const uint &n_bits, const uint &bit_offset)
  {
    //if(bits == 0) { printf("no\n"); return;}
    uint seg_start = m_start_bit + bit_offset;
    uint seg_end = seg_start + n_bits - 1;
    int write_index = m_word_index;
    uint shift = seg_start; 

    // handle the case where all of the bits reside in the
    // next word. This is mutually exclusive with straddle.
    if(seg_start >= sizeof(Word) * 8) 
    { 
      write_index++;
      shift -= sizeof(Word) * 8;
    }
    // we may be asked to write less bits than exist in 'bits'
    // so we have to make sure that anything after n is zero.
    // If this does not happen, then we may write into a zfp
    // block not at the specified index
    // uint zero_shift = sizeof(Word) * 8 - n_bits;
    Word left = (bits >> n_bits) << n_bits;
    
    Word b = bits - left;
    Word add = b << shift;
    if(m_valid_block) atomicAdd(&m_words[write_index], add); 
    // n_bits straddles the word boundary
    bool straddle = seg_start < sizeof(Word) * 8 && seg_end >= sizeof(Word) * 8;
    if(straddle)
    {
      Word rem = b >> (sizeof(Word) * 8 - shift);
      print_bits(rem);
      if(m_valid_block) atomicAdd(&m_words[write_index + 1], rem); 
    }
  }

  private:
  __device__ BlockWriter()
  {
  }

};

template<typename Scalar, typename Int>
void 
inline __device__ floating_point_ops1(const int &tid,
                                      Int *sh_q,
                                      uint *s_emax_bits,
                                      const Scalar *sh_data,
                                      Scalar *sh_reduce,
                                      int *sh_emax,
                                      const Scalar &thread_val,  //
                                      Word blocks[],             // output stream
                                      uint &blk_idx,             // this is the start of all 32 blocks 
                                      const int &num_blocks,     // total number of blocks
                                      const int &bsize)          // bits per values
{
  const int block = tid / 4 /*vals_per_block*/;
  const int block_start = block * 4 /*vals_per_block*/;
  const int local_pos = tid % 4;

  /** FLOATING POINT ONLY ***/
  int max_exp = get_max_exponent1(tid, sh_data, sh_reduce, block_start, local_pos);
	__syncthreads();

  /*** FLOATING POINT ONLY ***/
	Scalar w = quantize_factor(max_exp, Scalar());
  /*** FLOATING POINT ONLY ***/
  // block tranform
  sh_q[tid] = (Int)(thread_val * w); // sh_q  = signed integer representation of the floating point value
  /*** FLOATING POINT ONLY ***/
	if (local_pos == 0)
  {
		s_emax_bits[block] = 1;

		unsigned int maxprec = precision(max_exp, get_precision<Scalar>(), get_min_exp<Scalar>());

	  unsigned int e = maxprec ? max_exp + get_ebias<Scalar>() : 0;
		if(e)
    {
      // this is writing the exponent out
			s_emax_bits[block] = get_ebits<Scalar>() + 1;// this c_ebit = ebias
      BlockWriter<4> writer(blocks, bsize, blk_idx + block, num_blocks);
      unsigned int bits = 2 * e + 1; // the bit count?? for this block
      // writing to shared mem
      writer.write_bits(bits, s_emax_bits[block], 0);
      //print_bits(blocks[0]);
		}
	}
}


template<>
void 
inline __device__ floating_point_ops1<int,int>(const int &tid,
                                               int *sh_q,
                                               uint *s_emax_bits,
                                               const int *sh_data,
                                               int *sh_reduce,
                                               int *sh_emax,
                                               const int &thread_val,
                                               Word *blocks,
                                               uint &blk_idx,
                                               const int &num_blocks,
                                               const int &bsize)
{

  const int offset = tid / 4 /*vals_per_block*/;
  const int local_pos = tid % 4;
  if(local_pos == 0)
  {
    s_emax_bits[offset] = 0;
  }
  sh_q[tid] = thread_val;
}

template<>
void 
inline __device__ floating_point_ops1<long long int, long long int>(const int &tid,
                                     long long int *sh_q,
                                     uint *s_emax_bits,
                                     const long long int*sh_data,
                                     long long int *sh_reduce,
                                     int *sh_emax,
                                     const long long int &thread_val,
                                     Word *blocks,
                                     uint &blk_idx,
                                     const int &num_blocks,
                                     const int &bize)
{
  const int offset = tid / 4 /*vals_per_block*/;
  const int local_pos = tid % 4;
  if(local_pos == 0)
  {
    s_emax_bits[offset] = 0;
  }
  sh_q[tid] = thread_val;
}

template<typename Scalar>
int
inline __device__
get_max_exponent1(const int &tid, 
                  const Scalar *sh_data,
                  Scalar *sh_reduce,
                  const int &offset,
                  const int &local_pos)
{
	if (local_pos < 2)
  {
		sh_reduce[offset + local_pos] = 
      max(fabs(sh_data[offset + local_pos]), fabs(sh_data[offset + local_pos + 2]));
  }

	if (local_pos == 0)
  {
		sh_reduce[offset] = max(sh_reduce[offset], sh_reduce[offset + 1]);
	}

	return exponent(sh_reduce[offset]);
}

//
//  Encode 1D array
//
template<typename Scalar>
__device__
void 
encode1(Scalar *sh_data,
	      const uint bsize, 
        uint blk_idx, // the start index of the set of zfp blocks we are encoding
        Word *blocks,
        const int num_blocks)
{
  typedef typename zfp_traits<Scalar>::UInt UInt;
  typedef typename zfp_traits<Scalar>::Int Int;
  const int intprec = get_precision<Scalar>();

  extern __shared__ Word sh_output[];
  typedef unsigned short PlaneType;
  // number of bits in the incoming type
  //const uint size = sizeof(Scalar) * 8; 
  const uint vals_per_block = 4;
  const uint vals_per_cuda_block = CUDA_BLK_SIZE_1D;
  //shared mem that depends on scalar size
	__shared__ Scalar *sh_reduce;
	__shared__ Int *sh_q;
	__shared__ UInt *sh_p;
  //
  // These memory locations do not overlap (in time)
  // so we will re-use the same buffer to
  // conserve precious shared mem space
  //
	sh_reduce = &sh_data[0];
	sh_q = (Int*)&sh_data[0];
	sh_p = (UInt*)&sh_data[0];

  // shared mem that always has the same size
	__shared__ uint sh_m[CUDA_BLK_SIZE_1D];
	__shared__ PlaneType sh_n[CUDA_BLK_SIZE_1D];
	__shared__ unsigned char sh_sbits[CUDA_BLK_SIZE_1D];
	__shared__ uint sh_encoded_bit_planes[CUDA_BLK_SIZE_1D];
	__shared__ int sh_emax[ZFP_BLK_PER_BLK_1D];
	__shared__ uint s_emax_bits[ZFP_BLK_PER_BLK_1D];

	uint tid = threadIdx.x + threadIdx.y * blockDim.x + threadIdx.z *blockDim.x*blockDim.y;

	Bitter bitter = make_bitter(0, 0);
  const uint word_bits = sizeof(Word) * 8;
  const uint total_words = (bsize * vals_per_cuda_block) / word_bits; 

  // init output stream 
	if (tid < total_words)
  {
    // TODO: not used
    sh_output[tid] = 0;
  }

  Scalar thread_val = sh_data[tid];

	__syncthreads();

  //
  // this is basically a no-op for int types
  //
  //if(tid < 4)
  floating_point_ops1(tid,
                      sh_q,
                      s_emax_bits,
                      sh_data,
                      sh_reduce,
                      sh_emax,
                      thread_val,
                      blocks,
                      blk_idx,
                      num_blocks,
                      bsize);
  #pragma warning "need to pass global index for writing exponents" 
	__syncthreads();

  //
  // In 1D we have zfp blocks of 4,
  // and we need to know the local position
  // of each thread
  //

  const int local_pos = tid % 4;
  const int block_start = (tid / 4) * 4/*vals_per_block*/;
  // Decorrelation
  if(local_pos == 0)
  { 
    fwd_lift<Int,1>(sh_q + block_start);
  }

	__syncthreads();
  // get negabinary representation
  // fwd_order in cpu code
	sh_p[tid] = int2uint(sh_q[tid]);

  
  // for 32 bit values, each warp will compress
  // 8 1D blocks (no need for synchs). for 64 bit values, 
  // two warps will compress 16 blocks (synchs needed).
  //TODO: perhaps each group should process a contiguous set of block
  // to avoid mem contention
  const uint work_size = intprec == 32 ? 8 : 16; // this is 1D specific
  const int block_stride = intprec == 32 ? 4 : 2; // works for both 1d and 2d
  int current_block = tid / intprec;
  const int bit_index = tid % intprec;
  /**********************Begin encode block *************************/
  for(uint block = 0; block < work_size; ++block)
  {
    const int block_start = current_block * vals_per_block;
    PlaneType y = 0;
    const PlaneType mask = 1;
	  /* extract bit plane k to x[k] */
    #pragma unroll 4 
    for (uint i = 0; i < vals_per_block; i++)
    {
      // TODO: this is the main bottlenect in terms 
      // of # of instructions. We could could change
      // this to a lookup table or some sort of
      // binary matrix transpose.
      y += ((sh_p[block_start + i] >> bit_index) & mask) << i;
    }
  
    //
    // For 1d blocks we only use 4 bits of the 16 bit 
    // unsigned short, so we will shift the bits left and 
    // ignore the remaining 12 bits when encoding
    //
    PlaneType z = y;
    int x = y;// << 16;
    // temporarily use sh_n as a buffer
    // these are setting up indices to things that have value
    // find the first 1 (in terms of most significant 
    // __clzll -- intrinsic for count the # of leading zeros 	
    sh_n[tid] = 32 /*total int bits*/ - __clz(x);
    
    // init sh_m each iteration
    sh_m[tid] = 0;
	  __syncthreads();
    if (bit_index < intprec - 1)
    {
      sh_m[tid] = sh_n[tid + 1];
    }
	  __syncthreads();
     
    // this is basically a scan
    if (bit_index == 0)
    {
      // begining of shared memory segment for each
      // block processed in parallel. Each block has
      // a bit_index == 0 at 0,32,64, and 96 (for 32bit)
      // and 0 and 64 for (64 bit types) == tid
      for (int i = intprec - 2; i >= 0; --i)
      {
        if (sh_m[tid + i] < sh_m[tid + i + 1])
        {
          sh_m[tid + i] = sh_m[tid + i + 1];
        }
      }
    }
    //if(tid < 32) printf("tid %d scan %d msb %d\n", tid, sh_m[tid], sh_n[tid]);
    __syncthreads();
    // maximum number of bits output per bit plane is 
    // 2 * 4^d - 1, i.e., 7, 31, and 127 for 1D, 2D, and 3D
    int bits = 32; // this is maxbits (line:82 encode.c -- zfp) 
    int n = 0;
    /* step 2: encode first n bits of bit plane */
    // substract the minimum number of bits needed to encode this number
    // which is at least the intprec - msb(tid+1)
    bits -= sh_m[tid]; 
    z >>= sh_m[tid]; // this only makes sense if bit plane msb is 0
    z = (sh_m[tid] != vals_per_block) * z; //if == size_of_bitplane set z to 0
    n = sh_m[tid];

    /* step 3.0 : count the number of bits for a run-length encoding*/
    for (; n < vals_per_block && bits && (bits--, !!z); z >>= 1, n++)
    {
      for (; n < vals_per_block - 1 && bits && (bits--, !(z & 1u)); z >>= 1, n++);
    }

    __syncthreads();

    bits = (32 - bits);
    sh_n[tid] = min(sh_m[tid], bits);

    BitStream32 out; 
    y = out.write_bits(y, sh_m[tid]);
    n = sh_n[tid];
  
	  /* step 3.1: unary run-length encode remainder of bit plane */
    for (; n < vals_per_block && bits && (bits-- && out.write_bit(!!y)); y >>= 1, n++)
    {
      for (; n < vals_per_block - 1 && bits && (bits-- && !out.write_bit(y & 1u)); y >>= 1, n++);
    }
	  __syncthreads();
    // reverse the order of the encoded bitplanes in shared mem
    // TODO: can't we just invert the bit plane from the beginning?
    //       that would just make this tid

    const int sh_mem_index = intprec - 1 - bit_index + (tid / intprec) * intprec; 
    sh_encoded_bit_planes[sh_mem_index] = out.bits;
    sh_sbits[sh_mem_index] = out.current_bits; // number of bits for bitplane

    // TODO: we need to get a scan of the number of bits each values is going 
    // to write so we can bitshift in parallel. We will resuse sh_m
    //sh_m[tid] = 0;
	  __syncthreads();

    if (bit_index == 0)
    {
      const uint max_bits = bsize * vals_per_block; 
      uint tot_sbits = s_emax_bits[current_block];// sbits[0];
      uint rem_sbits = max_bits - s_emax_bits[current_block];// sbits[0];
      BlockWriter<4> writer(blocks, bsize, blk_idx + current_block, num_blocks);
      for (int i = 0; i < intprec && tot_sbits < max_bits; i++)
      {
        uint n_bits = min(rem_sbits, sh_sbits[tid+i]); 
        writer.write_bits(sh_encoded_bit_planes[tid + i], n_bits, tot_sbits);
        tot_sbits += n_bits;
        rem_sbits -= n_bits;
      }
    } // end serial write
    current_block += block_stride;

  } //encode each block

  return;
}


template<class Scalar>
__global__
void __launch_bounds__(128,5)
cudaEncode1(const uint  bsize,
            const Scalar* data,
            Word *blocks,
            const int dim)
{
	__shared__ Scalar sh_data[CUDA_BLK_SIZE_1D];

  //share data over 32 blocks( 4 vals * 32 blocks= 128) 

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
	__syncthreads();
  // 32 1d zfp_blocks per cuda block of 128 with 32-bit types
  // 16 1d zfp_blocks per cuda block of 128 with 64-bit types
  int blocks_per_cuda_block = sizeof(Scalar) == 8 ? 16 : 32;
  const uint zfp_block_start = blockIdx.x * blocks_per_cuda_block; 

  int total_blocks = dim / 4; 
  if(dim % 4 != 0) total_blocks++;

	encode1<Scalar>(sh_data,
                  bsize, 
                  zfp_block_start,
                  blocks,
                  total_blocks);

  __syncthreads();

}

void allocate_device_mem1d(const int dim, 
                           const int bsize, 
                           thrust::device_vector<Word> &stream)
{
  
  const size_t vals_per_block = 4;
  size_t total_blocks = dim / vals_per_block; 
  if(dim % vals_per_block != 0) total_blocks++;
  const size_t bits_per_block = vals_per_block * bsize;
  const size_t bits_per_word = sizeof(Word) * 8;
  const size_t total_bits = bits_per_block * total_blocks;
  size_t alloc_size = total_bits / bits_per_word;
  if(total_bits % bits_per_word != 0) alloc_size++;
  stream.resize(alloc_size);
  // ensure we have zeros
  cudaMemset(thrust::raw_pointer_cast(stream.data()), 0, sizeof(Word) * alloc_size);
}

//
// Launch the encode kernel
//
template<class Scalar>
void encode1launch(int dim, 
                   const Scalar *d_data,
                   thrust::device_vector<Word> &stream,
                   const int bsize)
{
  std::cout<<"boomm\n";
  dim3 block_size, grid_size;
  block_size = dim3(CUDA_BLK_SIZE_1D, 1, 1);
  grid_size = dim3(dim, 1, 1);

  grid_size.x /= block_size.x; 

  // Check to see if we need to increase the block sizes
  // in the case where dim[x] is not a multiple of 4

  int encoded_dim = dim;

  if(encoded_dim % CUDA_BLK_SIZE_1D != 0) 
  {
    grid_size.x++;
    encoded_dim = grid_size.x * CUDA_BLK_SIZE_1D;
  }

  std::cout<<"allocating mem\n";
  allocate_device_mem1d(dim, bsize, stream);
  std::size_t dyn_shared = (ZFP_BLK_PER_BLK_1D * bsize * 4) / (sizeof(Word) * 8);
  std::cout<<"Dynamic shared mem size "<<dyn_shared<<"\n";
  //std::size_t shared_mem_size = sizeof(Scalar) * cuda_block_size 
  //                            + sizeof(Bitter) * cuda_block_size 
  //                            + sizeof(unsigned char) * cuda_block_size 
  //                            + sizeof(unsigned int) * 128 
  //                            + 2 * sizeof(int);

	cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);

  std::cout<<"event\n";
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  std::cout<<"Running kernel \n";
  std::cout<<"grid "<<grid_size.x<<" "<<grid_size.y<<" "<<grid_size.z<<"\n";
  std::cout<<"block "<<block_size.x<<" "<<block_size.y<<" "<<block_size.z<<"\n";
  cudaEventRecord(start);

	cudaEncode1<Scalar> << <grid_size, block_size, dyn_shared * sizeof(Word)>> >
    (bsize,
     d_data,
     thrust::raw_pointer_cast(stream.data()),
     dim);

  cudaEventRecord(stop);
  cudaEventSynchronize(stop);
  cudaStreamSynchronize(0);

  float miliseconds = 0.f;
  cudaEventElapsedTime(&miliseconds, start, stop);
  float seconds = miliseconds / 1000.f;
  printf("Encode elapsed time: %.5f (s)\n", seconds);
  float rate = (float(dim) * sizeof(Scalar) ) / seconds;
  rate /= 1024.f;
  rate /= 1024.f;
  printf("Encode rate: %.2f (MB / sec)\n", rate);
}

//
// Encode a host vector and output a encoded device vector
//
template<class Scalar>
void encode1(int dim,
             thrust::device_vector<Scalar> &d_data,
             thrust::device_vector<Word> &stream,
             const int bsize)
{
  std::cout<<"inside encode\n";
  encode1launch<Scalar>(dim, thrust::raw_pointer_cast(d_data.data()), stream, bsize);
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
