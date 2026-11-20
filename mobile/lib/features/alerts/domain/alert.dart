// An anomaly alert, as the officer's alerts screens show it (officer alerts
// plan, T1), read from the API's "alert view" (docs/api.md, "Alerts
// (FR-08)"):
//
//   id, type, severity, status, details, createdAt,
//   step        { id, type, reviewStatus, anchorStatus, capturedAt, receivedAt }
//   consignment { id, qrCode, mineral, stage, held }
//   actor       { id, username, role }
//   review      null while open; { by: { id, username }, notes, at } once closed
//   otherAlerts (GET /alerts/{id} only) [{ id, type, severity, status, stepId,
//                                          createdAt }]
//
// Read strictly, like AccountRequest and ConsignmentView: a missing field, a
// wrong type or a status this app does not know makes the alert unreadable
// (null here). Two things are deliberately NOT strict:
//
//   - an unknown `type` becomes AlertType.unknown. The server may add a check
//     later; the officer can still read the rest and decide, and the screen
//     says it cannot show that alert's details.
//   - `details` is kept as the server sent it. Its shape depends on the type,
//     and the words for it (alert_words.dart) fall back to one plain sentence
//     when something in it is odd, so an unexpected detail never hides an
//     alert that needs a decision.
//
// Weights inside `details` stay text (whole milligrams), as everywhere else.
//
// Plain Dart, no Flutter.

import '../../auth/domain/user.dart' show Role;
import '../../registration/domain/mineral.dart';
import '../../verification/domain/consignment_view.dart'
    show AnchorStatus, ConsignmentStage, ReviewStatus, StepType;

/// The six alert types (api.md), and [unknown] for one this app does not
/// know yet.
enum AlertType {
  duplicateConsignment('duplicate_consignment'),
  quantityDiscrepancy('quantity_discrepancy'),
  gpsZone('gps_zone'),
  invalidSignature('invalid_signature'),
  handoffOrder('handoff_order'),
  recordTampered('record_tampered'),
  unknown('');

  const AlertType(this.apiName);

  /// The API's spelling; empty for [unknown].
  final String apiName;

  /// The type named [name], or [unknown]. Never null: see the file header.
  static AlertType fromApiName(String name) {
    for (final type in values) {
      if (type != unknown && type.apiName == name) return type;
    }
    return unknown;
  }
}

enum AlertSeverity { low, medium, high }

/// `open`, then closed as `reviewed` ("Confirm problem") or `dismissed`
/// ("Clear, no problem"). The names are the API's spelling, and also the
/// list's `status` query.
enum AlertStatus { open, reviewed, dismissed }

/// The step the alert is on.
class AlertStep {
  const AlertStep({
    required this.id,
    required this.type,
    required this.reviewStatus,
    required this.anchorStatus,
    required this.capturedAt,
    required this.receivedAt,
  });

  final String id;
  final StepType type;
  final ReviewStatus reviewStatus;
  final AnchorStatus anchorStatus;

  /// The phone's signed time, in UTC.
  final DateTime capturedAt;

  /// When the server stored the step, in UTC.
  final DateTime receivedAt;

  static AlertStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (!_text(id)) return null;
    final type = _named(StepType.values, json['type']);
    final review = _named(ReviewStatus.values, json['reviewStatus']);
    final anchor = _named(AnchorStatus.values, json['anchorStatus']);
    final captured = _time(json['capturedAt']);
    final received = _time(json['receivedAt']);
    if (type == null || review == null || anchor == null) return null;
    if (captured == null || received == null) return null;
    return AlertStep(
      id: id as String,
      type: type,
      reviewStatus: review,
      anchorStatus: anchor,
      capturedAt: captured,
      receivedAt: received,
    );
  }
}

/// The consignment the alert's step belongs to.
class AlertConsignment {
  const AlertConsignment({
    required this.id,
    required this.qrCode,
    required this.mineral,
    required this.stage,
    required this.held,
  });

