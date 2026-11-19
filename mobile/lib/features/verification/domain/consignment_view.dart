// What GET /consignments/by-qr/{qrCode} answers (docs/api.md), as Dart values:
// one consignment, its custody steps in order, and the server's live chain
// check of each step (Scope (9), Verification (1)-(14)).
//
// The answer is cut down per role on the server: "A field a role may not see
// is left out, not sent as null". So this file keeps two cases apart:
//
//   - a key that is ABSENT means "not for you" (a blind transporter's
//     weights, a buyer's coordinates);
//   - a key that is present with null means something real: `zoneName: null`
//     is "outside every licensed zone", `chainTxHash: null` is "nothing sent
//     to the blockchain yet".
//
// Read strictly, like AccountRequest.fromJson: a missing required field, a
// wrong type or a value this app does not know makes the whole answer
// unreadable (null here, BadResponse in the API class). A check result the
// app does not understand must never be shown as "verified".
//
// Weights and coordinates stay text, exactly as the server sent them: they
// come from signed payloads, and the project's rule is that such values are
// never turned into floats.
//
// The `evidence` block (signed payload, signature, public key) is not kept:
// the phone does not re-check signatures itself (plan Q2, option A).
//
// Plain Dart, no Flutter.

import '../../auth/domain/user.dart' show Role;
import '../../registration/domain/mineral.dart';

/// Where the consignment is in its custody chain (api.md `stage`).
enum ConsignmentStage {
  registered('registered'),
  inTransit('in_transit'),
  purchased('purchased');

  const ConsignmentStage(this.apiName);

  /// The API's spelling.
  final String apiName;
}

/// What a step records (api.md `type`).
enum StepType { registration, handoff, purchase }

/// Where the step is in anchoring (api.md `anchor.status`).
enum AnchorStatus { pending, submitted, confirmed, failed }

/// The server's chain check of one step (api.md "The chain check").
enum CheckResult {
  match('match'),
  mismatch('mismatch'),
  notAnchoredYet('not_anchored_yet'),
  chainUnavailable('chain_unavailable');

  const CheckResult(this.apiName);

  final String apiName;
}

/// Whether a step passed the anomaly rules (api.md `reviewStatus`, officers
/// only).
enum ReviewStatus { passed, cleared, flagged, rejected }

/// The whole answer.
class ConsignmentView {
  const ConsignmentView({
    required this.id,
    required this.qrCode,
    required this.mineral,
    required this.stage,
    required this.held,
    required this.weightsHidden,
    required this.steps,
  });

  final String id;
  final String qrCode;
  final Mineral mineral;
  final ConsignmentStage stage;

  /// "Under review": an open alert holds the consignment from anchoring.
  final bool held;

  /// The viewer may not see weights yet (a transporter before their own
  /// handoff), so the app can say "weigh it first".
  final bool weightsHidden;

  /// In custody order, as the server sent them.
  final List<CheckedStep> steps;

  /// Reads the 200 body, or null if anything is missing, of the wrong type or
  /// unknown. Extra fields are ignored, so the server may add some.
  static ConsignmentView? fromJson(Object? json) {
    if (json is! Map) return null;
    final consignment = json['consignment'];
    final rawSteps = json['steps'];
    if (consignment is! Map || rawSteps is! List) return null;

    final id = consignment['id'];
    final qrCode = consignment['qrCode'];
    final mineralName = consignment['mineral'];
    final stageName = consignment['stage'];
    final held = consignment['held'];
    final weightsHidden = consignment['weightsHidden'];
    if (!_text(id) || !_text(qrCode) || !_text(mineralName)) return null;
    if (stageName is! String || held is! bool || weightsHidden is! bool) {
      return null;
    }

    final mineral = Mineral.fromApiName(mineralName as String);
    final stage = _byApiName(
      ConsignmentStage.values,
      stageName,
      (s) => s.apiName,
    );
    if (mineral == null || stage == null) return null;

    final steps = <CheckedStep>[];
    for (final raw in rawSteps) {
      final step = CheckedStep.fromJson(raw);
      // One unreadable step makes the answer unreadable rather than being
      // skipped: a step missing from a custody history would change what it
      // says, and the verdict could become "verified" without it.
      if (step == null) return null;
      steps.add(step);
    }

    return ConsignmentView(
      id: id as String,
      qrCode: qrCode as String,
      mineral: mineral,
      stage: stage,
      held: held,
      weightsHidden: weightsHidden,
      steps: List.unmodifiable(steps),
    );
  }

