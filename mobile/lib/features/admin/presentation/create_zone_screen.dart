// "Create zone" (GPS zones plan §4.3, T5; FR-11): a name, an optional
// licence number, and the corners, added by standing at each one ("Add my
// location") or by typing them ("Type a corner"), with a live sketch once
// there are three.
//
// What the app checks itself: a name of at least 3 characters, 3 to 100
// corners, and each typed corner being two numbers in range with at most 6
// decimals (corner_input.dart). The shape rules are the server's; its
// messages go on the corner or field they name.
//
// After a 201 the screen closes and tells the list a zone was created, so
// the list shows "Active", where the new zone now is.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/text/app_text.dart';
import '../../../core/theme/sizes.dart';
import '../../../core/widgets/form_message.dart';
import '../../alerts/presentation/alert_widgets.dart' show SmallSpinner;
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/password_prompt.dart';
import '../../registration/data/location_source.dart' show LocationAccess;
import '../../steps/presentation/location_tracker.dart';
import '../../steps/presentation/saved_work_gate.dart' show backOrHome;
import '../domain/corner_input.dart';
import '../domain/gps_zone.dart';
import 'create_zone_controller.dart';
import 'zone_page_screen.dart' show CornerRow;
import 'zone_shape_view.dart';

class CreateZoneScreen extends ConsumerStatefulWidget {
  const CreateZoneScreen({super.key});

  @override
  ConsumerState<CreateZoneScreen> createState() => _CreateZoneScreenState();
}

class _CreateZoneScreenState extends ConsumerState<CreateZoneScreen> {
  // Filled from the controller, which outlives a rebuilt page (see
  // CreateZoneState.name); every keystroke goes back to it.
  late final _name = TextEditingController(
    text: ref.read(createZoneControllerProvider).name,
  );
  late final _licence = TextEditingController(
    text: ref.read(createZoneControllerProvider).licence,
  );

  /// Our own check of the name, before anything is sent.
  String? _nameProblem;

  CreateZoneController get _controller =>
      ref.read(createZoneControllerProvider.notifier);

  @override
  void dispose() {
    _name.dispose();
    _licence.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (ref.read(createZoneControllerProvider).dirty &&
        !await _confirmLeave(context)) {
      return;
    }
    if (mounted) backOrHome(context, AppRoutes.adminZones);
  }

