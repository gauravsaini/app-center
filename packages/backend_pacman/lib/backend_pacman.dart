/// `backend_pacman` — the pacman backend (Arch-like systems).
///
/// CLI-subprocess transport: talks to the `pacman(1)` binary (and
/// `checkupdates` from pacman-contrib), never to libalpm directly.
/// Mutating operations elevate via `pkexec pacman` (polkit).
///
/// Identity is pacman's verbatim 4-token package-id
/// (`name;version;arch;repo`); the version is opaque end-to-end
/// (epoch prefix carried verbatim, never split). Cards are keyed by
/// name alone — alpm's local db is name-keyed, and Arch multilib
/// renames (`lib32-*`) instead of multi-arching, so same-name
/// multi-arch installs cannot exist (research §3). Everything the
/// backend needs from the outside world goes through
/// [PacmanTransport], so tests script a stub and never touch the
/// live system.
///
/// ```dart
/// final backend = BackendPacman(transport: CliPacmanTransport());
/// await runContractExam('pacman', () => backend, ...);
/// ```
library backend_pacman;

export 'src/backend.dart';
export 'src/cli_transport.dart';
export 'src/identity.dart';
export 'src/metadata.dart';
export 'src/transport.dart';
