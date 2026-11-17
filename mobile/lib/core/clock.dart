// "What time is it?", as something that can be swapped.
//
// Code that compares times (has this token expired?) asks clockProvider
// instead of calling DateTime.now() itself, so a test can say "it is now
// 09:00" and check the rule exactly, without waiting.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Returns the current time, in UTC.
typedef Clock = DateTime Function();

DateTime systemClock() => DateTime.now().toUtc();

final clockProvider = Provider<Clock>((ref) => systemClock);