  final String id;
  final String qrCode;
  final Mineral mineral;
  final ConsignmentStage stage;

  /// True while any alert on the consignment is open.
  final bool held;

  static AlertConsignment? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final qrCode = json['qrCode'];
    final mineralName = json['mineral'];
    final held = json['held'];
    if (!_text(id) || !_text(qrCode) || mineralName is! String) return null;
    if (held is! bool) return null;
    final mineral = Mineral.fromApiName(mineralName);
    final stage = _stage(json['stage']);
    if (mineral == null || stage == null) return null;
    return AlertConsignment(
      id: id as String,
      qrCode: qrCode as String,
      mineral: mineral,
      stage: stage,
      held: held,
    );
  }
}

/// Who recorded the step: a username and a role, never a full name.
class AlertActor {
  const AlertActor({
    required this.id,
    required this.username,
    required this.role,
  });

  final String id;
  final String username;
  final Role role;

  static AlertActor? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final username = json['username'];
    if (!_text(id) || !_text(username)) return null;
    final role = _named(Role.values, json['role']);
    if (role == null) return null;
    return AlertActor(
      id: id as String,
      username: username as String,
      role: role,
    );
  }
}

/// The officer's decision on a closed alert.
class AlertReview {
  const AlertReview({
    required this.byId,
    required this.byUsername,
    required this.notes,
    required this.at,
  });

  final String byId;
  final String byUsername;
  final String notes;

  /// When the decision was saved, in UTC.
  final DateTime at;

  static AlertReview? fromJson(Object? json) {
    if (json is! Map) return null;
    final by = json['by'];
    final notes = json['notes'];
    final at = _time(json['at']);
    if (by is! Map || !_text(notes) || at == null) return null;
    final byId = by['id'];
    final byUsername = by['username'];
    if (!_text(byId) || !_text(byUsername)) return null;
    return AlertReview(
      byId: byId as String,
      byUsername: byUsername as String,
      notes: notes as String,
      at: at,
    );
  }
}

/// Another alert on the same consignment, in an alert's detail.
class OtherAlert {
  const OtherAlert({
    required this.id,
    required this.type,
    required this.severity,
    required this.status,
    required this.stepId,
    required this.createdAt,
  });

  final String id;
  final AlertType type;
  final AlertSeverity severity;
  final AlertStatus status;
  final String stepId;
  final DateTime createdAt;

  static OtherAlert? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final typeName = json['type'];
    final stepId = json['stepId'];
    if (!_text(id) || typeName is! String || !_text(stepId)) return null;
    final severity = _named(AlertSeverity.values, json['severity']);
    final status = _named(AlertStatus.values, json['status']);
    final createdAt = _time(json['createdAt']);
    if (severity == null || status == null || createdAt == null) return null;
    return OtherAlert(
      id: id as String,
      type: AlertType.fromApiName(typeName),
      severity: severity,
      status: status,
      stepId: stepId as String,
      createdAt: createdAt,
    );
  }
}

/// One alert.
class Alert {
  const Alert({
    required this.id,
    required this.type,
    required this.severity,
    required this.status,
    required this.details,
    required this.createdAt,
    required this.step,
    required this.consignment,
    required this.actor,
    required this.review,
    this.otherAlerts,
  });

  final String id;
  final AlertType type;
  final AlertSeverity severity;
  final AlertStatus status;

  /// As stored by the check that raised it; read by alert_words.dart.
  final Map<String, Object?> details;

  /// When the alert was raised, in UTC.
  final DateTime createdAt;

  final AlertStep step;
  final AlertConsignment consignment;
  final AlertActor actor;

  /// Null exactly while the alert is open.
  final AlertReview? review;

  /// The other alerts on this consignment, oldest first. Only GET
  /// /alerts/{id} sends them; null in the list.
  final List<OtherAlert>? otherAlerts;

  bool get isOpen => status == AlertStatus.open;

