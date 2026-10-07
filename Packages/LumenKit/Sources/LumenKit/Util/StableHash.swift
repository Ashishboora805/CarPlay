import Foundation

/// Deterministic, process-independent hashing (Swift's `Hasher` is randomly seeded per launch,
/// so it can't be used for identifiers or cache file names that must survive relaunches).
public enum StableHash {
    /// 64-bit FNV-1a over the UTF-8 bytes of `string`.
    public static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Fixed-width (16 character) lowercase hex representation of `fnv1a64`.
    public static func hex(_ string: String) -> String {
        let raw = String(fnv1a64(string), radix: 16)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}
