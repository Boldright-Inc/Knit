// Parallel byte-histogram (entropy) probe.
//
// One threadgroup per input block. Each threadgroup walks its block, builds a
// 256-bin histogram in threadgroup memory using atomic adds, and writes the
// final histogram into device memory. The host computes Shannon entropy from
// the histogram in O(256) per block.
//
// Used by the compressor to (a) classify "incompressible" blocks (entropy
// >= ~7.5 bit/byte) and skip wasted compression work, and (b) feed the
// compressibility heatmap visualization with per-block entropy values.

#include <metal_stdlib>
using namespace metal;

struct ProbeParams {
    uint total_bytes;
    uint block_size;
    uint num_blocks;
};

kernel void byte_histogram(
    device const uchar  *input        [[buffer(0)]],
    device uint         *histograms   [[buffer(1)]],   // num_blocks * 256 uint
    constant ProbeParams &params      [[buffer(2)]],
    uint                 tid          [[thread_position_in_threadgroup]],
    uint                 group_id     [[threadgroup_position_in_grid]],
    uint                 group_size   [[threads_per_threadgroup]])
{
    if (group_id >= params.num_blocks) return;

    threadgroup atomic_uint local_hist[256];

    // Cooperative zero of the 256-bin local histogram.
    for (uint i = tid; i < 256; i += group_size) {
        atomic_store_explicit(&local_hist[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint block_start = group_id * params.block_size;
    if (block_start >= params.total_bytes) {
        // Pad past EOF: emit zero histogram.
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint i = tid; i < 256; i += group_size) {
            histograms[group_id * 256u + i] = 0u;
        }
        return;
    }
    uint block_end = min(block_start + params.block_size, params.total_bytes);
    uint block_len = block_end - block_start;

    // Strided walk: each lane bins (block_len / group_size) bytes.
    for (uint i = tid; i < block_len; i += group_size) {
        uchar b = input[block_start + i];
        atomic_fetch_add_explicit(&local_hist[uint(b)], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Write threadgroup histogram out to global memory.
    for (uint i = tid; i < 256; i += group_size) {
        uint v = atomic_load_explicit(&local_hist[i], memory_order_relaxed);
        histograms[group_id * 256u + i] = v;
    }
}
