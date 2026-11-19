// "Check a consignment" (consignment check plan): one screen for the
// transporter, the buyer and the officer, at /transporter/check,
// /buyer/check and /officer/check (Q3).
//
// T3 builds the scan step and every way it can end except the answer
// itself: the result page (verdict and custody steps) comes in T4, and until
// then a finished check only says which record was checked.
//
// The camera is built only while the screen is scanning, so it stops as soon
// as a code is accepted and starts again on "Scan again".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../registration/data/location_source.dart';
import '../../registration/presentation/qr_scanner_view.dart';
import 'consignment_check_controller.dart';

class ConsignmentCheckScreen extends ConsumerWidget {
  const ConsignmentCheckScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(consignmentCheckControllerProvider);
    final controller = ref.read(consignmentCheckControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text(AppText.checkConsignment)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Center(
            child: ConstrainedBox(
              // A readable width on a phone turned on its side.
              constraints: const BoxConstraints(maxWidth: 560),
              child: switch (state) {
                CheckScanning(:final notOurs) => _Scanning(
                  notOurs: notOurs,
                  onCode: controller.onScanned,
                ),
                CheckRunning(:final qrCode) => _Running(qrCode: qrCode),
                CheckNeedsPassword() => _NeedsPassword(
                  onPassword: () async {
                    if (await showPasswordPrompt(context)) {
                      await controller.retry();
                    }
                  },
                  onScanAgain: controller.scanAgain,
                ),
                CheckFailed(:final failure) => _Failed(
                  failure: failure,
                  onRetry: controller.retry,
                  onScanAgain: controller.scanAgain,
                ),
                CheckDone(:final view) => _Done(
                  qrCode: view.qrCode,
                  onScanAgain: controller.scanAgain,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The sentence for a failed check.
///
/// 429 uses the server's own words ("Too many consignment scans…"): the
/// app's shared sentence for TOO_MANY_REQUESTS is about login tries.
/// Everything else follows failureText: 404 CONSIGNMENT_NOT_FOUND has no
/// sentence of the app's own, so the server's "No consignment has this QR
/// code." is shown, the same for an unknown code and one this buyer may not
/// see, as api.md intends.
String checkFailureText(AppFailure failure) {
  if (failure
      case ServerRefused(code: ApiCodes.tooManyRequests, :final serverMessage)
      when serverMessage.trim().isNotEmpty) {
    return serverMessage;
  }
  return failureText(failure);
}

/// Whether "Try again" with the same code can help. A 4xx refusal (not
/// found, not allowed, too many scans, a malformed code) will be the same
/// answer again, so only "Scan again" is offered then.
bool _worthRetrying(AppFailure failure) => switch (failure) {
  ServerRefused(:final status) => status >= 500,
  InsecureConnection() => false,
  NoConnection() || TimedOut() || BadResponse() => true,
};

class _Scanning extends ConsumerWidget {
  const _Scanning({required this.notOurs, required this.onCode});
  final bool notOurs;
  final ValueChanged<String> onCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scanner = ref.watch(qrScannerBuilderProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSizes.tileRadius),
          child: SizedBox(
            height: 260,
            child: scanner(
              onCode: onCode,
              problemBuilder: (context, problem, retry) =>
                  _CameraProblem(problem: problem, retry: retry),
            ),
          ),
        ),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.checkScanHint),
        if (notOurs) ...[
          const SizedBox(height: AppSizes.spaceS),
          const _StatusLine(
            icon: Icons.error_outline,
            error: true,
            text: AppText.notOurRecord,
          ),
        ],
      ],
    );
  }
}

class _Running extends StatelessWidget {
  const _Running({required this.qrCode});
  final String qrCode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A bar, not a spinner: the check may take several seconds (the
        // server asks the blockchain, 8 s at most per request).
        const LinearProgressIndicator(),
        const SizedBox(height: AppSizes.spaceM),
        Text(
          AppText.checkingRecord(qrCode),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSizes.spaceS),
        const Text(AppText.checkingTakesTime),
      ],
    );
  }
}

class _NeedsPassword extends StatelessWidget {
  const _NeedsPassword({required this.onPassword, required this.onScanAgain});
  final VoidCallback onPassword;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StatusLine(
          icon: Icons.lock_clock,
          text: AppText.checkNeedsPassword,
        ),
        const SizedBox(height: AppSizes.spaceM),
        _Buttons(
          main: FilledButton(
            onPressed: onPassword,
            child: const Text(AppText.enterPasswordButton),
          ),
          onScanAgain: onScanAgain,
        ),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({
    required this.failure,
    required this.onRetry,
    required this.onScanAgain,
  });
  final AppFailure failure;
  final VoidCallback onRetry;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    final wait = failure is ServerRefused
        ? (failure as ServerRefused).retryAfter
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(
          icon: Icons.error_outline,
          error: true,
          text: checkFailureText(failure),
        ),
        if (wait != null) ...[
          const SizedBox(height: AppSizes.spaceS),
          Text(AppText.tryAgainIn(wait)),
        ],
        const SizedBox(height: AppSizes.spaceM),
        _Buttons(
          main: _worthRetrying(failure)
              ? FilledButton(
                  onPressed: onRetry,
                  child: const Text(AppText.tryAgain),
                )
              : null,
          onScanAgain: onScanAgain,
        ),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.qrCode, required this.onScanAgain});
  final String qrCode;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusLine(
          icon: Icons.fact_check,
          text: AppText.checkedRecord(qrCode),
        ),
        const SizedBox(height: AppSizes.spaceM),
        _Buttons(main: null, onScanAgain: onScanAgain),
      ],
    );
  }
}

/// The main action (if any), then "Scan again"; they wrap onto two lines
/// when the text is large.
class _Buttons extends StatelessWidget {
  const _Buttons({required this.main, required this.onScanAgain});
  final Widget? main;
  final VoidCallback onScanAgain;

  @override
  Widget build(BuildContext context) {
    final scanAgain = main == null
        ? FilledButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text(AppText.scanAgain),
          )
        : OutlinedButton.icon(
            onPressed: onScanAgain,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text(AppText.scanAgain),
          );
    return Wrap(
      spacing: AppSizes.spaceS,
      runSpacing: AppSizes.spaceS,
      children: [?main, scanAgain],
    );
  }
}

class _CameraProblem extends ConsumerWidget {
  const _CameraProblem({required this.problem, required this.retry});
  final ScannerProblem problem;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusLine(
              icon: Icons.no_photography,
              error: true,
              text: switch (problem) {
                ScannerProblem.permissionDenied => AppText.cameraNeeded,
                ScannerProblem.noCamera => AppText.noCamera,
                ScannerProblem.failed => AppText.cameraFailed,
              },
            ),
            if (problem != ScannerProblem.noCamera) ...[
              const SizedBox(height: AppSizes.spaceS),
              Wrap(
                spacing: AppSizes.spaceS,
                runSpacing: AppSizes.spaceS,
                children: [
                  FilledButton(
                    onPressed: retry,
                    child: Text(
                      problem == ScannerProblem.permissionDenied
                          ? AppText.allowCamera
                          : AppText.tryAgain,
                    ),
                  ),
                  // Android stops showing the dialog after repeated
                  // refusals; then only the app's settings page can allow it.
                  if (problem == ScannerProblem.permissionDenied)
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(locationSourceProvider).openAppSettings(),
                      child: const Text(AppText.openSettings),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.text,
    this.error = false,
  });
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = error ? scheme.error : scheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: colour),
        const SizedBox(width: AppSizes.spaceS),
        Expanded(
          child: Text(text, style: TextStyle(color: colour)),
        ),
      ],
    );
  }
}
