import 'package:store_contracts/store_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('PhaseHeartbeat', () {
    test('silent 59s does not beat, 60s does', () {
      var now = DateTime(2026, 9, 27, 12);
      final hb = PhaseHeartbeat(clock: () => now);
      const dl = Downloading(bytesDone: 1, bytesTotal: 10);

      hb.markEmitted();
      now = now.add(const Duration(seconds: 59));
      expect(hb.shouldBeat(dl), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(hb.shouldBeat(dl), isTrue);
    });

    test('markEmitted resets the silence timer', () {
      var now = DateTime(2026, 9, 27, 12);
      final hb = PhaseHeartbeat(clock: () => now);
      const dl = Downloading(bytesDone: 1, bytesTotal: 10);

      hb.markEmitted();
      now = now.add(const Duration(seconds: 50));
      hb.markEmitted();
      now = now.add(const Duration(seconds: 50));
      expect(hb.shouldBeat(dl), isFalse);
      now = now.add(const Duration(seconds: 10));
      expect(hb.shouldBeat(dl), isTrue);
    });

    test('only downloading and applying beat', () {
      var now = DateTime(2026, 9, 27, 12);
      final hb = PhaseHeartbeat(clock: () => now);
      hb.markEmitted();
      now = now.add(const Duration(hours: 1));

      expect(hb.shouldBeat(const Applying()), isTrue);
      expect(hb.shouldBeat(const Downloading(bytesDone: 0)), isTrue);
      expect(hb.shouldBeat(const Preparing()), isFalse);
      expect(hb.shouldBeat(const Verifying()), isFalse);
      expect(hb.shouldBeat(const Queued(position: 0)), isFalse);
      expect(hb.shouldBeat(const Authenticating()), isFalse);
      expect(hb.shouldBeat(const Cancelling()), isFalse);
      expect(hb.shouldBeat(const Done(result: OperationResult())), isFalse);
      expect(hb.shouldBeat(const Cancelled()), isFalse);
    });

    test('no emission recorded yet never beats', () {
      var now = DateTime(2026, 9, 27, 12);
      final hb = PhaseHeartbeat(clock: () => now);
      now = now.add(const Duration(hours: 1));
      // Entering the phase is itself an emission; without markEmitted
      // the helper refuses to fire — backends must record entry.
      expect(hb.shouldBeat(const Downloading(bytesDone: 0)), isFalse);
    });

    test('custom interval is honored', () {
      var now = DateTime(2026, 9, 27, 12);
      final hb = PhaseHeartbeat(
        interval: const Duration(seconds: 10),
        clock: () => now,
      );
      hb.markEmitted();
      now = now.add(const Duration(seconds: 10));
      expect(hb.shouldBeat(const Applying()), isTrue);
    });
  });
}
