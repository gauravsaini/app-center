/// Scripted [SnapdTransport] for tests. Never touches the live system.
///
/// Import via `package:backend_snap/testing.dart` — kept out of the
/// main barrel so production code never depends on it.
library;

import 'dart:async';

import 'src/transport.dart';

class _ScriptedChange {
  _ScriptedChange({
    required this.kind,
    required this.snapNames,
    required this.script,
  });

  final String kind;
  final List<String> snapNames;
  final List<SnapdChangeSnapshot> script;
  var polls = 0;
  var aborted = false;
}

SnapdChangeSnapshot _doing(
  String id,
  String kind,
  List<String> snapNames,
  List<SnapdTaskSnapshot> tasks,
) => SnapdChangeSnapshot(
  id: id,
  kind: kind,
  status: 'Doing',
  ready: false,
  error: '',
  snapNames: snapNames,
  tasks: tasks,
);

SnapdChangeSnapshot _done(String id, String kind, List<String> snapNames) =>
    SnapdChangeSnapshot(
      id: id,
      kind: kind,
      status: 'Done',
      ready: true,
      error: '',
      snapNames: snapNames,
      tasks: const [],
    );

List<SnapdChangeSnapshot> _installScript(String id, String name) => [
  SnapdChangeSnapshot(
    id: id,
    kind: 'install',
    status: 'Do',
    ready: false,
    error: '',
    snapNames: [name],
    tasks: const [],
  ),
  _doing(
    id,
    'install',
    [name],
    const [
      SnapdTaskSnapshot(
        kind: 'download-snap',
        status: 'Doing',
        done: 10,
        total: 100,
      ),
    ],
  ),
  _doing(
    id,
    'install',
    [name],
    const [
      SnapdTaskSnapshot(
        kind: 'download-snap',
        status: 'Doing',
        done: 50,
        total: 100,
      ),
    ],
  ),
  _doing(
    id,
    'install',
    [name],
    const [
      SnapdTaskSnapshot(
        kind: 'download-snap',
        status: 'Doing',
        done: 90,
        total: 100,
      ),
    ],
  ),
  _doing(
    id,
    'install',
    [name],
    const [
      SnapdTaskSnapshot(
        kind: 'validate-snap',
        status: 'Doing',
        done: 0,
        total: 0,
      ),
    ],
  ),
  _doing(
    id,
    'install',
    [name],
    const [
      SnapdTaskSnapshot(kind: 'link-snap', status: 'Doing', done: 0, total: 0),
    ],
  ),
  _done(id, 'install', [name]),
];

List<SnapdChangeSnapshot> _quickScript(String id, String kind, String name) => [
  SnapdChangeSnapshot(
    id: id,
    kind: kind,
    status: 'Do',
    ready: false,
    error: '',
    snapNames: [name],
    tasks: const [],
  ),
  _doing(
    id,
    kind,
    [name],
    const [
      SnapdTaskSnapshot(kind: 'link-snap', status: 'Doing', done: 0, total: 0),
    ],
  ),
  _done(id, kind, [name]),
];

class StubSnapdTransport extends SnapdTransport {
  StubSnapdTransport() {
    // A change that "outlived the app" — for recoverInFlight.
    _changes['change-recover'] = _ScriptedChange(
      kind: 'install',
      snapNames: ['recover-snap'],
      script: [
        _doing(
          'change-recover',
          'install',
          ['recover-snap'],
          const [
            SnapdTaskSnapshot(
              kind: 'download-snap',
              status: 'Doing',
              done: 30,
              total: 100,
            ),
          ],
        ),
        _doing(
          'change-recover',
          'install',
          ['recover-snap'],
          const [
            SnapdTaskSnapshot(
              kind: 'download-snap',
              status: 'Doing',
              done: 70,
              total: 100,
            ),
          ],
        ),
        _done('change-recover', 'install', ['recover-snap']),
      ],
    );
  }

  final _changes = <String, _ScriptedChange>{};
  var _nextId = 0;

  String _spawn(
    String kind,
    String name,
    List<SnapdChangeSnapshot> Function(String) script,
  ) {
    final id = 'change-${_nextId++}';
    _changes[id] = _ScriptedChange(
      kind: kind,
      snapNames: [name],
      script: script(id),
    );
    return id;
  }

  @override
  Future<void> checkAvailable() async {}

  @override
  Future<List<SnapSummaryData>> find(String query) async => const [
    SnapSummaryData(
      name: 'test-snap',
      title: 'Test Snap',
      summary: 'a test snap',
      description: 'A longer description of the test snap.',
      version: '1.0',
      iconUrl: '',
      confinement: 'strict',
    ),
  ];

  @override
  Future<SnapSummaryData> getDetails(String name) async {
    if (name == 'test-snap') return (await find('')).first;
    if (name == 'installed-snap') {
      return const SnapSummaryData(
        name: 'installed-snap',
        title: 'Installed Snap',
        summary: 'an installed snap',
        description: 'Installed, classic confinement.',
        version: '2.0',
        iconUrl: '',
        confinement: 'classic',
        installedVersion: '2.0',
      );
    }
    throw SnapdNotFoundException('snap "$name" not found');
  }

  @override
  Future<List<String>> installedNames() async => const ['installed-snap'];

  @override
  Future<List<SnapSummaryData>> updatesAvailable() async => const [
    SnapSummaryData(
      name: 'installed-snap',
      title: 'Installed Snap',
      summary: '',
      description: '',
      version: '2.1',
      iconUrl: '',
      confinement: 'classic',
      installedVersion: '2.0',
    ),
  ];

  @override
  Future<String> install(String name, {required bool classic}) async {
    if (name == 'no.such.snap') {
      throw SnapdNotFoundException('snap "$name" not found');
    }
    return _spawn('install', name, (id) => _installScript(id, name));
  }

  @override
  Future<String> remove(String name) async =>
      _spawn('remove', name, (id) => _quickScript(id, 'remove', name));

  @override
  Future<String> refresh(String name) async =>
      _spawn('refresh', name, (id) => _quickScript(id, 'refresh', name));

  @override
  Future<SnapdChangeSnapshot> getChange(String id) async {
    final c = _changes[id];
    if (c == null) throw SnapdTransportException('unknown change $id');
    if (c.aborted) {
      return SnapdChangeSnapshot(
        id: id,
        kind: c.kind,
        status: 'Error',
        ready: true,
        error: 'aborted by client',
        snapNames: c.snapNames,
        tasks: const [],
      );
    }
    final i = c.polls++;
    return c.script[i < c.script.length ? i : c.script.length - 1];
  }

  @override
  Future<List<SnapdChangeSnapshot>> inProgressChanges() async => [
    for (final e in _changes.entries)
      if (e.key == 'change-recover')
        SnapdChangeSnapshot(
          id: e.key,
          kind: e.value.kind,
          status: 'Doing',
          ready: false,
          error: '',
          snapNames: e.value.snapNames,
          tasks: const [],
        ),
  ];

  @override
  Future<void> abortChange(String id) async {
    final c = _changes[id];
    if (c != null) c.aborted = true;
  }
}
