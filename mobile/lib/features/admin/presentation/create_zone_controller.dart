// The state behind "Create zone" (GPS zones plan §4.3, T5): the corners so
// far, the GPS while "Add my location" looks for a fix, the send, and the
// server's messages put back on the field or corner they name.
//
// The name and licence number live in the screen's text fields; the corners
// live here, because both the GPS and the typed-corner dialog add to them.
//
// "Add my location" (Q1) uses the same LocationTracker and fix policy as the
// custody screens (25 m at most, 30 s old at most, no fake-location app). It
// starts only when tapped, never on opening the screen, so the location
// question is asked only of an administrator who wants it, and it stops as
// soon as one usable reading has been added. The reading is rounded to 6
// decimal places (Q3).
//
// Nothing about the zone (name, corners, readings) is logged.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clock.dart';
import '../../../core/errors/api_codes.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/errors/failure_text.dart';
import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../registration/data/location_source.dart';
import '../../steps/presentation/location_tracker.dart';
import '../data/admin_zones_repository.dart';
import '../domain/corner_input.dart';
import '../domain/gps_zone.dart';

class CreateZoneState {
  const CreateZoneState({
    this.name = '',
    this.licence = '',
    this.corners = const [],
    this.location,
    this.saving = false,
    this.fieldErrors = const {},
    this.cornerErrors = const {},
    this.failure,
    this.created,
  });

  /// The name and licence number as typed. Here, not only in the screen's
  /// text fields: when the 60-minute token runs out, the router rebuilds the
  /// page and the screen's own state starts afresh (the lesson of Admin
  /// accounts T4, found again by the T5 session test), but this provider
  /// lives on.
  final String name;
  final String licence;

  final List<ZoneCorner> corners;

  /// While "Add my location" is looking: what the GPS says. Null otherwise.
  final LocationStatus? location;

  final bool saving;

  /// The server's messages by the API's field names: `name`,
  /// `licenceNumber`, `boundary` (the corner list as a whole).
  final Map<String, String> fieldErrors;

  /// The server's messages by corner, counting from 0.
  final Map<int, String> cornerErrors;

  /// Any other refusal, shown above the Create button.
  final String? failure;

  /// The zone the server created; the screen closes when it is set, from
  /// whichever page is on screen by then.
  final GpsZone? created;

  bool get locating => location != null;
  bool get canAddCorner => corners.length < maxZoneCorners && !saving;

  /// Anything typed or added, for "Leave without creating the zone?".
  bool get dirty =>
      name.trim().isNotEmpty || licence.trim().isNotEmpty || corners.isNotEmpty;

  CreateZoneState copyWith({
    String? name,
    String? licence,
    GpsZone? created,
    List<ZoneCorner>? corners,
    LocationStatus? location,
    bool clearLocation = false,
    bool? saving,
    Map<String, String>? fieldErrors,
    Map<int, String>? cornerErrors,
    String? failure,
    bool clearFailure = false,
  }) => CreateZoneState(
    name: name ?? this.name,
    licence: licence ?? this.licence,
    created: created ?? this.created,
    corners: corners ?? this.corners,
    location: clearLocation ? null : (location ?? this.location),
    saving: saving ?? this.saving,
    fieldErrors: fieldErrors ?? this.fieldErrors,
    cornerErrors: cornerErrors ?? this.cornerErrors,
    failure: clearFailure ? null : (failure ?? this.failure),
  );

  @override
  String toString() =>
      'CreateZoneState(corners: ${corners.length}, locating: $locating, '
      'saving: $saving)';
}

/// What a create came to.
sealed class CreateZoneOutcome {
  const CreateZoneOutcome();
}

final class ZoneCreated extends CreateZoneOutcome {
  const ZoneCreated(this.zone);
  final GpsZone zone;
}

/// Refused or not sent; the state says where.
final class ZoneNotCreated extends CreateZoneOutcome {
  const ZoneNotCreated();
}

/// The token has expired: ask for the password, then send again.
final class ZoneCreateNeedsPassword extends CreateZoneOutcome {
  const ZoneCreateNeedsPassword();
}

class CreateZoneController extends Notifier<CreateZoneState> {
  late final LocationTracker _location = LocationTracker(
    source: () => ref.read(locationSourceProvider),
    clock: () => ref.read(clockProvider),
    isAlive: () => ref.mounted,
    onStatus: _onLocation,
  );

  AdminZonesRepository get _repository =>
      ref.read(adminZonesRepositoryProvider);

  @override
  CreateZoneState build() {
    ref.onDispose(_location.stop);
    return const CreateZoneState();
  }

  /// A typed corner: added, or the problem. Null means added.
  CornerProblem? addTyped(String text) {
    if (!state.canAddCorner) return null;
    final input = parseCorner(text);
    final corner = input.corner;
    if (corner == null) return input.problem;
    _setCorners([...state.corners, corner]);
    return null;
  }

