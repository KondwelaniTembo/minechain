// A custody step as this phone keeps it (plan §2, table local_steps).
//
// The signed payload is the truth. The other signed fields here (QR code,
// weight, coordinates, time) are copies made from the same values when the
// step was captured, for lists and checks; they are never used to rebuild
// the payload (signing spec, section 4).
//
// Plain Dart with plain fields only, so these can travel to and from the
// database's background isolate.

/// Where a step is in being sent (plan §2, sync_state).
enum SyncState { queued, deferred, synced, flagged, rejected }

/// The fixed-width UTC form every time is stored in, for example
/// `2026-11-17T09:00:00.000Z`. Same width for every time, so comparing the
/// text in SQL (`next_attempt_at <= ?`) compares the times.
String storedTime(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}.${utc.millisecond.toString().padLeft(3, '0')}Z';
}

/// A step just captured and signed, before it is saved.
class NewLocalStep {
  const NewLocalStep({
    required this.stepId,
    required this.actorId,
    required this.type,
    required this.qrCode,
    required this.mineral,
    required this.weightMg,
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    required this.payload,
    required this.signature,
    required this.keyFingerprint,
    required this.gpsAccuracyM,
    required this.createdAt,
  });

  final String stepId;
  final String actorId;

  /// `registration`, `handoff` or `purchase`.
  final String type;
  final String qrCode;

  /// Registrations only.
  final String? mineral;

  /// Whole milligrams, as the payload's text.
  final String weightMg;
  final String latitude;
  final String longitude;

  /// The payload's `captured_at` text.
  final String capturedAt;

  /// The exact signed string.
  final String payload;

  /// DER, standard base64.
  final String signature;

  /// Which key signed it.
  final String keyFingerprint;

  /// Local only, for display; not signed.
  final double? gpsAccuracyM;
  final DateTime createdAt;

  // No payload, signature, place or weight in logs.
  @override
  String toString() => 'NewLocalStep(type: $type)';
}

/// A saved step, with what the server said about it.
class LocalStep {
  const LocalStep({
    required this.stepId,
    required this.actorId,
    required this.type,
    required this.qrCode,
    required this.mineral,
    required this.weightMg,
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    required this.payload,
    required this.signature,
    required this.keyFingerprint,
    required this.gpsAccuracyM,
    required this.syncState,
    required this.reviewStatus,
    required this.serverTransactionId,
    required this.lastCode,
    required this.lastMessage,
    required this.attempts,
    required this.nextAttemptAt,
    required this.firstDeferredAt,
    required this.syncedAt,
    required this.createdAt,
  });

  final String stepId;
  final String actorId;
  final String type;
  final String qrCode;
  final String? mineral;
  final String weightMg;
  final String latitude;
  final String longitude;
  final String capturedAt;
  final String payload;
  final String signature;
  final String keyFingerprint;
  final double? gpsAccuracyM;
  final SyncState syncState;
  final String? reviewStatus;
  final String? serverTransactionId;
  final String? lastCode;
  final String? lastMessage;
  final int attempts;
  final DateTime? nextAttemptAt;
  final DateTime? firstDeferredAt;
  final DateTime? syncedAt;
  final DateTime createdAt;

  /// Reads one row of local_steps. The schema's CHECKs already guarantee the
  /// shapes, so a value that does not parse means a damaged file: it throws.
  static LocalStep fromRow(Map<String, Object?> row) {
    DateTime? time(String column) {
      final text = row[column] as String?;
      return text == null ? null : DateTime.parse(text);
    }

    return LocalStep(
      stepId: row['step_id']! as String,
      actorId: row['actor_id']! as String,
      type: row['type']! as String,
      qrCode: row['qr_code']! as String,
      mineral: row['mineral'] as String?,
      weightMg: row['weight_mg']! as String,
      latitude: row['latitude']! as String,
      longitude: row['longitude']! as String,
      capturedAt: row['captured_at']! as String,
      payload: row['payload']! as String,
      signature: row['signature']! as String,
      keyFingerprint: row['key_fingerprint']! as String,
      gpsAccuracyM: (row['gps_accuracy_m'] as num?)?.toDouble(),
      syncState: SyncState.values.byName(row['sync_state']! as String),
      reviewStatus: row['review_status'] as String?,
      serverTransactionId: row['server_transaction_id'] as String?,
      lastCode: row['last_code'] as String?,
      lastMessage: row['last_message'] as String?,
      attempts: row['attempts']! as int,
      nextAttemptAt: time('next_attempt_at'),
      firstDeferredAt: time('first_deferred_at'),
      syncedAt: time('synced_at'),
      createdAt: DateTime.parse(row['created_at']! as String),
    );
  }

  @override
  String toString() => 'LocalStep(type: $type, syncState: ${syncState.name})';
}

/// What the server said about one step (api.md, POST /sync/steps, "The five
/// outcomes"), ready to be written down. M6 turns each result into one.
sealed class StepSyncUpdate {
  const StepSyncUpdate(this.stepId);
  final String stepId;
}

/// `created` or `duplicate`: stored on the server.
final class StepSynced extends StepSyncUpdate {
  const StepSynced(
    super.stepId, {
    required this.reviewStatus,
    required this.transactionId,
  });
  final String reviewStatus;
  final String transactionId;
}

/// `flagged`: stored on the server, under review.
final class StepFlagged extends StepSyncUpdate {
  const StepFlagged(
    super.stepId, {
    required this.code,
    required this.message,
    required this.reviewStatus,
    required this.transactionId,
  });
  final String code;
  final String message;
  final String reviewStatus;
  final String transactionId;
}

/// `rejected`: never accepted as it is. Kept on the phone as evidence.
final class StepRejected extends StepSyncUpdate {
  const StepRejected(super.stepId, {required this.code, required this.message});
  final String code;
  final String message;
}

/// `deferred`: not yet; send again at or after [nextAttemptAt].
final class StepDeferred extends StepSyncUpdate {
  const StepDeferred(
    super.stepId, {
    required this.code,
    required this.message,
    required this.nextAttemptAt,
  });
  final String code;
  final String message;
  final DateTime nextAttemptAt;
}
