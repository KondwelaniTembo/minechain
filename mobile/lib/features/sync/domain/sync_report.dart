// What one sync run came to, for the "Send my work" screen. Plain Dart.
//
// No payload, signature, token or coordinates are held here: only counts,
// QR codes, and the server's codes and messages, which are shown as given.

/// What started a run (plan Q4, and M6's approved points 6 and 7).
enum SyncTrigger {
  /// "Send now" on the screen: ignores the backoff, may ask for the password.
  tap,

  /// A fresh sign-in: a login, the session restored at start-up, or the
  /// password entered again after the token ran out. Outside the 2-minute
  /// limit: the session it waited for has just become usable.
  signIn,

  /// The app came back to the front.
  resume,

  /// A step was just saved: runs at once, outside the 2-minute limit.
  afterSave,
}

/// Why a run stopped before every due step had an answer. Nothing in any
/// row changed because of the stop itself; the waiting work stays.
enum SyncStop {
  /// Not signed in (or the server just ended the session).
  notSignedIn,

  /// The token has run out: the password must be entered again.
  needsPassword,

  /// The server has another phone's key for this account.
  keyOtherDevice,

  /// The key could not be set up ([SyncReport.message] says why).
  keyProblem,

  /// No connection could be made.
  offline,

  /// No answer within the time limit (a sleeping server, a weak signal).
  timedOut,

  /// The server answered with a fault (500, an unreadable answer).
  serverProblem,

  /// 429: too many sync requests ([SyncReport.message] is the server's).
  tooManyRequests,

  /// The server refused the request as malformed (400, 413, 403): an app
  /// bug. Nothing is resent automatically until the next trigger.
  appProblem,

  /// The connection failed its safety checks (pinning, TLS 1.3).
  insecure,

  /// The saved work really cannot be opened with this phone's key (a
  /// DatabaseFailure other than busy). Only this says "ask an
  /// administrator".
  savedWorkProblem,

  /// Something on the phone failed for a moment: the database file was in
  /// use, or any other error that is not "cannot be opened". The work is
  /// untouched, and the run is tried once more by itself
  /// ([SyncReport.retrySoon]).
  phoneBusy,
}

/// A step that came back under review or not accepted, to name on screen.
class SyncProblem {
  const SyncProblem({
    required this.qrCode,
    required this.rejected,
    required this.code,
    required this.message,
  });

  final String qrCode;

  /// True: `rejected` (never stored). False: `flagged` (stored, under
  /// review).
  final bool rejected;
  final String code;

  /// The server's message, shown as given.
  final String message;

  @override
  String toString() => 'SyncProblem(rejected: $rejected, code: $code)';
}

class SyncReport {
  const SyncReport({
    required this.startedAt,
    required this.trigger,
    required this.elapsed,
    this.sent = 0,
    this.underReview = 0,
    this.rejected = 0,
    this.waiting = 0,
    this.unmatched = 0,
    this.problems = const [],
    this.stop,
    this.message,
    this.retrySoon = false,
  });

  /// When the run started (UTC, from the app's clock). The screen shows it
  /// in the phone's local time.
  final DateTime startedAt;

  /// What started it: shown as "you tapped Send now", "after you saved" or
  /// "started automatically".
  final SyncTrigger trigger;

  /// From the start of the run to its end, for NFR-03 (debug builds show it).
  final Duration elapsed;

  /// `created` or `duplicate`.
  final int sent;

  /// `flagged`: stored on the server too, but under review.
  final int underReview;

  /// Every step the server stored in this run: [sent] and [underReview].
  int get sentToServer => sent + underReview;

  /// `rejected`.
  final int rejected;

  /// `deferred`: still on the phone, to be sent again.
  final int waiting;

  /// Results the app could not match to a step (an app bug). Those steps
  /// are unchanged and will be sent again.
  final int unmatched;

  final List<SyncProblem> problems;

  /// Null when the run finished.
  final SyncStop? stop;

  /// The server's message for [SyncStop.tooManyRequests], or the key
  /// problem's sentence for [SyncStop.keyProblem].
  final String? message;

  /// For [SyncStop.phoneBusy]: true when the service will try again by
  /// itself in a moment, false when that retry has been used up.
  final bool retrySoon;

  int get answered => sent + underReview + rejected + waiting;

  /// The run finished and there was nothing to send.
  bool get nothingToSend => stop == null && answered == 0 && unmatched == 0;

  @override
  String toString() =>
      'SyncReport(trigger: ${trigger.name}, sent: $sent, '
      'underReview: $underReview, '
      'rejected: $rejected, waiting: $waiting, unmatched: $unmatched, '
      'stop: ${stop?.name})';
}

/// Every send that ended since the user last looked at "Send my work"
/// (Transporter handoff T5b). Two saves in a row are two sends; showing only
/// the last one said "1 sent" for two bags, and an automatic "nothing to
/// send" hid a review message.
///
/// [combined] holds the totals: sent, under review and rejected are summed,
/// and every problem line is kept, because each send answered different
/// steps and those answers are final. What can still change (steps waiting,
/// unmatched answers, the stop, the time taken) comes from the newest send
/// only, because it says how things are now: a deferred step is sent again,
/// and would be counted twice if summed.
class SyncSummary {
  const SyncSummary._(this.sends, this.combined, {required this.sameTrigger});

  /// A summary of one send.
  SyncSummary.of(SyncReport report) : this._(1, report, sameTrigger: true);

  /// How many sends this summary holds; at least 1.
  final int sends;

  /// [SyncReport.startedAt] is the first send's start and
  /// [SyncReport.trigger] the first send's trigger.
  final SyncReport combined;

  /// Every send had the same trigger, so the heading may name it
  /// ("2 sends after you saved").
  final bool sameTrigger;

  /// [summary] with [newer] added. A send with nothing to send adds nothing,
  /// so it never hides a summary that holds something.
  static SyncSummary? add(SyncSummary? summary, SyncReport newer) {
    if (newer.nothingToSend) return summary;
    if (summary == null) return SyncSummary.of(newer);
    final old = summary.combined;
    return SyncSummary._(
      summary.sends + 1,
      SyncReport(
        startedAt: old.startedAt,
        trigger: old.trigger,
        elapsed: newer.elapsed,
        sent: old.sent + newer.sent,
        underReview: old.underReview + newer.underReview,
        rejected: old.rejected + newer.rejected,
        waiting: newer.waiting,
        unmatched: newer.unmatched,
        problems: [...old.problems, ...newer.problems],
        stop: newer.stop,
        message: newer.message,
        retrySoon: newer.retrySoon,
      ),
      sameTrigger: summary.sameTrigger && old.trigger == newer.trigger,
    );
  }

  /// The same summary without its stop: the session is usable again, so
  /// "Enter your password" or "You are signed out" is no longer true.
  SyncSummary withoutStop() => SyncSummary._(
    sends,
    SyncReport(
      startedAt: combined.startedAt,
      trigger: combined.trigger,
      elapsed: combined.elapsed,
      sent: combined.sent,
      underReview: combined.underReview,
      rejected: combined.rejected,
      waiting: combined.waiting,
      unmatched: combined.unmatched,
      problems: combined.problems,
    ),
    sameTrigger: sameTrigger,
  );

  @override
  String toString() =>
      'SyncSummary(sends: $sends, sameTrigger: $sameTrigger, $combined)';
}
