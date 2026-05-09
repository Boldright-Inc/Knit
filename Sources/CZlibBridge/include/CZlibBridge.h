// Bridge to system zlib for chunk-parallel DEFLATE compression.
//
// pigz-style parallelism requires Z_SYNC_FLUSH boundaries between threads so
// the resulting raw DEFLATE streams can be concatenated. libdeflate doesn't
// expose flush semantics — system zlib does, and macOS ships it.

#ifndef CZLIBBRIDGE_H
#define CZLIBBRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Modes for bzip_chunk_deflate:
//   0 = Z_SYNC_FLUSH — flush boundary, output ends with 00 00 ff ff
//   1 = Z_FINISH     — final block, output ends with end-of-stream marker
//   2 = Z_NO_FLUSH   — produce nothing more than current dict gives (rarely useful here)
typedef enum {
    BZIP_FLUSH_SYNC   = 0,
    BZIP_FLUSH_FINISH = 1
} bzip_flush_mode_t;

// Compress a single contiguous chunk to RAW DEFLATE (no zlib/gzip wrapper).
// Returns produced bytes on success, or -1 on error.
//
// `level` = 0..9 (zlib semantics; differs from libdeflate's 0..12).
ssize_t bzip_chunk_deflate(
    int level,
    const void *in_buf, size_t in_size,
    void *out_buf, size_t out_avail,
    bzip_flush_mode_t mode);

// Worst-case output bound for a chunk of `in_size` raw bytes at `level`.
size_t bzip_chunk_deflate_bound(int level, size_t in_size);

#ifdef __cplusplus
}
#endif
#endif
