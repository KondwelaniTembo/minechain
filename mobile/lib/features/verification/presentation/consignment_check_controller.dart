// The state behind "Check a consignment" (consignment check plan, T3): scan a
// custody record, ask the server, show the answer.
//
// A plain Notifier with its own sealed states, like AccountRequestsController:
// the screen needs "scanning", "checking", "enter your password", "failed"
// and "done", and spelling them out lets the compiler and the tests see each.
//
// One request per scan. The camera keeps reading the same code many times a
// second while it is in view, so every code that arrives while a check runs,
// or after one has finished, is ignored until the user taps "Scan again".
//
// Nothing about the consignment is logged; the states' toString() print no
// QR code.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../registration/domain/custody_record.dart';
import '../data/consignment_check_repository.dart';
import '../domain/consignment_view.dart';

sealed class CheckState {
  const CheckState();
}

/// The camera is on. [notOurs] is true after a QR code that is not a
/// MineChain custody record; the camera keeps scanning.
final class CheckScanning extends CheckState {
  const CheckScanning({this.notOurs = false});
  final bool notOurs;

  @override
  String toString() => 'CheckScanning(notOurs: $notOurs)';
}

/// The server is checking [qrCode].
final class CheckRunning extends CheckState {
  const CheckRunning(this.qrCode);
  final String qrCode;

  @override
  String toString() => 'CheckRunning()';
}

/// The token has expired: the password is needed before [qrCode] is
/// checked. Nothing was sent.
final class CheckNeedsPassword extends CheckState {
  const CheckNeedsPassword(this.qrCode);
  final String qrCode;

  @override
  String toString() => 'CheckNeedsPassword()';
}

/// The check of [qrCode] failed or was refused.
final class CheckFailed extends CheckState {
  const CheckFailed(this.qrCode, this.failure);
  final String qrCode;
  final AppFailure failure;

  @override
  String toString() => 'CheckFailed($failure)';
}

/// The server's answer.
final class CheckDone extends CheckState {
  const CheckDone(this.view);
  final ConsignmentView view;

  @override
  String toString() => 'CheckDone($view)';
}

class ConsignmentCheckController extends Notifier<CheckState> {
  @override
  CheckState build() => const CheckScanning();

  /// A code from the camera, exactly as read.
  Future<void> onScanned(String raw) async {
    if (state is! CheckScanning) return;
    // The custody record ID format, not the server's wide QR grammar: a
    // website link or another tag never reaches the server (and never uses
    // up one of the 60 scans allowed per 15 minutes).
    if (!isCustodyRecordId(raw)) {
      state = const CheckScanning(notOurs: true);
      return;
    }
    await _check(raw);
  }

  /// "Try again" after a failure, or after the password was entered.
  Future<void> retry() async {
    final code = switch (state) {
      CheckFailed(:final qrCode) || CheckNeedsPassword(:final qrCode) => qrCode,
      _ => null,
    };
    if (code != null) await _check(code);
  }

  /// "Scan again": back to the camera.
  void scanAgain() {
    if (state is CheckRunning) return;
    state = const CheckScanning();
  }

  Future<void> _check(String qrCode) async {
    final token = _token();
    if (token == null) {
      state = CheckNeedsPassword(qrCode);
      return;
    }
    state = CheckRunning(qrCode);
    try {
      final view = await ref
          .read(consignmentCheckRepositoryProvider)
          .check(token: token, qrCode: qrCode);
      if (!ref.mounted) return;
      state = CheckDone(view);
    } on AppFailure catch (failure) {
      if (!ref.mounted) return;
      // A TOKEN_EXPIRED on this very request has already moved the session
      // to "needs password" (ApiClient's session events).
      state = _token() == null
          ? CheckNeedsPassword(qrCode)
          : CheckFailed(qrCode, failure);
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets the answer, so opening it again
/// always starts with the camera and a fresh check.
final consignmentCheckControllerProvider =
    NotifierProvider.autoDispose<ConsignmentCheckController, CheckState>(
      ConsignmentCheckController.new,
    );
