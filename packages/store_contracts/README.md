# store_contracts

The law. Stable, versioned interfaces every store backend implements and
the host consumes (ADR-002). Zero dependencies.

## What's in here

| File | What |
|---|---|
| `lib/src/backend.dart` | `StoreBackend` — the plugin interface |
| `lib/src/identity.dart` | `AppIdentity`, `AppInfo`, `AppDetails`, `Permission` |
| `lib/src/operation.dart` | `OperationHandle`, the 11-state sealed `OperationState`, `legalTransitions` |
| `lib/src/errors.dart` | Typed `StoreException` hierarchy + `Remediation` |
| `lib/src/catalog.dart` | `UnifiedCatalog`, `UnifiedApp` (host-side) |
| `lib/src/engine.dart` | `OperationEngine` (host-side) |
| `lib/src/flags.dart` | `FeatureFlags` (host-side) |
| `lib/exam.dart` | **The contract exam** — every backend must pass it |

## Versioning

`storeContractsVersion` follows SemVer. Additive changes bump minor;
breaking changes bump major. Backends declare the major they implement
via `StoreBackend.contractVersion`; the host refuses mismatched majors.

## Implementing a backend

1. Implement `StoreBackend` for your transport (snapd socket, CLI, D-Bus…).
2. Map every native error into a `StoreException` subtype. `UnknownStoreException`
   is a bug-report generator, not a user message.
3. Never show your own dialogs; never block the UI thread; `isAvailable()`
   stays under 200ms with no side effects.
4. Prove it: run the exam with a **stubbed transport** (canned responses —
   never the live system):

```dart
import 'package:store_contracts/exam.dart';

test('flatpak passes the contract exam', () => runContractExam(
      'flatpak',
      () => BackendFlatpak(transport: StubTransport.canned()),
      installTarget: const AppIdentity(backendId: 'flatpak', nativeId: 'org.test.App'),
      unknownTarget: const AppIdentity(backendId: 'flatpak', nativeId: 'no.such.App'),
      installedTarget: const AppIdentity(backendId: 'flatpak', nativeId: 'org.test.Installed'),
    ));
```

The exam checks: legal DAG transitions, first-state discipline, cancel
reaching terminal (Cancelled/Done, never bare Failed), monotonic progress,
typed errors with non-empty code/detail, idempotent no-op installs,
terminal silence, and `recoverInFlight` starting at `Restoring`.

## Tests

```bash
dart test   # or: melos test (runs the exam against the in-memory fake)
```

`test/fake_backend.dart` is the reference: an in-memory backend the exam
passes against, proving the exam itself is sound. It also includes a
negative test — a backend jumping `Queued → Done` without `noop` fails.
