// The small words and icons both "Accounts" pages build from an account
// (admin accounts plan, T2 and T3): the status in its three forms, the line
// that says why an account is where it is, and the role's icon.
//
// In presentation, not domain, because the words come from AppText.

import 'package:flutter/material.dart';

import '../../../core/text/app_text.dart';
import '../../auth/domain/user.dart' show AccountStatus, Role;
import '../domain/admin_account.dart';

/// The chip's label: "Active".
String statusChipLabel(AccountStatus status) => switch (status) {
  AccountStatus.active => AppText.accountsActive,
  AccountStatus.suspended => AppText.accountsSuspended,
  AccountStatus.invited => AppText.accountsInvited,
  AccountStatus.rejected => AppText.accountsRejected,
  AccountStatus.deleted => AppText.accountsDeleted,
  // Never a chip (Q5); the switch must still be complete.
  AccountStatus.pending => 'Pending',
};

/// The word inside a sentence: "12 active accounts.", "No deleted accounts."
String statusWord(AccountStatus status) =>
    statusChipLabel(status).toLowerCase();

/// The account page's status line: "Suspended: cannot sign in until
/// reactivated."
String statusSentence(AccountStatus status) => switch (status) {
  AccountStatus.active => AppText.accountIsActive,
  AccountStatus.suspended => AppText.accountIsSuspended,
  AccountStatus.invited => AppText.accountIsInvited,
  AccountStatus.pending => AppText.accountIsPending,
  AccountStatus.rejected => AppText.accountIsRejected,
  AccountStatus.deleted => AppText.accountIsDeleted,
};

/// The card's line for its status, or null when there is nothing to add:
/// the reason ("Suspended: Lost device reported"), or an invited account's
/// code ("valid until …", "expired", "none left"). [now] is in UTC.
String? statusDetail(AdminAccount account, DateTime now) {
  final reason = account.statusReason;
  return switch (account.status) {
    AccountStatus.suspended when reason != null => AppText.suspendedBecause(
      reason,
    ),
    AccountStatus.rejected when reason != null => AppText.rejectedBecause(
      reason,
    ),
    AccountStatus.deleted when reason != null => AppText.deletedBecause(reason),
    AccountStatus.invited => _codeLine(account.activationExpiresAt, now),
    _ => null,
  };
}

String _codeLine(DateTime? expiresAt, DateTime now) {
  if (expiresAt == null) return AppText.noCodeLeft;
  // api.md: "A time in the past means it has expired and a new one is
  // needed." The phone's clock may be off by a little; the server decides.
  if (!expiresAt.isAfter(now)) return AppText.codeExpired;
  return AppText.codeValidUntil(expiresAt.toLocal());
}

IconData roleIcon(Role role) => switch (role) {
  Role.miner => Icons.landscape,
  Role.transporter => Icons.local_shipping,
  Role.buyer => Icons.storefront,
  Role.officer => Icons.policy,
  Role.admin => Icons.admin_panel_settings,
};

IconData statusIcon(AccountStatus status) => switch (status) {
  AccountStatus.active => Icons.check_circle,
  AccountStatus.suspended => Icons.pause_circle,
  AccountStatus.invited => Icons.mail,
  AccountStatus.pending => Icons.hourglass_top,
  AccountStatus.rejected => Icons.block,
  AccountStatus.deleted => Icons.delete,
};
