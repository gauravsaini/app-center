/// [PackageSnapdTransport]: the real transport, over `package:snapd`.
library;

import 'package:snapd/snapd.dart';

import 'transport.dart';

class PackageSnapdTransport extends SnapdTransport {
  PackageSnapdTransport({SnapdClient? client})
    : _client = client ?? SnapdClient();

  final SnapdClient _client;

  SnapdTransportException _wrap(Object e) =>
      SnapdTransportException(e.toString());

  @override
  Future<void> checkAvailable() async {
    try {
      await _client.systemInfo().timeout(const Duration(seconds: 2));
    } catch (e) {
      throw _wrap(e);
    }
  }

  SnapSummaryData _toData(Snap s) {
    var iconUrl = '';
    for (final m in s.media) {
      if (m.type == 'icon') {
        iconUrl = m.url;
        break;
      }
    }
    return SnapSummaryData(
      name: s.name,
      title: s.title ?? s.name,
      summary: s.summary,
      description: s.description,
      version: s.version,
      iconUrl: iconUrl,
      confinement: s.confinement.name,
    );
  }

  @override
  Future<List<SnapSummaryData>> find(String query) async {
    try {
      final snaps = await _client.find(query: query);
      return snaps.map(_toData).toList();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<SnapSummaryData> getDetails(String name) async {
    try {
      return _toData(await _client.getSnap(name));
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('not found') || msg.contains('no snap')) {
        throw SnapdNotFoundException(e.toString());
      }
      throw _wrap(e);
    }
  }

  @override
  Future<List<String>> installedNames() async {
    try {
      final snaps = await _client.getSnaps();
      return [for (final s in snaps) s.name];
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<SnapSummaryData>> installedSnaps() async {
    try {
      final snaps = await _client.getSnaps();
      return snaps.map(_toData).toList();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<SnapSummaryData>> updatesAvailable() async {
    try {
      final snaps = await _client.find(filter: SnapFindFilter.refresh);
      return snaps.map(_toData).toList();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<String> install(String name, {required bool classic}) async {
    try {
      return await _client.install(name, classic: classic);
    } catch (e) {
      throw _snapNotFoundOrWrap(e);
    }
  }

  @override
  Future<String> remove(String name) async {
    try {
      return await _client.remove(name);
    } catch (e) {
      throw _snapNotFoundOrWrap(e);
    }
  }

  @override
  Future<String> refresh(String name) async {
    try {
      return await _client.refresh(name);
    } catch (e) {
      throw _snapNotFoundOrWrap(e);
    }
  }

  SnapdTransportException _snapNotFoundOrWrap(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('not found') ||
        msg.contains('no snap') ||
        msg.contains('not installed')) {
      return SnapdNotFoundException(e.toString());
    }
    return _wrap(e);
  }

  SnapdTaskSnapshot _taskToSnapshot(SnapdTask t) => SnapdTaskSnapshot(
    kind: t.kind ?? '',
    status: t.status ?? '',
    done: t.progress.done,
    total: t.progress.total,
  );

  SnapdChangeSnapshot _changeToSnapshot(SnapdChange c) => SnapdChangeSnapshot(
    id: c.id,
    kind: c.kind ?? '',
    status: c.status ?? '',
    ready: c.ready,
    error: c.err ?? '',
    snapNames: c.snapNames,
    tasks: [for (final t in c.tasks) _taskToSnapshot(t)],
  );

  @override
  Future<SnapdChangeSnapshot> getChange(String id) async {
    try {
      return _changeToSnapshot(await _client.getChange(id));
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<List<SnapdChangeSnapshot>> inProgressChanges() async {
    try {
      final changes = await _client.getChanges(
        filter: SnapdChangeFilter.inProgress,
      );
      return changes.map(_changeToSnapshot).toList();
    } catch (e) {
      throw _wrap(e);
    }
  }

  @override
  Future<void> abortChange(String id) async {
    try {
      await _client.abortChange(id);
    } catch (e) {
      throw _wrap(e);
    }
  }
}
