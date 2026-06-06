import 'package:flutter/services.dart';

/// Method channel wrapper for iOS Picture-in-Picture (PiP) teleprompter.
class PipChannel {
  PipChannel._();

  static const _channel = MethodChannel('tiefprompt/pip');

  /// Whether PiP is available on this device (iOS 15.0+ required).
  static Future<bool> get isSupported async =>
      (_channel.invokeMethod<bool>('isSupported')) ?? false;

  /// Whether the PiP window is currently active.
  static Future<bool> get isActive async =>
      (_channel.invokeMethod<bool>('isActive')) ?? false;

  /// Start PiP with the given script text and settings.
  static Future<void> start({
    required String text,
    required double speed,
    required double fontSize,
    required bool isMirrored,
    double scrollOffset = 0,
  }) =>
      _channel.invokeMethod('startPip', {
        'text': text,
        'speed': speed,
        'fontSize': fontSize,
        'isMirrored': isMirrored,
        'scrollOffset': scrollOffset,
      });

  /// Stop PiP and dismiss the floating window.
  static Future<void> stop() => _channel.invokeMethod('stopPip');

  /// Update scroll speed while PiP is running.
  static Future<void> updateSpeed(double speed) =>
      _channel.invokeMethod('updateSpeed', {'speed': speed});

  /// Update font size and/or mirror mode while PiP is running.
  static Future<void> updateSettings({
    double? fontSize,
    bool? isMirrored,
  }) =>
      _channel.invokeMethod('updateSettings', {
        if (fontSize != null) 'fontSize': fontSize,
        if (isMirrored != null) 'isMirrored': isMirrored,
      });

  /// Seek to a scroll offset (0..1000 proportional range).
  static Future<void> seekTo(double scrollOffset) =>
      _channel.invokeMethod('seekTo', {'scrollOffset': scrollOffset});
}
