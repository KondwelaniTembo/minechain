// Small values kept between uses in the local database's `settings` table
// (plan §2), for example the last mineral chosen, so the registration screen
// can preselect it (plan Q5: "the mineral, skipped when remembered").
//
// Nothing secret goes here; keys live in the secure store. As everywhere,
// values are bound with `?`, never joined into SQL.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local_database.dart';

/// The settings' names, in one place.
abstract final class SettingKeys {
  static const String lastMineral = 'last_mineral';
}

class LocalSettings {
  LocalSettings(this._db);

  final LocalDatabase _db;

  /// The value saved under [key], or null. A read that fails counts as "no
  /// value": a lost preference must never stop the screen.
  Future<String?> read(String key) async {
    try {
      return await _db.run((db) => _read(db, key));
    } on SqliteException {
      return null;
    }
  }

  /// Saves [value] under [key]. A failure is ignored for the same reason.
  Future<void> write(String key, String value) async {
    try {
      await _db.run((db) => _write(db, key, value));
    } on SqliteException {
      // Only a convenience: the next screen simply preselects nothing.
    }
  }
}

String? _read(Database db, String key) {
  final rows = db.select('SELECT value FROM settings WHERE key = ?', [key]);
  return rows.isEmpty ? null : rows.first['value'] as String;
}

void _write(Database db, String key, String value) {
  db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );
}

final localSettingsProvider = FutureProvider<LocalSettings>((ref) async {
  return LocalSettings(await ref.watch(localDatabaseProvider.future));
});