  Future<void> _typeCorner() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TypeCornerDialog(add: _controller.addTyped),
    );
  }

  Future<void> _create() async {
    if (_name.text.trim().length < zoneNameMin) {
      setState(() => _nameProblem = AppText.zoneNameTooShort);
      return;
    }
    setState(() => _nameProblem = null);
    final controller = _controller;

    if (ref.read(authControllerProvider) is SignedInNeedsPassword &&
        !await showPasswordPrompt(context)) {
      return;
    }
    final outcome = await controller.create();
    // The token ran out on the way: the password, then the same zone again
    // (the first send was refused before anything was stored). If this page
    // was rebuilt meanwhile, the new one shows the form's "session expired"
    // and Create asks for the password above. Success is handled in build.
    if (outcome is ZoneCreateNeedsPassword && mounted) {
      if (await showPasswordPrompt(context)) await controller.create();
    }
  }

  bool _closing = false;

  /// The server created the zone: say so, and back to the list.
  ///
  /// Not at once: after the password was asked for again, the router re-runs
  /// its redirect on the next frame, and a page closed before that re-run is
  /// put back by it (T5, fix A, approved by the developer). So it waits for
  /// the end of the frame. Called from build, so a page the re-run rebuilt
  /// closes itself too.
  Future<void> _closeCreated(GpsZone zone) async {
    if (_closing) return;
    _closing = true;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(AppText.zoneCreated(zone.name))));
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(createZoneControllerProvider);
    if (state.created case final created?) unawaited(_closeCreated(created));
    final text = Theme.of(context).textTheme;
    final canCreate =
        !state.saving &&
        !state.locating &&
        state.corners.length >= minZoneCorners &&
        state.name.trim().isNotEmpty;

    return PopScope(
      // Never while sending; and not past typed work without asking.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !state.saving) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: state.saving ? null : _leave),
          title: const Text(AppText.createZone),
        ),
        body: SafeArea(
          child: ListView(
            key: const ValueKey('create-zone'),
            padding: const EdgeInsets.all(AppSizes.spaceM),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(AppText.createZoneIntro),
                      const SizedBox(height: AppSizes.spaceM),
                      TextField(
                        key: const ValueKey('zone-name'),
                        controller: _name,
                        enabled: !state.saving,
                        maxLength: zoneNameMax,
                        textCapitalization: TextCapitalization.words,
                        onChanged: (text) {
                          setState(() => _nameProblem = null);
                          _controller.setName(text);
                        },
                        decoration: InputDecoration(
                          labelText: AppText.zoneName,
                          errorText: _nameProblem ?? state.fieldErrors['name'],
                          errorMaxLines: 4,
                        ),
                      ),
                      const SizedBox(height: AppSizes.spaceS),
                      TextField(
                        key: const ValueKey('zone-licence'),
                        controller: _licence,
                        enabled: !state.saving,
                        maxLength: zoneLicenceMax,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: _controller.setLicence,
                        decoration: InputDecoration(
                          labelText: AppText.zoneLicenceNumber,
                          helperText: AppText.zoneLicenceHint,
                          errorText: state.fieldErrors['licenceNumber'],
                          errorMaxLines: 4,
                        ),
                      ),
                      const SizedBox(height: AppSizes.spaceM),
                      Text(AppText.zoneCornersHeading, style: text.titleMedium),
                      const SizedBox(height: AppSizes.spaceXs),
                      const Text(AppText.zoneCornersHint),
                      const SizedBox(height: AppSizes.spaceS),
                      if (state.corners.isEmpty)
                        const Text(AppText.noCornersYet),
                      for (var i = 0; i < state.corners.length; i++)
                        CornerRow(
                          key: ValueKey('corner-$i'),
                          number: i + 1,
                          corner: state.corners[i],
                          error: state.cornerErrors[i],
                          trailing: IconButton(
                            tooltip: AppText.removeCorner(i + 1),
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: state.saving
                                ? null
                                : () => _controller.remove(i),
                          ),
                        ),
                      if (state.fieldErrors['boundary'] case final problem?)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSizes.spaceS),
                          child: FormMessage(problem),
                        ),
                      if (state.corners.length >= minZoneCorners) ...[
                        const SizedBox(height: AppSizes.spaceM),
                        ZoneShapeView(corners: state.corners),
                        const SizedBox(height: AppSizes.spaceXs),
                        Text(AppText.zoneSketchNote, style: text.bodySmall),
                      ],
                      const SizedBox(height: AppSizes.spaceM),
                      if (!state.canAddCorner && !state.saving)
                        const Padding(
                          padding: EdgeInsets.only(bottom: AppSizes.spaceS),
                          child: Text(AppText.maxCornersReached),
                        ),
                      if (state.location case final status?)
                        _Locating(status: status, controller: _controller)
                      else ...[
                        OutlinedButton.icon(
                          onPressed: state.canAddCorner
                              ? _controller.addMyLocation
                              : null,
                          icon: const Icon(Icons.my_location),
                          label: const Text(AppText.addMyLocation),
                        ),
                        const SizedBox(height: AppSizes.spaceXs),
                        Text(AppText.addMyLocationHint, style: text.bodySmall),
                      ],
                      const SizedBox(height: AppSizes.spaceS),
                      OutlinedButton.icon(
                        onPressed: state.canAddCorner && !state.locating
                            ? _typeCorner
                            : null,
                        icon: const Icon(Icons.keyboard),
                        label: const Text(AppText.typeACorner),
                      ),
                      if (state.failure case final failure?) ...[
                        const SizedBox(height: AppSizes.spaceM),
                        FormMessage(failure),
                      ],
                      const SizedBox(height: AppSizes.spaceL),
                      FilledButton.icon(
                        onPressed: canCreate ? _create : null,
                        icon: state.saving
                            ? const SmallSpinner()
                            : const Icon(Icons.add_location_alt),
                        label: Text(
                          state.saving ? AppText.sending : AppText.createZone,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// While "Add my location" looks: what the GPS says, its way out of a
/// problem, and "Stop".
class _Locating extends StatelessWidget {
  const _Locating({required this.status, required this.controller});

  final LocationStatus status;
  final CreateZoneController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String words, bool problem, Widget? action) = switch (status) {
      LocationStarting() => (AppText.startingLocation, false, null),
      LocationSearching(:final accuracyM, :final stillLooking) => (
        stillLooking
            ? '${AppText.findingLocation(accuracyM)}\n${AppText.stillLooking}'
            : AppText.findingLocation(accuracyM),
        false,
        null,
      ),
      // Never shown: a found reading is added at once.
      LocationFound() => (AppText.startingLocation, false, null),
      LocationMocked() => (AppText.fakeLocation, true, null),
      LocationFailed() => (
        AppText.locationFailed,
        true,
        FilledButton(
          onPressed: controller.retryLocation,
          child: const Text(AppText.tryAgain),
        ),
      ),
      LocationBlocked(:final access) => switch (access) {
        LocationAccess.serviceOff => (
          AppText.zoneLocationOff,
          true,
          FilledButton(
            onPressed: controller.openLocationSettings,
            child: const Text(AppText.turnOnLocation),
          ),
        ),
        LocationAccess.deniedOnce => (
          AppText.zoneLocationNeeded,
          true,
          FilledButton(
            onPressed: controller.retryLocation,
            child: const Text(AppText.allowLocation),
          ),
        ),
        LocationAccess.deniedForever => (
          AppText.locationRefused,
          true,
          FilledButton(
            onPressed: controller.openAppSettings,
            child: const Text(AppText.openSettings),
          ),
        ),
        LocationAccess.approximateOnly => (
          AppText.locationApproximate,
          true,
          FilledButton(
            onPressed: controller.openAppSettings,
            child: const Text(AppText.openSettings),
          ),
        ),
        LocationAccess.granted => (AppText.startingLocation, false, null),
      },
    };
    final searching = status is LocationStarting || status is LocationSearching;

    return Card(
      key: const ValueKey('locating'),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.spaceM),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (searching)
                  const SmallSpinner()
                else
                  ExcludeSemantics(
                    child: Icon(
                      problem ? Icons.gps_off : Icons.gps_fixed,
                      color: problem ? scheme.error : null,
                    ),
                  ),
                const SizedBox(width: AppSizes.spaceS),
                Expanded(child: Text(words)),
              ],
            ),
            const SizedBox(height: AppSizes.spaceS),
            Wrap(
              spacing: AppSizes.spaceS,
              runSpacing: AppSizes.spaceS,
              alignment: WrapAlignment.end,
              children: [
                ?action,
                TextButton(
                  onPressed: controller.stopLocating,
                  child: const Text(AppText.stopLocating),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Type a corner": one field, "latitude, longitude". It stays open with
/// the reason while the text is not a corner, and closes once one is added.
class _TypeCornerDialog extends StatefulWidget {
  const _TypeCornerDialog({required this.add});

  /// Adds the corner; returns why not, or null when added.
  final CornerProblem? Function(String text) add;

  @override
  State<_TypeCornerDialog> createState() => _TypeCornerDialogState();
}

class _TypeCornerDialogState extends State<_TypeCornerDialog> {
  final _text = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final problem = widget.add(_text.text);
    if (problem == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(
      () => _problem = switch (problem) {
        CornerProblem.notTwoNumbers => AppText.cornerNotTwoNumbers,
        CornerProblem.latitudeOutOfRange => AppText.cornerLatitudeRange,
        CornerProblem.longitudeOutOfRange => AppText.cornerLongitudeRange,
        CornerProblem.tooManyDecimals => AppText.cornerTooManyDecimals,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text(AppText.typeCornerTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(AppText.typeCornerExplanation),
          const SizedBox(height: AppSizes.spaceM),
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            decoration: InputDecoration(
              labelText: AppText.cornerFieldLabel,
              hintText: AppText.cornerFieldHint,
              errorText: _problem,
              errorMaxLines: 4,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(AppText.cancel),
        ),
        FilledButton(onPressed: _add, child: const Text(AppText.addCorner)),
      ],
    );
  }
}

/// "Leave without creating the zone?" True to leave.
Future<bool> _confirmLeave(BuildContext context) async {
  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text(AppText.leaveZoneQuestion),
      content: const Text(AppText.leaveZoneExplanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text(AppText.leave),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(AppText.stay),
        ),
      ],
    ),
  );
  return leave == true;
}
