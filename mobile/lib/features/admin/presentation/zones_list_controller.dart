// The state behind the administrator's "GPS zones" list (GPS zones plan,
// T2): one list per status ("Active", "Inactive"), fetched 20 at a time.
//
// Built like AccountsListController, for the same reasons: the screen needs
// the password prompt and "Show more" while the list stays on screen, and the
// list is read again when the administrator comes back from a zone, so it
// never shows a change the server has not made.
//
// It also keeps two small things the other zone pages need:
// - how many zones were active when the active list was last read, for the
//   deactivate dialog's "only active zone" pre-warning (Q4) and the list's
//   warning card;
// - the zone the list opened last, for its page (no GET /admin/zones/{id}).
//
// Nothing about a zone (name, licence number, corners) is logged; the
// states' toString() print only counts.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_failure.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_zones_repository.dart';
import '../domain/gps_zone.dart';

sealed class ZonesListState {
  const ZonesListState();
}

/// The first page is being fetched; nothing to show yet.
final class ZonesLoading extends ZonesListState {
  const ZonesLoading();
}

/// The token has expired: the password is needed first.
final class ZonesNeedPassword extends ZonesListState {
  const ZonesNeedPassword();
}

/// The first page could not be fetched.
final class ZonesFailed extends ZonesListState {
  const ZonesFailed(this.failure);
  final AppFailure failure;

  @override
  String toString() => 'ZonesFailed($failure)';
}

/// The list, possibly empty.
final class ZonesLoaded extends ZonesListState {
  const ZonesLoaded({
    required this.zones,
    required this.total,
    this.loadingMore = false,
  });

  /// In the server's order: by name, ignoring letter case.
  final List<GpsZone> zones;

  /// Every zone with this status on the server, not only those loaded.
  final int total;

  /// "Show more" is fetching the next page.
  final bool loadingMore;

  bool get hasMore => zones.length < total;

  @override
  String toString() =>
      'ZonesLoaded(zones: ${zones.length}, total: $total, '
      'loadingMore: $loadingMore)';
}

class ZonesListController extends Notifier<ZonesListState> {
  ZonesListController(this.status);

  /// Which of the two lists this is.
  final ZoneStatus status;

  bool _refreshing = false;

  AdminZonesRepository get _repository =>
      ref.read(adminZonesRepositoryProvider);

  @override
  ZonesListState build() {
    // The first fetch starts just after build returns: a Notifier may not
    // change its own state while it is being built.
    Future.microtask(refresh);
    return const ZonesLoading();
  }

  /// Fetches the first page again (opening the screen, coming back from a
  /// zone, pull-to-refresh, the refresh button, "Try again").
  ///
  /// Returns a failure only when a list was already on screen and stays
  /// there, so the screen can mention it briefly. Without a list, the
  /// failure becomes the state itself.
  Future<AppFailure?> refresh() async {
    if (!ref.mounted) return null;
    final before = state;
    if (_refreshing) return null;
    if (before is ZonesLoaded && before.loadingMore) return null;

    final token = _token();
    if (token == null) {
      state = const ZonesNeedPassword();
      return null;
    }
    if (before is! ZonesLoaded) state = const ZonesLoading();

    _refreshing = true;
    try {
      final page = await _repository.zones(token: token, status: status);
      if (!ref.mounted) return null;
      state = ZonesLoaded(zones: page.zones, total: page.total);
      _noteActiveCount(page.total);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      if (state is ZonesLoaded) return failure;
      state = _token() == null
          ? const ZonesNeedPassword() // TOKEN_EXPIRED on this very fetch
          : ZonesFailed(failure);
      return null;
    } finally {
      _refreshing = false;
    }
  }

  /// Fetches the next page and adds it under the list.
  Future<AppFailure?> loadMore() async {
    final current = state;
    if (current is! ZonesLoaded || current.loadingMore || !current.hasMore) {
      return null;
    }
    if (_refreshing) return null;
    final token = _token();
    if (token == null) {
      state = const ZonesNeedPassword();
      return null;
    }

    state = ZonesLoaded(
      zones: current.zones,
      total: current.total,
      loadingMore: true,
    );
    try {
      final page = await _repository.zones(
        token: token,
        status: status,
        offset: current.zones.length,
      );
      if (!ref.mounted) return null;
      // If another administrator acted meanwhile, the pages can overlap.
      final known = {for (final z in current.zones) z.id};
      state = ZonesLoaded(
        zones: [
          ...current.zones,
          for (final z in page.zones)
            if (!known.contains(z.id)) z,
        ],
        total: page.total,
      );
      _noteActiveCount(page.total);
      return null;
    } on AppFailure catch (failure) {
      if (!ref.mounted) return null;
      state = ZonesLoaded(zones: current.zones, total: current.total);
      return failure;
    }
  }

  void _noteActiveCount(int total) {
    if (status == ZoneStatus.active) {
      ref.read(knownActiveZonesProvider.notifier).set(total);
    }
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// One list per status. autoDispose: leaving the screen (or switching to
/// the other list) forgets it, so it is always fetched fresh.
final zonesListControllerProvider = NotifierProvider.autoDispose
    .family<ZonesListController, ZonesListState, ZoneStatus>(
      ZonesListController.new,
    );

/// How many zones were active when the active list was last read, or null
/// before it has been read. A hint only (another administrator may act at
/// any moment); the server's NO_ACTIVE_ZONES warning is what counts (api.md,
/// "No active zones left").
class KnownActiveZones extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int count) => state = count;
}

final knownActiveZonesProvider = NotifierProvider<KnownActiveZones, int?>(
  KnownActiveZones.new,
);

/// The zone the list opened last, for its page.
///
/// Not the route's `extra`, for the reason openedAccountProvider gives: when
/// the 60-minute token runs out on the page, the router re-runs its redirect
/// and rebuilds the page without the `extra`. It is still lost when Android
/// closes the app, a known limitation: there is no GET /admin/zones/{id}.
class OpenedZone extends Notifier<GpsZone?> {
  @override
  GpsZone? build() => null;

  void open(GpsZone zone) => state = zone;
}

final openedZoneProvider = NotifierProvider<OpenedZone, GpsZone?>(
  OpenedZone.new,
);
