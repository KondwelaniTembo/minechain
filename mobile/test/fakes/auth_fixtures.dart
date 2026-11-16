// TEST ONLY: sample accounts and API answers, with the fake values api.md
// uses (ids like 3f2b6c1e-0000-4000-8000-000000000001, tokens containing
// FAKE). None is a real person, password or token.

import 'dart:convert';

const fakeToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKE-PAYLOAD.FAKE-SIGNATURE';
const fakePassword = 'gold river kasempa';

Map<String, Object?> userJson({
  String id = '3f2b6c1e-0000-4000-8000-000000000001',
  String username = 'mutale_banda',
  String fullName = 'Mutale Banda',
  String role = 'miner',
  String status = 'active',
}) => {
  'id': id,
  'username': username,
  'fullName': fullName,
  'licenceNumber': 'ZM-ASM-0042',
  'role': role,
  'status': status,
  'createdAt': '2026-11-05T09:00:00.000Z',
  'publicKeyFingerprint': null,
};

String loginAnswer({
  String token = fakeToken,
  int expiresIn = 3600,
  Map<String, Object?>? user,
}) => jsonEncode({
  'token': token,
  'tokenType': 'Bearer',
  'expiresIn': expiresIn,
  'user': user ?? userJson(),
});

String meAnswer({Map<String, Object?>? user}) =>
    jsonEncode({'user': user ?? userJson()});

String errorAnswer(String code, [String message = 'Refused.']) => jsonEncode({
  'error': {'code': code, 'message': message},
});
