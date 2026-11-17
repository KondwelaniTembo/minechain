// TEST ONLY: stand-ins for the registration screen's plugins and save, so
// the camera, the GPS and the Keystore never load in widget tests.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:minechain/features/auth/domain/user.dart';
import 'package:minechain/features/device_key/presentation/device_key_controller.dart';
import 'package:minechain/features/registration/data/location_source.dart';
import 'package:minechain/features/registration/data/register_consignment.dart';
import 'package:minechain/features/registration/domain/gps_fix.dart';
import 'package:minechain/features/registration/domain/mineral.dart';
import 'package:minechain/features/registration/presentation/qr_scanner_view.dart';

import 'fake_device_key_channel.dart';

/// The GPS: [access] is what ensureAccess answers; readings are pushed in
/// by the test with [emit] or [fail].
class FakeLocationSource implements LocationSource {
  FakeLocationSource([this.access = LocationAccess.granted]);

  LocationAccess access;
  int accessChecks = 0;

  /// The `ask` of each ensureAccess call, in order.
  final List<bool> asks = [];
  int locationSettingsOpened = 0;
  int appSettingsOpened = 0;

  /// When set, ensureAccess waits for it instead of answering at once (a
  /// dialog left open, or the hang seen on the A57).
  Completer<LocationAccess>? pending;

  /// When set, ensureAccess throws it (a plugin fault).
  Object? accessError;

  /// When set, readings() throws it.
  Object? readingsError;

  final StreamController<GpsReading> _readings =
      StreamController<GpsReading>.broadcast();

  bool get listening => _readings.hasListener;

  @override
  Future<LocationAccess> ensureAccess({bool ask = true}) async {
    accessChecks++;
    asks.add(ask);
    final error = accessError;
    if (error != null) throw error;
    final waiting = pending;
    if (waiting != null) return waiting.future;
    return access;
  }

  @override
  Stream<GpsReading> readings() {
    final error = readingsError;
    if (error != null) throw error;
    return _readings.stream;
  }

  void emit(GpsReading reading) => _readings.add(reading);
  void fail(LocationStreamProblem problem) =>
      _readings.addError(LocationStreamError(problem));

  @override
  Future<void> openLocationSettings() async => locationSettingsOpened++;

  @override
  Future<void> openAppSettings() async => appSettingsOpened++;
}

/// A reading at [at], [accuracyM] metres, real unless [mocked].
GpsReading reading(
  DateTime at, {
  double accuracyM = 6,
  bool mocked = false,
  bool hasAccuracy = true,
}) => GpsReading(
  latitude: -15.4190123,
  longitude: 28.2881049,
  accuracyM: accuracyM,
  hasAccuracy: hasAccuracy,
  isMocked: mocked,
  timestamp: at,
);

/// The camera: shows a plain box, or the screen's own problem view when
/// [problem] is set. The test "scans" with [scan].
class FakeQrScanner {
  ValueChanged<String>? _onCode;
  ScannerProblem? problem;
  int retries = 0;

  /// What the provider hands the screen.
  QrScannerBuilder get builder => ({required onCode, required problemBuilder}) {
    _onCode = onCode;
    return Builder(
      builder: (context) {
        final current = problem;
        if (current != null) {
          return problemBuilder(context, current, () => retries++);
        }
        return const ColoredBox(
          color: Colors.black,
          child: Center(child: Text('fake camera')),
        );
      },
    );
  };

  void scan(String code) => _onCode!(code);
}

/// The save, recording each call and answering with [answer] (SaveDone by
/// default), or waiting for [hold].
class FakeRegisterConsignment extends RegisterConsignment {
  FakeRegisterConsignment()
    : super(
        channel: FakeDeviceKeyChannel(),
        steps: () => throw UnimplementedError('not used by the fake'),
        keyState: () => const DeviceKeyNotNeeded(),
      );

  final List<Map<String, Object?>> calls = [];
  SaveResult answer = const SaveDone('6f1d2c3a-0000-4000-8000-000000000999');
  Completer<void>? hold;

  @override
  Future<SaveResult> save({
    required User user,
    required String qrCode,
    required Mineral mineral,
    required String weightMg,
    required double latitude,
    required double longitude,
    double? gpsAccuracyM,
  }) async {
    calls.add({
      'qrCode': qrCode,
      'mineral': mineral,
      'weightMg': weightMg,
      'latitude': latitude,
      'longitude': longitude,
    });
    final waiting = hold;
    if (waiting != null) await waiting.future;
    return answer;
  }
}

/// A device key controller holding a fixed state.
class StaticDeviceKeyController extends DeviceKeyController {
  StaticDeviceKeyController(this.initial);
  final DeviceKeyState initial;

  @override
  DeviceKeyState build() => initial;

  @override
  Future<void> check(User user) async {}
}
