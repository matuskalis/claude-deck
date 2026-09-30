import Testing

/// Parent of every suite that redirects `HookInstaller.settingsURL` or
/// `EventsSpool.directory`.
///
/// Those are process-global, and Swift Testing runs suites in parallel with each other even
/// when each is `.serialized` internally — so two suites pointing them at their own
/// temporary directories will interleave, and one will restore a path while the other is
/// still using it. That passed locally and failed on CI, which is the usual way round.
/// Serialising the parent serialises the children.
///
/// A child that writes fixtures calls `Hermetic.reset()` from its `init` to get a
/// throwaway home directory, so nothing it does can reach the developer's real `~/.claude`.
@Suite(.serialized)
struct DeckTests {}
