#include <iostream>
#include <thrust/device_vector.h>
#include <thrust/device_ptr.h>
#include <thrust/host_vector.h>
#include <thrust/random.h>
#include <thrust/transform.h>
#include <thrust/functional.h>
#include <thrust/execution_policy.h>
#include <cuda_runtime.h>
#include <assert.h>

#define KEPLER 0
#include "ErrorCheck.h"
#include "fixed_point.cuh"

using namespace thrust;
using namespace std;

#define FREXP(x, e) frexp(x, e)
#define LDEXP(x, e) ldexp(x, e)

const int nx = 256;
const int ny = 256;
const int nz = 256;


//Used to generate rand array in CUDA with Thrust
struct RandGen
{
    RandGen() {}

    __device__ float operator () (const uint idx)
    {
        thrust::default_random_engine randEng;
        thrust::uniform_real_distribution<float> uniDist;
        randEng.discard(idx);
        return uniDist(randEng);
    }
};

template<class Int, class Scalar>
void cpuTestFixedPoint
(
        Scalar *p
        )
{
    Int q[64];

    Int q2[64];
    for (int z=0; z<nz; z+=4){
        for (int y=0; y<ny; y+=4){
            for (int x=0; x<nx; x+=4){
                int idx = z*nx*ny + y*nx + x;
                int emax2 = max_exp<Scalar>(p, idx, 1,nx,nx*ny);
                fwd_cast(q2,p, emax2, idx, 1,nx,nx*ny);

                int emax = fwd_cast(q, p+idx, 1,nx,nx*ny);

                for (int i=0; i<64; i++){
                    assert(q[i] == q2[i]);
                }

            }
        }
    }

}

int main()
{
    device_vector<double> d_vec_in(nx*ny*nz), d_vec_out(nx*ny*nz);
    host_vector<double> h_vec_in(nx*ny*nz);

    thrust::counting_iterator<uint> index_sequence_begin(0);
    thrust::transform(
                    index_sequence_begin,
                    index_sequence_begin + nx*ny*nz,
                    d_vec_in.begin(),
                    RandGen());

    h_vec_in = d_vec_in;
    cpuTestFixedPoint<long long, double>(raw_pointer_cast(h_vec_in.data()));
}
