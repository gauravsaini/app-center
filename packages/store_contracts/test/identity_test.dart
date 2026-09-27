import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

/// Phase 3 slice 2 contract additions (phase3-slice2.md §1, §3):
/// `AppInfo.identitySignal` and `UnifiedApp.canonicalId`, both additive
/// (nullable, default null) — old call sites compile unchanged.
void main() {
  group('AppInfo.identitySignal', () {
    test('defaults to null (additive)', () {
      const app = AppInfo(
        identity: AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        name: 'Firefox',
        summary: 'Web browser',
        iconUrl: '',
        source: AppSource.snap,
      );
      expect(app.identitySignal, isNull);
    });

    test('const-compatible with a signal attached', () {
      const app = AppInfo(
        identity: AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        name: 'Firefox',
        summary: 'Web browser',
        iconUrl: '',
        source: AppSource.snap,
        identitySignal: IdentitySignal(
          appstreamId: 'org.mozilla.firefox',
          homepageUrl: 'https://www.mozilla.org/firefox/',
        ),
      );
      expect(app.identitySignal!.appstreamId, 'org.mozilla.firefox');
      expect(
        app.identitySignal!.homepageUrl,
        'https://www.mozilla.org/firefox/',
      );
    });
  });

  group('UnifiedApp.canonicalId', () {
    test('defaults to null (additive); preferred unchanged', () {
      const app = AppInfo(
        identity: AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        name: 'Firefox',
        summary: 'Web browser',
        iconUrl: '',
        source: AppSource.snap,
      );
      const unified = UnifiedApp(groupId: 'snap:firefox', variants: [app]);
      expect(unified.canonicalId, isNull);
      expect(unified.preferred, same(app));
    });

    test('const-compatible with a canonical id attached', () {
      const app = AppInfo(
        identity: AppIdentity(backendId: 'snap', nativeId: 'firefox'),
        name: 'Firefox',
        summary: 'Web browser',
        iconUrl: '',
        source: AppSource.snap,
      );
      const unified = UnifiedApp(
        groupId: 'appstream:org.mozilla.firefox',
        variants: [app],
        canonicalId: CanonicalAppId(
          CanonicalIdScheme.appstream,
          'org.mozilla.firefox',
        ),
      );
      expect(
        unified.canonicalId,
        CanonicalAppId.parse('appstream:org.mozilla.firefox'),
      );
    });
  });

  group('contract version', () {
    test('bumped to 0.4.0: additive members are a minor bump', () {
      // version.dart's documented rule: additive member → minor bump,
      // same as 0.2.0→0.3.0 was for identityLookupKey.
      expect(storeContractsVersion, '0.4.0');
      expect(storeContractsMajor, 0);
    });
  });
}