  // Codes and counts only: a QR code, username or weight in a log would be
  // work details.
  @override
  String toString() =>
      'ConsignmentView(stage: ${stage.apiName}, held: $held, '
      'steps: ${steps.length})';
}

/// Who did a step: always the role; the username only where the role may
/// see it (not for a transporter).
class StepActor {
  const StepActor({required this.role, required this.username});

  final Role role;
  final String? username;
}

/// A step's GPS point, as text with 6 decimal places.
class StepLocation {
  const StepLocation({required this.latitude, required this.longitude});

  final String latitude;
  final String longitude;
}

/// One of a step's alerts (officers only). Full details are in
/// GET /alerts/{id}, which the officer's alerts module reads.
class StepAlert {
  const StepAlert({required this.id, required this.type, required this.status});

  final String id;
  final String type;
  final String status;
}

/// One custody step and its chain check.
class CheckedStep {
  const CheckedStep({
    required this.id,
    required this.type,
    required this.byYou,
    required this.actor,
    required this.weightMg,
    required this.location,
    required this.zoneName,
    required this.capturedAt,
    required this.receivedAt,
    required this.anchorStatus,
    required this.chainTxHashShown,
    required this.chainTxHash,
    required this.check,
    required this.mismatchFields,
    required this.mismatchReason,
    required this.reviewStatus,
    required this.alerts,
  });

  final String id;
  final StepType type;

  /// The viewer's own step.
  final bool byYou;
  final StepActor actor;

  /// Whole milligrams as text; null when the viewer may not see weights.
  final String? weightMg;

  /// Null when the viewer may not see coordinates.
  final StepLocation? location;

  /// The licensed zone the point fell in, or null for "outside every active
  /// zone". Every role sees this field.
  final String? zoneName;

  /// The phone's signed capture time, in UTC.
  final DateTime capturedAt;

  /// When the server stored the step, in UTC.
  final DateTime receivedAt;

  final AnchorStatus anchorStatus;

  /// False when the viewer may not see the transaction hash (a blind
  /// transporter: the hash leads to the on-chain weight).
  final bool chainTxHashShown;

  /// The Sepolia transaction hash, or null while nothing has been sent.
  /// Always null when [chainTxHashShown] is false.
  final String? chainTxHash;

  final CheckResult check;

  /// Officers only, on a mismatch: the NAMES of what differs, never values.
  /// Null when the server sent none.
  final List<String>? mismatchFields;

  /// Officers only, sometimes, on a mismatch (for example `TX_NOT_FOUND`).
  final String? mismatchReason;

  /// Officers only; null for everyone else.
  final ReviewStatus? reviewStatus;

  /// Officers only; null for everyone else.
  final List<StepAlert>? alerts;

  static final RegExp _milligrams = RegExp(r'^[0-9]+$');
  static final RegExp _degrees = RegExp(r'^-?[0-9]{1,3}\.[0-9]{6}$');
  static final RegExp _txHash = RegExp(r'^0x[0-9a-fA-F]{64}$');

