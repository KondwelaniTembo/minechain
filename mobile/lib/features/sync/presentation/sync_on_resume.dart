// Starts an automatic send each time the app comes back to the front (plan
// Q4), like SessionExpiryWatcher does for the token's expiry. The sync
// service itself decides whether it may run (at most once every 2 minutes,
// not before a 429's Retry-After, never with an expired token).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sync_service.dart';
import '../domain/sync_report.dart';

class SyncOnResume extends ConsumerStatefulWidget {
  const SyncOnResume({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SyncOnResume> createState() => _SyncOnResumeState();
}

class _SyncOnResumeState extends ConsumerState<SyncOnResume> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(
        ref.read(syncServiceProvider.notifier).syncNow(SyncTrigger.resume),
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
