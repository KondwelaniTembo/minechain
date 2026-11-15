// Every sentence and label the user sees, in one file.
//
// Why one file: the wording stays plain and consistent (the same action is
// always called the same thing), it can be read and checked in one go, and if
// a second language is ever added (FR-15, cut for now) there is one place to
// start from.
//
// Rule: everyday words, short, no technical terms (plan section 7). For
// example "Send my work", not "Sync".

/// The app's text. Constants only.
abstract final class AppText {
  // ---- App ----

  static const String appTitle = 'MineChain';

  // ---- Shared ----

  static const String comingSoon = 'Coming soon';
  static const String myAccount = 'My account';

  // ---- Miner home ----

  static const String registerConsignment = 'Register consignment';
  static const String myConsignments = 'My consignments';
  static const String sendMyWork = 'Send my work';
}
