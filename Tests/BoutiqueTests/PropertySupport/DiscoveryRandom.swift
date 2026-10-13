import PropertyBased

/// Library RNG for retained legacy seeded sweeps. New properties use Generator
/// composition and propertyCheck so that failures shrink automatically.
struct DiscoveryRandom {
    private var random: Xoshiro
    init(seed: UInt64) {
        // Separate seed words avoid the old seed*n / increment-by-n shifted streams.
        random = Xoshiro(seed: (seed ^ 0x243F6A8885A308D3,
                               seed ^ 0x13198A2E03707344,
                               seed ^ 0xA4093822299F31D0,
                               seed ^ 0x082EFA98EC4E6C89))
    }
    mutating func next() -> UInt64 { random.next() }
}
