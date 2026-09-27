# Manage-strangle LLD

Parent: [manage-strangle-hld.md](manage-strangle-hld.md).
Sibling: [lld.md](lld.md) — the contract law.

## 1. Entities touched

| Entity | Package | Change |
|---|---|---|
| `StoreBackend` | `store_contracts` | + `listInstalled()` with default `[]` |
| `runContractExam` | `store_contracts` (`exam.dart`) | + listInstalled check |
| `StoreHost` | `store_host` (`host.dart`) | wire `installed()` |
| `MapFeatureFlags` | `store_host` (`flags.dart`) | + `pages.manage.unified` default `false` |
| composition root | `app_center` (`store_host_wiring.dart`) | no change (backends registered once) |

`UnifiedCatalog.installed()` already exists in `catalog.dart` — unchanged.

## 2. `StoreBackend.listInstalled()` — exact contract

```dart
/// Installed apps managed by this backend.
///
/// PRE: none. A backend that cannot enumerate its installed apps
///   returns [] (the default) — "not supported".
/// POST: every returned [AppInfo.identity.backendId] == this backend's
///   `id`. Identities from another backend are a contract violation
///   (exam-enforced).
/// THROWS: [StoreException] subtypes only — never raw errors. The host
///   catches regardless, but a raw throw fails the exam.
/// NOTE: the default implementation returns []. Backends inherit this
///   and keep compiling — this is the LLD §10 additive path
///   (new optional method with a default, minor bump).
Future<List<AppInfo>> listInstalled() => Future.value(const []);
```

Invariants (exam-enforced):

1. Completes within 10s (timeout guard; same budget family as
   `recoverInFlight()`).
2. `app.identity.backendId == backend.id` for every returned app.
3. Throwing is legal; the thrown value must be a `StoreException`.
   Raw `Exception`/`Error` → `ExamFailure`.
4. Default (un-overridden) → `[]`, provably: the exam instantiates a
   backend that does not override the method and expects `[]`.

## 3. `StoreHost.installed()` — wiring

```dart
@override
Future<List<UnifiedApp>> installed() async {
  final out = <UnifiedApp>[];
  for (final b in await enabledBackends()) {
    try {
      for (final app in await b.listInstalled()) {
        out.add(
          UnifiedApp(
            groupId: '${b.id}:${app.identity.nativeId}',
            variants: [app],
          ),
        );
      }
    } catch (_) {
      // One backend failing degrades to partial results —
      // mirrors checkUpdates() in this file.
    }
  }
  return out;
}
```

Properties:

- Mirrors `checkUpdates()`: sequential fan-out over `enabledBackends()`
  (flag-enabled AND `isAvailable()`), per-backend try/catch, **never
  throws itself**. Sequential (not parallel) is deliberate — this is
  the same fan-out discipline as `checkUpdates()`, and installed lists
  are small; parallelism becomes a scheduling concern when the Updates
  page wiring lands.
- `groupId` construction is identical to `search()`:
  `'${b.id}:${app.identity.nativeId}'`. v1: no cross-backend merging.
- Uses the backend's `id` for the groupId prefix, not
  `app.identity.backendId` — the exam guarantees they are equal, and
  the host side must not trust data it hasn't verified.
- No flag gate inside `installed()`: the flag gates the *page*
  (legacy vs unified path), not the host method. `search()` is not
  flag-gated either; flags gate backends, not catalog reads.

## 4. Flag: `pages.manage.unified`

```dart
'pages.manage.unified': false,
```

Key conventions (ADR-010):

- Convention: `pages.<page>.unified` — per-page strangler switch:
  `true` = page reads from `StoreHost`; `false` (default) = legacy path.
- Owner: `libreapp-center`.
- Removal date: `2027-06-30` — by then Manage must be fully unified
  and the flag deleted, not inherited.
- Registered in `MapFeatureFlags._defaults`; documented in the
  key-conventions doc comment in `flags.dart`; unknown keys still
  never throw.

## 5. Exam delta

`runContractExam` gains `_listInstalled()`:

```dart
Future<void> _listInstalled(String check, StoreBackend Function() create) async {
  final backend = create();
  late final List<AppInfo> apps;
  try {
    apps = await backend.listInstalled().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw ExamFailure('$check: listInstalled() hung'),
    );
  } on StoreException catch (e) {
    _assertTypedError(check, e); // typed throw is legal
    return;
  } catch (e) {
    _fail(check, 'threw raw ${e.runtimeType}, not a StoreException');
  }
  for (final app in apps) {
    if (app.identity.backendId != backend.id) {
      _fail(check, 'identity ${app.identity} carries backendId '
        '${app.identity.backendId} != ${backend.id}');
    }
  }
}
```

And a `_defaultListInstalled()` check against a backend that does not
override the method (expects `[]`) — this pins the additive default so
a future "mandatory" change can't sneak in without a major bump.

## 6. Test matrix

`store_contracts` (`test/exam_test.dart`):

- Fake backend returns canned installed apps → exam passes, identities
  verified.
- A backend whose `listInstalled()` throws a raw `Exception` fails the
  exam (exam must bite).
- A backend that doesn't override `listInstalled()` passes with `[]`.

`store_host` (`test/host_test.dart`):

- Two stub backends return apps → merged list, groupIds
  `<backendId>:<nativeId>`, one variant each.
- One stub backend throws `StoreException` → partial results from the
  other; `installed()` itself does not throw.
- No enabled backends (flag off) → `[]`.
- `pages.manage.unified` default `false`; unknown keys never throw.

## 7. Versioning

- `packages/store_contracts/pubspec.yaml`: `0.1.0` → `0.2.0`.
- `lib/src/version.dart`: `storeContractsVersion` → `'0.2.0'`.
  `storeContractsMajor` stays `0`; `StoreBackend.contractVersion`
  stays `0` — the host still accepts every backend. LLD §10 additive
  path: new optional method with a default = minor.
- `packages/app_center/pubspec.yaml`: `store_contracts: ^0.1.0` →
  `^0.2.0` (0.x caret: `^0.1.0` excludes `0.2.0`).
- No other pins on `store_contracts` exist in the repo
  (grep `store_contracts: ^` across `pubspec.yaml` files).

## 8. Out of scope (repeats HLD §6, contract-level)

- Real backend implementations (`backend_snap`, `backend_deb`,
  `backend_flatpak` `listInstalled()`): later slices, each exam-first.
- Cross-backend dedupe, caching/staggering, capability advertising,
  Manage-page UI migration. The host method is ready; the page flips
  under `pages.manage.unified` in its own slice.
