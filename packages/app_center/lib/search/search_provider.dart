import 'dart:async';

import 'package:app_center/appstream/appstream.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/store/store_host_wiring.dart';
import 'package:appstream/appstream.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:snapd/snapd.dart';
import 'package:store_host/store_host.dart';

enum PackageFormat { snap, deb }

final queryProvider = StateProvider<String?>((_) => null);

final packageFormatProvider = StateProvider.autoDispose<PackageFormat>(
  (_) => PackageFormat.snap,
);

typedef AutoCompleteOptions = ({
  Iterable<Snap> snaps,
  Iterable<AppstreamComponent> debs,
});

final autoCompleteProvider = FutureProvider<AutoCompleteOptions>((ref) async {
  final query = ref.watch(queryProvider);

  // The completer is used to make sure no queries are sent if the provider is
  // already disposed.
  final completer = Completer();
  ref.onDispose(completer.complete);

  // Wait for a short duration before sending off the query (i.e. wait until
  // the user stops typing). This also helps to ensure the results arrive in
  // the correct order.
  await Future.delayed(const Duration(milliseconds: 100));

  if ((query?.isNotEmpty ?? true) && !completer.isCompleted) {
    final results = await Future.wait([
      ref.watch(snapSearchProvider(SnapSearchParameters(query: query)).future),
      ref.watch(appstreamSearchProvider(query ?? '').future),
    ]);
    final snaps = results[0] as List<Snap>;
    final debs = results[1] as List<AppstreamComponent>;
    return (snaps: snaps, debs: debs);
  }
  return (snaps: <Snap>[], debs: <AppstreamComponent>[]);
});

/// Unified-store search (strangler-fig slice).
///
/// Collects the [UnifiedApp] stream from [StoreHost.search] into a growing
/// list — one emission per backend result batch, so the UI renders
/// progressively. Cancelling the subscription (provider auto-dispose)
/// cancels backend work. A backend failing or stalling degrades to
/// partial results; the host never fails the whole search.
///
/// When the host stream closes (all backends done, or none available),
/// the final list is emitted — an empty list renders the normal empty
/// state instead of spinning forever.
///
/// No `backend_*` import here by design: this file sees only the host
/// and the contracts.
final unifiedSearchProvider = StreamProvider.family<List<UnifiedApp>, String>(
  (ref, query) async* {
    final host = ref.watch(storeHostProvider);
    final collected = <UnifiedApp>[];
    await for (final app in host.search(query)) {
      collected.add(app);
      yield List.unmodifiable(collected);
    }
    yield List.unmodifiable(collected);
  },
);

/// Snap slice of the unified search: only `backendId == 'snap'` results.
/// Derived from [unifiedSearchProvider] so both share one host
/// subscription per query.
final unifiedSnapSearchProvider =
    Provider.family<AsyncValue<List<UnifiedApp>>, String>((ref, query) {
      return ref
          .watch(unifiedSearchProvider(query))
          .whenData(
            (apps) => apps
                .where((app) => app.preferred.identity.backendId == 'snap')
                .toList(growable: false),
          );
    });
