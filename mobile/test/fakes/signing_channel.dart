// The Keystore for save tests: "signs" by recording the bytes and returning
// a fixed DER signature, or refuses with [refuse]. Shared from buyer
// purchase T1 on; the older handoff and registration tests keep their own
// copies, which do the same.

import 'dart:typed_data';

import 'package:minechain/features/device_key/data/device_key_channel.dart';

import 'fake_device_key_channel.dart';

class SigningChannel extends FakeDeviceKeyChannel {
  SigningChannel({super.keys});

  /// Every byte string signed, in order.
  final List<Uint8List> signed = [];

  /// When set, sign() throws this error and records nothing.
  DeviceKeyError? refuse;

  /// The fixed signature: DER for r = 1, s = 2.
  static final Uint8List signature = Uint8List.fromList([
    0x30,
    0x06,
    0x02,
    0x01,
    0x01,
    0x02,
    0x01,
    0x02,
  ]);

  @override
  Future<Uint8List> sign(String alias, Uint8List bytes) async {
    final error = refuse;
    if (error != null) throw DeviceKeyException(error);
    signed.add(Uint8List.fromList(bytes));
    return Uint8List.fromList(signature);
  }
}