  /// Starts looking for one usable GPS reading to add as the next corner.
  Future<void> addMyLocation() async {
    if (!state.canAddCorner || state.locating) return;
    state = state.copyWith(location: const LocationStarting());
    await _location.start();
  }

  /// "Try again" and "Allow location" while looking.
  Future<void> retryLocation() => _location.start();

  /// "Stop": no corner is added.
  void stopLocating() {
    _location.stop();
    state = state.copyWith(clearLocation: true);
  }

  Future<void> openLocationSettings() => _location.openLocationSettings();
  Future<void> openAppSettings() => _location.openAppSettings();

  void _onLocation(LocationStatus status) {
    if (!state.locating) return;
    if (status is LocationFound) {
      _location.stop();
      final fix = status.fix;
      state = state.copyWith(clearLocation: true);
      if (state.canAddCorner) {
        _setCorners([
          ...state.corners,
          cornerFromReading(fix.latitude, fix.longitude),
        ]);
      }
      return;
    }
    state = state.copyWith(location: status);
  }

  void remove(int index) {
    if (state.saving || index < 0 || index >= state.corners.length) return;
    _setCorners([...state.corners]..removeAt(index));
  }

  /// A change to the list moves every corner after it, so the server's
  /// messages about corners and the shape no longer point at the right one.
  void _setCorners(List<ZoneCorner> corners) {
    final errors = {...state.fieldErrors}..remove('boundary');
    state = state.copyWith(
      corners: corners,
      fieldErrors: errors,
      cornerErrors: const {},
      clearFailure: true,
    );
  }

  void setName(String text) {
    final errors = {...state.fieldErrors}..remove('name');
    state = state.copyWith(name: text, fieldErrors: errors);
  }

  void setLicence(String text) {
    final errors = {...state.fieldErrors}..remove('licenceNumber');
    state = state.copyWith(licence: text, fieldErrors: errors);
  }

  /// Sends the zone as it stands. On success [CreateZoneState.created] is
  /// set as well, for whichever page is on screen by then.
  Future<CreateZoneOutcome> create() async {
    if (state.saving ||
        state.created != null ||
        state.corners.length < minZoneCorners) {
      return const ZoneNotCreated();
    }
    final name = state.name;
    final licenceNumber = state.licence;
    final token = _token();
    if (token == null) return const ZoneCreateNeedsPassword();

    state = state.copyWith(
      saving: true,
      fieldErrors: const {},
      cornerErrors: const {},
      clearFailure: true,
    );
    try {
      final zone = await _repository.create(
        token: token,
        name: name,
        licenceNumber: licenceNumber,
        boundary: state.corners,
      );
      if (ref.mounted) state = state.copyWith(saving: false, created: zone);
      return ZoneCreated(zone);
    } on AppFailure catch (failure) {
      if (!ref.mounted) return const ZoneNotCreated();
      final expired =
          failure is ServerRefused && failure.code == ApiCodes.tokenExpired;
      if (expired || _token() == null) {
        // Said on the form too: if the page was rebuilt meanwhile, the
        // screen that asked is gone, and the new one must still say why
        // nothing was created. Tapping Create again asks for the password.
        state = state.copyWith(saving: false, failure: failureText(failure));
        return const ZoneCreateNeedsPassword();
      }
      state = _placed(failure, state.copyWith(saving: false));
      return const ZoneNotCreated();
    }
  }

  /// Puts each of the server's messages where it belongs.
  CreateZoneState _placed(AppFailure failure, CreateZoneState base) {
    if (failure is! ServerRefused) {
      return base.copyWith(failure: failureText(failure));
    }
    if (failure.code == ApiCodes.zoneNameTaken) {
      return base.copyWith(fieldErrors: {'name': failureText(failure)});
    }
    final fields = <String, String>{};
    final corners = <int, String>{};
    for (final detail in failure.details) {
      final index = cornerIndexOfField(detail.field);
      if (index != null && index < base.corners.length) {
        corners.update(
          index,
          (before) => '$before\n${detail.message}',
          ifAbsent: () => detail.message,
        );
      } else if (const {
        'name',
        'licenceNumber',
        'boundary',
      }.contains(detail.field)) {
        fields[detail.field] = detail.message;
      }
    }
    // A refusal that names no field shown here still says something.
    final placed = fields.isNotEmpty || corners.isNotEmpty;
    return base.copyWith(
      fieldErrors: fields,
      cornerErrors: corners,
      failure: placed ? null : failureText(failure),
    );
  }

  String? _token() {
    final auth = ref.read(authControllerProvider);
    return auth is SignedIn ? auth.token : null;
  }
}

/// autoDispose: leaving the screen forgets the corners and stops the GPS.
final createZoneControllerProvider =
    NotifierProvider.autoDispose<CreateZoneController, CreateZoneState>(
      CreateZoneController.new,
    );
