#ifndef WRITEBITTER_H
#define WRITEBITTER_H
#include "ull128.h"

unsigned long long
__device__ __host__
write_bitters(Bitter &bitters, Bitter value, uint n, unsigned char &sbits)
{
	if (n == bitsize(value.x)){
		bitters.x = value.x;
		bitters.y = value.y;
		sbits += n;
		return 0;
	}
	else{
		Bitter v = rshiftull2(value, n);
		Bitter ret = rshiftull2(value, n);
		v = lshiftull2(v, n);
		value = subull2(value, v);

		v = lshiftull2(value, sbits);
		bitters.x += v.x;
		bitters.y += v.y;

		sbits += n;
		return ret.x;
	}
}

__device__ __host__
void
write_bitter(Bitter &bitters, Bitter bit, unsigned char &sbits)
{
	Bitter val = lshiftull2(bit, sbits++);
	bitters.x += val.x;
	bitters.y += val.y;
}

__device__ __host__
void
write_out(unsigned long long *out, uint &tot_sbits, uint &offset, unsigned long long value, uint sbits)
{

	out[offset] += value << tot_sbits;
	tot_sbits += sbits;
	if (tot_sbits >= wsize) {
		tot_sbits -= wsize;
		offset++;
		if (tot_sbits > 0)
			out[offset] = value >> (sbits - tot_sbits);
	}
}


__shared__ Bitter sh_bitters[64];
__device__ __host__
void
write_outx(unsigned long long *out, uint &tot_sbits, uint &offset, unsigned long idx, uint sbits)
{

	out[offset] += sh_bitters[idx].x << tot_sbits;
	tot_sbits += sbits;
	if (tot_sbits >= wsize) {
		tot_sbits -= wsize;
		offset++;
		if (tot_sbits > 0)
			out[offset] = sh_bitters[idx].x >> (sbits - tot_sbits);
	}
}
__device__ __host__
void
write_outy(unsigned long long *out, uint &tot_sbits, uint &offset, unsigned long idx, uint sbits)
{

	out[offset] += sh_bitters[idx].y << tot_sbits;
	tot_sbits += sbits;
	if (tot_sbits >= wsize) {
		tot_sbits -= wsize;
		offset++;
		if (tot_sbits > 0)
			out[offset] = sh_bitters[idx].y >> (sbits - tot_sbits);
	}
}
#endif