import CryptoKit
import Foundation
import PropertyBased

/// Library RNG for retained legacy seeded sweeps. New properties use Generator
/// composition and propertyCheck so that failures shrink automatically.
struct DiscoveryRandom {
    private var random: Xoshiro
    init(seed: UInt64) {
        // Hash the domain-tagged seed to avoid overlapping streams and correlated
        // initial outputs from nearby seeds. Byte order is explicit and portable.
        let digest = Array(SHA256.hash(data: Data("Boutique.legacy-seed.v1:\(seed)".utf8)))
        func word(_ offset: Int) -> UInt64 {
            digest[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        random = Xoshiro(seed: (word(0), word(8), word(16), word(24)))
    }
    mutating func next() -> UInt64 { random.next() }
}
