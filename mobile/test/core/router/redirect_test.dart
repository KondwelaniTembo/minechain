// The redirect rules as a table: every sign-in state, every kind of path, all
// five roles. Because redirectFor is a pure function, each case is one line:
// inputs in, answer out.

import 'package:flutter_test/flutter_test.dart';
import 'package:minechain/core/router/redirect.dart';
import 'package:minechain/core/router/routes.dart';
import 'package:minechain/features/auth/domain/auth_state.dart';
import 'package:minechain/features/auth/domain/user.dart';

import '../../fakes/fake_controllers.dart';

const homes = {
  Role.miner: AppRoutes.miner,
  Role.transporter: AppRoutes.transporter,
  Role.buyer: AppRoutes.buyer,
  Role.officer: AppRoutes.officer,
  Role.admin: AppRoutes.admin,
};

/// Every path the table tries: the fixed pages, each home, a page under each
/// home, and paths that belong to nobody.
final paths = [
  AppRoutes.start,
  AppRoutes.login,
  AppRoutes.register,
  AppRoutes.activate,
  AppRoutes.account,
  '${AppRoutes.account}/something', // nothing lives under /account
  ...homes.values,
  for (final home in homes.values) '$home/something',
  AppRoutes.adminRequests, // administrators only (plan A1)
  '/nowhere',
  '/',
  '/minerx', // looks like /miner, but is not under it
];

void main() {
  group('AuthUnknown: everything goes to /start', () {
    for (final path in paths) {
      test(path, () {
        expect(
          redirectFor(const AuthUnknown(), path),
          path == AppRoutes.start ? isNull : AppRoutes.start,
        );
      });
    }
  });

  for (final signedOut in const [
    SignedOut(),
    SignedOut(reason: 'ACCOUNT_SUSPENDED'),
  ]) {
    group('$signedOut: only the signed-out pages', () {
      for (final path in paths) {
        test(path, () {
          final allowed = AppRoutes.signedOutPages.contains(path);
          expect(
            redirectFor(signedOut, path),
            allowed ? isNull : AppRoutes.login,
          );
        });
      }
    });
  }

  for (final role in Role.values) {
    final home = homes[role]!;
    // SignedInNeedsPassword routes exactly like SignedIn (decision Q2).
    for (final state in <AuthState>[
      signedInAs(role),
      SignedInNeedsPassword(userOf(role)),
    ]) {
      group('${state.runtimeType} as ${role.name}', () {
        for (final path in paths) {
          // The role's own pages, plus /account, which every role may open.
          final ownPage = path == home ||
              path.startsWith('$home/') ||
              path == AppRoutes.account;
          test('$path -> ${ownPage ? 'stays' : home}', () {
            expect(redirectFor(state, path), ownPage ? isNull : home);
          });
        }
      });
    }
  }

  test('a query or fragment does not change the decision', () {
    expect(redirectFor(signedInAs(Role.miner), '/miner?tab=2#top'), isNull);
    expect(redirectFor(const SignedOut(), '/login?next=%2Fadmin'), isNull);
    expect(
      redirectFor(signedInAs(Role.miner), '/admin?x=1'),
      AppRoutes.miner,
    );
  });

  test('following a redirect never redirects again (no loops)', () {
    final states = <AuthState>[
      const AuthUnknown(),
      const SignedOut(),
      for (final role in Role.values) signedInAs(role),
      for (final role in Role.values) SignedInNeedsPassword(userOf(role)),
    ];
    for (final state in states) {
      for (final path in paths) {
        final target = redirectFor(state, path);
        if (target != null) {
          expect(redirectFor(state, target), isNull,
              reason: '$state: $path -> $target -> somewhere else');
        }
      }
    }
  });

  test('homeOf gives each role its own home', () {
    for (final MapEntry(key: role, value: home) in homes.entries) {
      expect(homeOf(role), home);
    }
  });
}
