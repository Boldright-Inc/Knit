#include "CZlibBridge.h"
#include <zlib.h>
#include <string.h>
#include <unistd.h>

// Compress a chunk to RAW DEFLATE. `windowBits = -15` selects raw (no zlib header/adler).
ssize_t bzip_chunk_deflate(
    int level,
    const void *in_buf, size_t in_size,
    void *out_buf, size_t out_avail,
    bzip_flush_mode_t mode)
{
    if (!out_buf || out_avail == 0) return -1;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    // -15 windowBits = raw deflate, 8 memLevel = default
    int rc = deflateInit2(&strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY);
    if (rc != Z_OK) return -1;

    strm.next_in   = (Bytef *)in_buf;
    strm.avail_in  = (uInt)in_size;
    strm.next_out  = (Bytef *)out_buf;
    strm.avail_out = (uInt)out_avail;

    int flush = (mode == BZIP_FLUSH_FINISH) ? Z_FINISH : Z_SYNC_FLUSH;
    rc = deflate(&strm, flush);

    if (mode == BZIP_FLUSH_FINISH) {
        if (rc != Z_STREAM_END) {
            deflateEnd(&strm);
            return -1;
        }
    } else {
        if (rc != Z_OK && rc != Z_BUF_ERROR) {
            deflateEnd(&strm);
            return -1;
        }
        // For SYNC_FLUSH on a small/empty input, deflate may produce 0 bytes
        // if there's nothing to flush. That's fine.
    }

    size_t produced = (size_t)((Bytef *)strm.next_out - (Bytef *)out_buf);
    deflateEnd(&strm);
    return (ssize_t)produced;
}

size_t bzip_chunk_deflate_bound(int level, size_t in_size)
{
    // zlib's deflateBound is conservative; we add a bit more for sync-flush markers.
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (deflateInit2(&strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return in_size + 1024;
    }
    size_t bound = (size_t)deflateBound(&strm, (uLong)in_size) + 16;
    deflateEnd(&strm);
    return bound;
}
