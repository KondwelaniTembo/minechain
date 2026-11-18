// The camera view that reads the custody record's QR code (plan §6), behind
// a small builder function so widget tests can put a fake in its place and
// the camera plugin never loads there.
//
// The real one uses mobile_scanner 7.5.0. What its README and sources say,
// and this file relies on:
// - "This package uses by default the bundled version of MLKit
//   Barcode-scanning for Android. This version is immediately available to
//   the device", so scanning works offline at a mine site (Mobile (5));
// - `MobileScannerController(formats: [...])` limits what is decoded;
// - the MobileScanner widget follows the app's lifecycle by itself
//   (`useAppLifecycleState`, true by default): the camera stops when the app
//   goes to the background and starts again on return;
// - it asks for the camera permission when it starts, and a refusal arrives
//   in `errorBuilder` as `MobileScannerErrorCode.permissionDenied`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Why the camera cannot scan.
enum ScannerProblem { permissionDenied, noCamera, failed }

/// Builds the scanner. [onCode] receives each decoded QR text exactly as
/// read. [problemBuilder] draws what to show instead of the camera, with a
/// [retry] that starts the camera again (and so asks for the permission
/// again, where Android still allows that).
typedef QrScannerBuilder = Widget Function({
  required ValueChanged<String> onCode,
  required Widget Function(
    BuildContext context,
    ScannerProblem problem,
    VoidCallback retry,
  )
  problemBuilder,
});

Widget _realScanner({
  required ValueChanged<String> onCode,
  required Widget Function(BuildContext, ScannerProblem, VoidCallback)
  problemBuilder,
}) => _MobileScannerView(onCode: onCode, problemBuilder: problemBuilder);

final qrScannerBuilderProvider = Provider<QrScannerBuilder>(
  (ref) => _realScanner,
);

class _MobileScannerView extends StatefulWidget {
  const _MobileScannerView({
    required this.onCode,
    required this.problemBuilder,
  });

  final ValueChanged<String> onCode;
  final Widget Function(BuildContext, ScannerProblem, VoidCallback)
  problemBuilder;

  @override
  State<_MobileScannerView> createState() => _MobileScannerViewState();
}

class _MobileScannerViewState extends State<_MobileScannerView> {
  // QR only: a shop barcode or another format is never even decoded.
  // noDuplicates: the same code held in front of the camera is reported
  // once, not thirty times a second.
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      // rawValue is the text exactly as encoded: never trimmed or changed
      // here (signing spec, section 4).
      final value = barcode.rawValue;
      if (value != null) {
        widget.onCode(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MobileScanner(
      controller: _controller,
      onDetect: _onDetect,
      errorBuilder: (context, error) =>
          widget.problemBuilder(context, switch (error.errorCode) {
            MobileScannerErrorCode.permissionDenied =>
              ScannerProblem.permissionDenied,
            MobileScannerErrorCode.unsupported => ScannerProblem.noCamera,
            _ => ScannerProblem.failed,
          }, () => _controller.start()),
    );
  }
}