  /// Reads one alert view, or null. Extra fields are ignored, so the server
  /// may add some without breaking the list.
  static Alert? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final typeName = json['type'];
    final details = json['details'];
    if (!_text(id) || typeName is! String || details is! Map) return null;

    final severity = _named(AlertSeverity.values, json['severity']);
    final status = _named(AlertStatus.values, json['status']);
    final createdAt = _time(json['createdAt']);
    final step = AlertStep.fromJson(json['step']);
    final consignment = AlertConsignment.fromJson(json['consignment']);
    final actor = AlertActor.fromJson(json['actor']);
    if (severity == null || status == null || createdAt == null) return null;
    if (step == null || consignment == null || actor == null) return null;

    // The review must match the status, as the database requires
    // (alerts_review_fields_match_status): an "open" alert with a decision,
    // or a closed one without, is not something to show or act on.
    if (!json.containsKey('review')) return null;
    final rawReview = json['review'];
    AlertReview? review;
    if (status == AlertStatus.open) {
      if (rawReview != null) return null;
    } else {
      review = AlertReview.fromJson(rawReview);
      if (review == null) return null;
    }

    List<OtherAlert>? others;
    if (json.containsKey('otherAlerts')) {
      final raw = json['otherAlerts'];
      if (raw is! List) return null;
      final list = <OtherAlert>[];
      for (final item in raw) {
        final other = OtherAlert.fromJson(item);
        if (other == null) return null;
        list.add(other);
      }
      others = List.unmodifiable(list);
    }

    return Alert(
      id: id as String,
      type: AlertType.fromApiName(typeName),
      severity: severity,
      status: status,
      details: Map.unmodifiable(details.cast<String, Object?>()),
      createdAt: createdAt,
      step: step,
      consignment: consignment,
      actor: actor,
      review: review,
      otherAlerts: others,
    );
  }

  // Codes only: a QR code, username or notes in a log would be work details.
  @override
  String toString() =>
      'Alert(type: ${type.apiName}, severity: ${severity.name}, '
      'status: ${status.name})';
}

/// One page of alerts with one status.
class AlertsPage {
  const AlertsPage({required this.alerts, required this.total});

  final List<Alert> alerts;

  /// Every alert with this status on the server, not only this page.
  final int total;

  @override
  String toString() => 'AlertsPage(alerts: ${alerts.length}, total: $total)';
}

/// What a decision's 200 answer says about the step and the consignment
/// now (api.md, POST /alerts/{id}/review and /dismiss).
///
/// Every field may be null: a 200 means the decision is saved, and an odd
/// echo must not turn that into a failure (the officer would try again and
/// get 409). The message is then simply shorter.
class AlertDecisionResult {
  const AlertDecisionResult({
    required this.stepStatus,
    required this.stage,
    required this.held,
  });

  final ReviewStatus? stepStatus;
  final ConsignmentStage? stage;
  final bool? held;

  static AlertDecisionResult fromJson(Object? json) {
    final step = json is Map ? json['step'] : null;
    final consignment = json is Map ? json['consignment'] : null;
    final held = consignment is Map ? consignment['held'] : null;
    return AlertDecisionResult(
      stepStatus: step is Map
          ? _named(ReviewStatus.values, step['reviewStatus'])
          : null,
      stage: consignment is Map ? _stage(consignment['stage']) : null,
      held: held is bool ? held : null,
    );
  }

  @override
  String toString() =>
      'AlertDecisionResult(step: ${stepStatus?.name}, '
      'stage: ${stage?.apiName}, held: $held)';
}

// ---- Reading helpers ---------------------------------------------------------

bool _text(Object? value) => value is String && value.isNotEmpty;

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// The value of [values] whose `name` is [raw] exactly, or null.
T? _named<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}

ConsignmentStage? _stage(Object? raw) {
  if (raw is! String) return null;
  for (final stage in ConsignmentStage.values) {
    if (stage.apiName == raw) return stage;
  }
  return null;
}
