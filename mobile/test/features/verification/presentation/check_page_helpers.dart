// TEST ONLY: shared by the result page tests (T4, T5). Opens "Check a
// consignment" in the whole app, scans the known code and lets the fake
// server answer; and cuts a full (officer's) step down to what each viewer
// is sent, following api.md's "What each viewer sees" column by column.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/text/app_text.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';

import '../../../fakes/app_harness.dart';
import '../../../fakes/fake_admin_server.dart' show json200;
import '../../../fakes/fake_check_server.dart';
import '../../../fakes/fake_controllers.dart';
import '../../../fakes/fake_registration.dart' show FakeQrScanner;

/// Set in each test file's setUp.
late FakeCheckServer server;
late FakeQrScanner camera;

/// Signs in as [role], opens the check, scans the known code and lets the
/// fake server answer with [answer].
Future<AppHarness> showAnswer(
  WidgetTester tester,
  Map<String, Object?> answer, {
  Role role = Role.buyer,
  Size size = const Size(360, 640),
  double textScale = 1.0,
}) async {
  server.answer = (_) => json200(answer);
  final app = await AppHarness.pump(
    tester,
    FakeAuthController(signedInAs(role)),
    size: size,
    textScale: textScale,
    overrides: [
      ...server.overrides(),
      qrScannerBuilderProvider.overrideWithValue(camera.builder),
    ],
  );
  await tapVisible(tester, find.text(AppText.checkConsignment));
  camera.scan(knownQrCode);
  await tester.pumpAndSettle();
  return app;
}

/// The five columns of api.md's "What each viewer sees".
enum Viewer {
  officer(Role.officer),
  owningBuyer(Role.buyer),
  otherBuyer(Role.buyer),
  transporterHandedOff(Role.transporter),
  blindTransporter(Role.transporter);

  const Viewer(this.role);
  final Role role;

  bool get isTransporter => role == Role.transporter;
}

/// A full step (an officer's, with the evidence block the app ignores),
/// cut down to what [viewer] is sent. A field a role may not see is left
/// out, not sent as null.
Map<String, Object?> stepFor(Viewer viewer, Map<String, Object?> full) {
  final step = {
    ...full,
    'actor': {...full['actor']! as Map},
    'anchor': {...full['anchor']! as Map},
    'check': {...full['check']! as Map},
    'evidence': {
      'signedPayload': 'minechain-step/1/registration\nstep_id=FAKE\n',
      'signature': 'MEQCIF-FAKE==',
      'signerPublicKey': 'MFkwEw-FAKE==',
    },
  };
  if (viewer != Viewer.officer) {
    step
      ..remove('reviewStatus')
      ..remove('alerts');
    (step['check']! as Map)
      ..remove('fields')
      ..remove('reason');
  }
  if (viewer != Viewer.officer && viewer != Viewer.owningBuyer) {
    step
      ..remove('location')
      ..remove('evidence');
  }
  if (viewer.isTransporter) (step['actor']! as Map).remove('username');
  if (viewer == Viewer.blindTransporter) {
    step.remove('weightMg');
    (step['anchor']! as Map).remove('chainTxHash');
  }
  return step;
}

/// A whole answer for [viewer]: [steps] cut down, and `weightsHidden` only
/// for the blind transporter.
Map<String, Object?> answerFor(
  Viewer viewer,
  List<Map<String, Object?>> steps, {
  String stage = 'in_transit',
  bool held = false,
}) => consignmentAnswerJson(
  stage: stage,
  held: held,
  weightsHidden: viewer == Viewer.blindTransporter,
  steps: [for (final s in steps) stepFor(viewer, s)],
);
