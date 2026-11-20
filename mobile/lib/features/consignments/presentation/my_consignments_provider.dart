// What "My consignments" and "My handoffs" list (plan M7, Scope (8),
// decision Mobile (34); by step type since Transporter handoff T5): the
// signed-in user's steps of one type on this phone, newest first, from the
// encrypted local database only. No network, so it works offline, and also
// while the session waits for the password (Mobile (11)).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/auth_state.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../steps/data/local_steps_repository.dart';
import '../../steps/domain/consignment_list_item.dart';
import '../../sync/data/sync_service.dart';

/// The user's steps of a type (`registration`, `handoff`, `purchase`).
/// autoDispose: read fresh each time the screen opens.
final myStepsProvider = FutureProvider.autoDispose
    .family<List<ConsignmentListItem>, String>((ref, type) async {
      // Read again whenever a send finishes, whatever started it: each run
      // ends with a new report, and the statuses may have changed. A run in
      // progress keeps the old report, so the list does not flicker.
      ref.watch(syncServiceProvider.select((status) => status.last));

      final auth = ref.watch(authControllerProvider);
      final user = switch (auth) {
        SignedIn(:final user) || SignedInNeedsPassword(:final user) => user,
        _ => null,
      };
      if (user == null) return const [];
      final steps = await ref.watch(localStepsRepositoryProvider.future);
      return steps.listOfTypeForActor(user.id, type);
    });
