// The state behind "Take custody" (transporter handoff plan, T3): scan the
// bag's custody record, refuse a second handoff of it by this account on
// this phone (Q4), ask the server what it knows (Q1, Q2), and settle the
// mineral, from the server or from the transporter's choice.
//
// T4 adds the weight, the GPS fix and Save on top of [CustodyReady].
//
// One request per scan, as on "Check a consignment": the camera reads the
// same code many times a second, so any code that arrives after one is
// accepted is ignored until "Scan another record".
//
// Never a dead end (Q2): offline, a slow answer, a server error or an ended
// session all lead to "could not be checked, you can still record it".
//
// Nothing here is logged; the states' toString() print no QR code.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../registration/domain/custody_record.dart';
import '../../registration/domain/mineral.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../verification/data/consignment_check_repository.dart';
import '../domain/custody_check.dart';

sealed class CustodyState {
  const CustodyState();
}

/// Why the camera is still on after a code was read.
sealed class ScanNotice {
  const ScanNotice();
}

/// Not a MineChain custody record.
final class ScanNotOurs extends ScanNotice {
  const ScanNotOurs();
}

/// This account already recorded taking custody of it on this phone, first
/// on [on] (UTC). Q4.
final class ScanAlreadyTaken extends ScanNotice {
  const ScanAlreadyTaken(this.on);
  final DateTime on;
}

/// The phone's database was busy for a moment; scanning again works.
final class ScanPhoneBusy extends ScanNotice {
  const ScanPhoneBusy();
}

/// The camera is on.
final class CustodyScanning extends CustodyState {
  const CustodyScanning([this.notice]);
  final ScanNotice? notice;

  @override
  String toString() => 'CustodyScanning(${notice.runtimeType})';
}

/// A code is accepted; the phone and the server are being asked about it.
final class CustodyChecking extends CustodyState {
  const CustodyChecking(this.qrCode);
  final String qrCode;

  @override
  String toString() => 'CustodyChecking()';
}

/// What is known about the bag; the transporter can go on.
final class CustodyReady extends CustodyState {
  const CustodyReady({
    required this.qrCode,
    required this.check,
    this.chosenMineral,
    this.recordAnyway = false,
  });

  final String qrCode;
  final CustodyCheck check;

  /// The transporter's choice from the chips, when the server did not say.
  final Mineral? chosenMineral;

  /// "Record anyway" was tapped (Q2).
  final bool recordAnyway;

  /// The server's mineral wins: it was signed by the miner, and the chips
  /// are not shown then.
  Mineral? get mineral => check.knownMineral ?? chosenMineral;

  /// Whether the transporter must choose the mineral (Q1).
  bool get choosesMineral => check.knownMineral == null;

  List<CustodyWarning> get warnings => custodyWarnings(check);

  /// A held or mismatching consignment, not yet confirmed (Q2).
  bool get waitingForRecordAnyway =>
      !recordAnyway && warnings.any(needsRecordAnyway);

  /// Everything T4's weight and Save need from this part.
  bool get mayContinue => mineral != null && !waitingForRecordAnyway;

  CustodyReady copyWith({Mineral? chosenMineral, bool? recordAnyway}) =>
      CustodyReady(
        qrCode: qrCode,
        check: check,
        chosenMineral: chosenMineral ?? this.chosenMineral,
        recordAnyway: recordAnyway ?? this.recordAnyway,
      );

  @override
  String toString() => 'CustodyReady($check, mayContinue: $mayContinue)';
}

class CustodyController extends Notifier<CustodyState> {
  @override
  CustodyState build() => const CustodyScanning();

  /// A code from the camera, exactly as read.
  Future<void> onScanned(String raw) async {
    if (state is! CustodyScanning) return;
    // The custody record ID format, so a website link never reaches the
    // database or the server.
    if (!isCustodyRecordId(raw)) {
      state = const CustodyScanning(ScanNotOurs());
      return;
    }
    final user = _user();
    if (user == null) return;
    // From here on, further reads of the code are ignored.
    state = CustodyChecking(raw);

    // Q4 first, on the phone: a refused scan costs no network request.
    final DateTime? earlier;
    try {
      final steps = await ref.read(localStepsRepositoryProvider.future);
      earlier = await steps.handedOffOn(raw, user);
    } on Object {
      // Busy, or a database problem the screen's gate shows by itself.
      if (ref.mounted) state = const CustodyScanning(ScanPhoneBusy());
      return;
    }
    if (!ref.mounted) return;
    if (earlier != null) {
      state = CustodyScanning(ScanAlreadyTaken(earlier));
      return;
    }

    final check = await _askServer(raw);
    if (!ref.mounted || state is! CustodyChecking) return;
    state = CustodyReady(qrCode: raw, check: check);
  }

  Future<CustodyCheck> _askServer(String qrCode) async {
    final token = _token();
    if (token == null) {
      return const CustodyUnchecked(UncheckedReason.needsPassword);
    }
    try {
      final view = await ref
          .read(consignmentCheckRepositoryProvider)
          .check(token: token, qrCode: qrCode);
      return CustodyChecked(view);
    } on AppFailure catch (failure) {
      return switch (failure) {
        ServerRefused(status: 404, code: ApiCodes.consignmentNotFound) =>
          const CustodyNotOnServer(),
        NoConnection() => const CustodyUnchecked(UncheckedReason.offline),
        // A TOKEN_EXPIRED on this very request has already moved the
        // session to "needs password".
        _ when _token() == null => const CustodyUnchecked(
          UncheckedReason.needsPassword,
        ),
        _ => const CustodyUnchecked(UncheckedReason.failed),
      };
    }
  }

  /// A mineral chip, when the server did not say (Q1).
  void chooseMineral(Mineral mineral) {
    final current = state;
    if (current is! CustodyReady || !current.choosesMineral) return;
    state = current.copyWith(chosenMineral: mineral);
  }

  /// "Record anyway" under a mismatch or a hold (Q2).
  void recordAnyway() {
    final current = state;
    if (current is! CustodyReady) return;
    state = current.copyWith(recordAnyway: true);
  }

  /// "Scan another record": back to the camera. Not while asking.
  void scanAgain() {
    if (state is CustodyChecking) return;
    state = const CustodyScanning();
  }

  /// The signed-in account's id: the custodian whose handoffs count for Q4.
  String? _user() => switch (ref.read(authControllerProvider)) {
    SignedIn(:final user) || SignedInNeedsPassword(:final user) => user.id,
    _ => null,
  };

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets the scan and the answer.
final custodyControllerProvider =
    NotifierProvider.autoDispose<CustodyController, CustodyState>(
      CustodyController.new,
    );
