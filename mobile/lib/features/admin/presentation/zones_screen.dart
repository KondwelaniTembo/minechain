// "GPS zones": the administrator's list of licensed extraction zones (GPS
// zones plan §4.1, T2; FR-11, Scope (3) and (7)).
//
// Two lists behind a row of chips: "Active" (the default; the zones sync
// checks registrations against) and "Inactive". Each card says the zone's
// name, licence number, how many corners it has and when it was made. A tap
// opens the zone (T3); coming back reads the list again. "Create zone" (T5)
// is the floating button.
//
// While no zone is active, a warning card says what that means: every new
// registration is flagged (api.md, "No active zones left").
//
// The server checks the role on every request; the router only keeps other
// roles from opening this page.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../alerts/presentation/alert_widgets.dart'
    show AlertInfoLine, AlertStateMessage, SmallSpinner;
import '../../auth/presentation/password_prompt.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/gps_zone.dart';
import 'zone_words.dart';
import 'zones_list_controller.dart';

class ZonesScreen extends ConsumerStatefulWidget {
  const ZonesScreen({super.key});

  @override
  ConsumerState<ZonesScreen> createState() => _ZonesScreenState();
}

class _ZonesScreenState extends ConsumerState<ZonesScreen> {
  ZoneStatus _status = ZoneStatus.active;

  ZonesListController get _controller =>
      ref.read(zonesListControllerProvider(_status).notifier);

  Future<void> _refresh() async {
    final failure = await _controller.refresh();
    if (failure != null && mounted) _say(context, failureText(failure));
  }

  /// Opens one zone; the list is read again when it closes.
  Future<void> _open(GpsZone zone) async {
    ref.read(openedZoneProvider.notifier).open(zone);
    await context.push(AppRoutes.adminZone);
    if (mounted) await _refresh();
  }

  /// Opens "Create zone". A created zone is active, so the list switches to
  /// "Active", where it now is.
  Future<void> _create() async {
    final created = await context.push<bool>(AppRoutes.adminCreateZone);
    if (!mounted) return;
    if (created == true && _status != ZoneStatus.active) {
      setState(() => _status = ZoneStatus.active);
    } else {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(zonesListControllerProvider(_status));
    final noneActive = ref.watch(knownActiveZonesProvider) == 0;
    final canRefresh = switch (state) {
      ZonesLoading() => false,
      ZonesLoaded(:final loadingMore) => !loadingMore,
      _ => true,
    };

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => backOrHome(context, AppRoutes.admin),
        ),
        title: const Text(AppText.gpsZones),
        actions: [
          IconButton(
            tooltip: AppText.refreshList,
            icon: const Icon(Icons.refresh),
            onPressed: canRefresh ? _refresh : null,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add_location_alt),
        label: const Text(AppText.createZone),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            // Scrollable even when short, so the list can always be pulled
            // down to refresh.
            physics: const AlwaysScrollableScrollPhysics(),
            // Room at the bottom, so the floating button never covers the
            // last card or "Show more".
            padding: const EdgeInsets.fromLTRB(
              AppSizes.spaceM,
              AppSizes.spaceM,
              AppSizes.spaceM,
              96,
            ),
            children: [
              for (final child in [
                _StatusChips(
                  selected: _status,
                  onSelected: (status) => setState(() => _status = status),
                ),
                const SizedBox(height: AppSizes.spaceM),
                if (noneActive) ...[
                  const NoActiveZoneCard(),
                  const SizedBox(height: AppSizes.spaceM),
                ],
                ..._body(state),
              ])
                Center(
                  child: ConstrainedBox(
                    // A readable width on a turned phone.
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: child,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(ZonesListState state) => switch (state) {
    ZonesLoading() => const [_Loading()],
    ZonesNeedPassword() => [
      AlertStateMessage(
        icon: Icons.key,
        text: AppText.zonesNeedPassword,
        action: FilledButton(
          onPressed: () async {
            final controller = _controller;
            if (await showPasswordPrompt(context)) await controller.refresh();
          },
          child: const Text(AppText.enterYourPassword),
        ),
      ),
    ],
    ZonesFailed(:final failure) => [
      AlertStateMessage(
        icon: failure is NoConnection ? Icons.wifi_off : Icons.error_outline,
        text: failureText(failure),
        // No casual "Try again" for an unsafe connection: it may mean
        // someone is intercepting the network.
        action: failure is InsecureConnection
            ? null
            : FilledButton(
                onPressed: () => _controller.refresh(),
                child: const Text(AppText.tryAgain),
              ),
      ),
    ],
    ZonesLoaded(zones: []) => [
      AlertStateMessage(
        icon: Icons.inbox,
        text: AppText.noZones(zoneStatusWord(_status)),
      ),
    ],
    final ZonesLoaded loaded => [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSizes.spaceS),
        child: Text(
          AppText.zonesCount(
            status: zoneStatusWord(_status),
            shown: loaded.zones.length,
            total: loaded.total,
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      for (final zone in loaded.zones)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSizes.spaceM),
          child: ZoneCard(
            key: ValueKey(zone.id),
            zone: zone,
            onTap: () => _open(zone),
          ),
        ),
      if (loaded.hasMore)
        OutlinedButton.icon(
          onPressed: loaded.loadingMore
              ? null
              : () async {
                  final failure = await _controller.loadMore();
                  if (failure != null && mounted) {
                    _say(context, failureText(failure));
                  }
                },
          icon: loaded.loadingMore
              ? const SmallSpinner()
              : const Icon(Icons.expand_more),
          label: const Text(AppText.showMore),
        ),
    ],
  };
}

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Two chips, one status at a time. In a Wrap, so at large text they go onto
/// more lines instead of being cut.
class _StatusChips extends StatelessWidget {
  const _StatusChips({required this.selected, required this.onSelected});

  final ZoneStatus selected;
  final ValueChanged<ZoneStatus> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppText.zonesShowing,
      child: Wrap(
        spacing: AppSizes.spaceS,
        runSpacing: AppSizes.spaceS,
        children: [
          for (final status in ZoneStatus.values)
            ChoiceChip(
              label: Text(zoneChipLabel(status)),
              selected: status == selected,
              onSelected: (_) => onSelected(status),
            ),
        ],
      ),
    );
  }
}

/// "No zone is active…": shown while the active list last read was empty.
class NoActiveZoneCard extends StatelessWidget {
  const NoActiveZoneCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(Icons.warning_amber, color: scheme.onErrorContainer),
            ),
            const SizedBox(width: AppSizes.spaceS),
            Expanded(
              child: Text(
                AppText.noActiveZone,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One zone in the list. Public so the zone page's tests can find it.
class ZoneCard extends StatelessWidget {
  const ZoneCard({required this.zone, required this.onTap, super.key});

  final GpsZone zone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.spaceM),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(zone.name, style: text.titleMedium)),
                  const ExcludeSemantics(child: Icon(Icons.chevron_right)),
                ],
              ),
              const SizedBox(height: AppSizes.spaceS),
              AlertInfoLine(
                icon: Icons.verified,
                text: zone.licenceNumber ?? AppText.noLicenceNumber,
              ),
              AlertInfoLine(
                icon: Icons.polyline,
                text: AppText.zoneCorners(zone.boundary.length),
              ),
              AlertInfoLine(
                icon: Icons.event,
                text: AppText.createdOn(zone.createdAt.toLocal()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSizes.spaceXl),
      child: Column(
        children: [
          CircularProgressIndicator(),
          SizedBox(height: AppSizes.spaceM),
          Text(AppText.loadingZones, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