  /// Reads one step, or null.
  static CheckedStep? fromJson(Object? json) {
    if (json is! Map) return null;

    final id = json['id'];
    final typeName = json['type'];
    final byYou = json['byYou'];
    if (!_text(id) || typeName is! String || byYou is! bool) return null;
    final type = _byApiName(StepType.values, typeName, (t) => t.name);
    if (type == null) return null;

    final actor = _actorFrom(json['actor']);
    if (actor == null) return null;

    // Optional by role: absent is fine, but if present it must be right.
    String? weightMg;
    if (json.containsKey('weightMg')) {
      final raw = json['weightMg'];
      if (raw is! String || !_milligrams.hasMatch(raw)) return null;
      weightMg = raw;
    }

    StepLocation? location;
    if (json.containsKey('location')) {
      location = _locationFrom(json['location']);
      if (location == null) return null;
    }

    // Every role sees zoneName, so the key must be there; null is a real
    // answer ("outside every zone").
    if (!json.containsKey('zoneName')) return null;
    final zoneName = json['zoneName'];
    if (zoneName != null && !_text(zoneName)) return null;

    final capturedAt = _time(json['capturedAt']);
    final receivedAt = _time(json['receivedAt']);
    if (capturedAt == null || receivedAt == null) return null;

    final anchor = json['anchor'];
    if (anchor is! Map) return null;
    final anchorName = anchor['status'];
    if (anchorName is! String) return null;
    final anchorStatus = _byApiName(
      AnchorStatus.values,
      anchorName,
      (a) => a.name,
    );
    if (anchorStatus == null) return null;
    final hashShown = anchor.containsKey('chainTxHash');
    final hash = anchor['chainTxHash'];
    if (hash != null && (hash is! String || !_txHash.hasMatch(hash))) {
      return null;
    }

    final check = json['check'];
    if (check is! Map) return null;
    final resultName = check['result'];
    if (resultName is! String) return null;
    final result = _byApiName(CheckResult.values, resultName, (r) => r.apiName);
    if (result == null) return null;

    List<String>? fields;
    if (check.containsKey('fields')) {
      final raw = check['fields'];
      if (raw is! List || !raw.every(_text)) return null;
      fields = List.unmodifiable(raw.cast<String>());
    }
    String? reason;
    if (check.containsKey('reason')) {
      final raw = check['reason'];
      if (!_text(raw)) return null;
      reason = raw as String;
    }

    ReviewStatus? review;
    if (json.containsKey('reviewStatus')) {
      final raw = json['reviewStatus'];
      if (raw is! String) return null;
      review = _byApiName(ReviewStatus.values, raw, (r) => r.name);
      if (review == null) return null;
    }

    List<StepAlert>? alerts;
    if (json.containsKey('alerts')) {
      final raw = json['alerts'];
      if (raw is! List) return null;
      final list = <StepAlert>[];
      for (final item in raw) {
        if (item is! Map) return null;
        final alertId = item['id'];
        final alertType = item['type'];
        final alertStatus = item['status'];
        if (!_text(alertId) || !_text(alertType) || !_text(alertStatus)) {
          return null;
        }
        list.add(
          StepAlert(
            id: alertId as String,
            type: alertType as String,
            status: alertStatus as String,
          ),
        );
      }
      alerts = List.unmodifiable(list);
    }

    return CheckedStep(
      id: id as String,
      type: type,
      byYou: byYou,
      actor: actor,
      weightMg: weightMg,
      location: location,
      zoneName: zoneName as String?,
      capturedAt: capturedAt,
      receivedAt: receivedAt,
      anchorStatus: anchorStatus,
      chainTxHashShown: hashShown,
      chainTxHash: hash as String?,
      check: result,
      mismatchFields: fields,
      mismatchReason: reason,
      reviewStatus: review,
      alerts: alerts,
    );
  }

  static StepActor? _actorFrom(Object? json) {
    if (json is! Map) return null;
    final roleName = json['role'];
    if (roleName is! String) return null;
    final role = _byApiName(Role.values, roleName, (r) => r.name);
    if (role == null) return null;
    String? username;
    if (json.containsKey('username')) {
      final raw = json['username'];
      if (!_text(raw)) return null;
      username = raw as String;
    }
    return StepActor(role: role, username: username);
  }

  static StepLocation? _locationFrom(Object? json) {
    if (json is! Map) return null;
    final lat = json['latitude'];
    final lng = json['longitude'];
    if (lat is! String || lng is! String) return null;
    if (!_degrees.hasMatch(lat) || !_degrees.hasMatch(lng)) return null;
    return StepLocation(latitude: lat, longitude: lng);
  }

  @override
  String toString() =>
      'CheckedStep(type: ${type.name}, check: ${check.apiName})';
}

bool _text(Object? value) => value is String && value.isNotEmpty;

DateTime? _time(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

T? _byApiName<T>(List<T> values, String name, String Function(T) apiName) {
  for (final value in values) {
    if (apiName(value) == name) return value;
  }
  return null;
}
