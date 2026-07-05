#ifndef ROONVIS_COMPRESSION_UTILS_PORTABLE_H_
#define ROONVIS_COMPRESSION_UTILS_PORTABLE_H_

#include <string.h>
#include <zlib.h>

namespace zlib_internal
{
inline uLong GzipExpectedCompressedSize(uLong sourceLen)
{
    return compressBound(sourceLen) + 18;
}

inline int GzipCompressHelper(Bytef *dest,
                              uLongf *destLen,
                              const Bytef *source,
                              uLong sourceLen,
                              void * /*malloc_fn*/,
                              void * /*free_fn*/)
{
    z_stream stream = {};
    int ret = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8,
                           Z_DEFAULT_STRATEGY);
    if (ret != Z_OK)
    {
        return ret;
    }

    stream.next_in = const_cast<Bytef *>(source);
    stream.avail_in = static_cast<uInt>(sourceLen);
    stream.next_out = dest;
    stream.avail_out = static_cast<uInt>(*destLen);

    ret = deflate(&stream, Z_FINISH);
    *destLen = stream.total_out;
    deflateEnd(&stream);
    return ret == Z_STREAM_END ? Z_OK : ret;
}

inline uint32_t GetGzipUncompressedSize(const Bytef *source, uLong sourceLen)
{
    if (sourceLen < 4)
    {
        return 0;
    }
    uint32_t result = 0;
    memcpy(&result, source + sourceLen - 4, sizeof(result));
    return result;
}

inline int GzipUncompressHelper(Bytef *dest, uLongf *destLen, const Bytef *source, uLong sourceLen)
{
    z_stream stream = {};
    int ret = inflateInit2(&stream, MAX_WBITS + 16);
    if (ret != Z_OK)
    {
        return ret;
    }

    stream.next_in = const_cast<Bytef *>(source);
    stream.avail_in = static_cast<uInt>(sourceLen);
    stream.next_out = dest;
    stream.avail_out = static_cast<uInt>(*destLen);

    ret = inflate(&stream, Z_FINISH);
    *destLen = stream.total_out;
    inflateEnd(&stream);
    return ret == Z_STREAM_END ? Z_OK : ret;
}
}  // namespace zlib_internal

#endif  // ROONVIS_COMPRESSION_UTILS_PORTABLE_H_
