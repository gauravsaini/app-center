/// [OperationEngine] — host-side operation orchestration.
library;

import 'identity.dart';
import 'operation.dart';

abstract class OperationEngine {
  /// Enqueue install/remove/update. One active operation per [AppIdentity]:
  /// a second enqueue for the same app returns the EXISTING handle
  /// (no duplicate downloads, no double polkit prompts).
  Future<OperationHandle> enqueue(OperationKind kind, AppIdentity app);

  /// All non-terminal handles, for the Manage page.
  Stream<List<OperationHandle>> activeOperations();

  /// Coalesce auth: batch N queued ops into one privilege prompt where
  /// the vehicle allows. Never prompt twice for one user gesture.
  Future<void> authenticateBatch(List<OperationHandle> ops);
}
