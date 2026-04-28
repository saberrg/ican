import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppLogService {
  AppLogService._();

  static final AppLogService instance = AppLogService._();

  static const int _maxEntries = 400;
  static const String _prefsKey = 'app_log.entries';
  static const MethodChannel _channel = MethodChannel('com.ican/app_log');

  final List<String> _entries = <String>[];
  Future<void> _writeChain = Future<void>.value();
  bool _initialized = false;
  bool _hookInstalled = false;
  DebugPrintCallback? _previousDebugPrint;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _entries
        ..clear()
        ..addAll(prefs.getStringList(_prefsKey) ?? const <String>[]);
      _trimEntries();
    } catch (_) {
      _entries.clear();
    }
  }

  void installDebugPrintHook() {
    if (_hookInstalled) return;
    _hookInstalled = true;
    _previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
      if (message == null || message.trim().isEmpty) return;
      unawaited(record(message, source: 'debugPrint'));
    };
  }

  Future<void> record(String message, {String source = 'app'}) {
    final sanitized = _sanitize(message);
    if (sanitized.trim().isEmpty) return Future<void>.value();
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final line = '$timestamp [$source] $sanitized';
    _entries.add(line);
    _trimEntries();
    unawaited(_sendToNative(line));
    _writeChain = _writeChain.then((_) => _persist()).catchError((_) {});
    return _writeChain;
  }

  Future<List<String>> recentEntries() async {
    await init();
    return List<String>.unmodifiable(_entries);
  }

  Future<String> exportText() async {
    final entries = await recentEntries();
    return entries.join('\n');
  }

  @visibleForTesting
  void resetForTesting() {
    _entries.clear();
    _writeChain = Future<void>.value();
    _initialized = false;
  }

  void _trimEntries() {
    if (_entries.length <= _maxEntries) return;
    _entries.removeRange(0, _entries.length - _maxEntries);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, List<String>.from(_entries));
  }

  Future<void> _sendToNative(String line) async {
    try {
      await _channel.invokeMethod<void>('log', <String, Object?>{
        'message': line,
      });
    } catch (_) {
      // Native logging is best-effort. The local ring buffer remains available.
    }
  }

  static String _sanitize(String message) {
    var sanitized = message;
    final patterns = <RegExp>[
      RegExp(r'(API_KEY\s*[=:]\s*)[^\s,;]+', caseSensitive: false),
      RegExp(r'(x-goog-api-key\s*[=:]\s*)[^\s,;]+', caseSensitive: false),
      RegExp(r'(Authorization\s*:\s*Bearer\s+)[^\s,;]+', caseSensitive: false),
      RegExp(r'(key=)[A-Za-z0-9_\-]{20,}', caseSensitive: false),
      RegExp(r'(AIza)[0-9A-Za-z_\-]{20,}'),
    ];
    for (final pattern in patterns) {
      sanitized = sanitized.replaceAllMapped(
        pattern,
        (match) => '${match.group(1) ?? ''}<redacted>',
      );
    }
    if (sanitized.length <= 1200) return sanitized;
    return '${sanitized.substring(0, 1200)}...';
  }
}
