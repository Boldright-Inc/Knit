import Foundation

/// .knit — Knit archive format, v1.
///
/// Designed for GPU-friendly, block-parallel zstd compression.
///
/// ```text
/// [Header]
/// uint32 magic   = 0x54494E4B  ("KNIT" little-endian)
/// uint16 version = 1
/// uint16 flags   = 0
/// uint64 reserved
///
/// [Repeated entries]
/// uint32 entry_marker = 0x4B4E_0001  ("KN" + entry tag)
/// uint16 name_len
/// utf8   name
/// uint16 mode
/// uint64 mod_unix     (seconds)
/// uint8  is_directory
/// uint32 block_size   (raw input bytes per block)
/// uint64 uncompressed_size
/// uint64 compressed_size
/// uint32 crc32
/// uint32 num_blocks
/// uint32 block_lengths[num_blocks]   (compressed bytes per block)
/// raw    block_data[]                (concatenated zstd frames)
///
/// [Footer]
/// uint32 footer_marker = 0x4B4E_FFFF
/// uint64 total_entries
/// uint32 archive_version = 1
/// ```
///
/// Each block is an independent zstd frame, so the format supports random
/// access decompression and parallel encoding/decoding without any global
/// dictionary state.
public enum KnitFormat {
    /// Magic bytes "KNIT" (0x4B 0x4E 0x49 0x54) read little-endian as UInt32.
    public static let headerMagic: UInt32 = 0x5449_4E4B
    public static let version: UInt16 = 1
    public static let entryMarker: UInt32 = 0x4B4E_0001
    public static let footerMarker: UInt32 = 0x4B4E_FFFF
    public static let archiveVersion: UInt32 = 1
    public static let defaultBlockSize: UInt32 = 1 * 1024 * 1024
}
