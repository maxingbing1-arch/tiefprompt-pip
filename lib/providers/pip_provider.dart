import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/prompter_provider.dart';
import 'package:tiefprompt/services/pip_channel.dart';

/// Tracks whether the PiP floating window is active.
final pipActiveProvider = StateProvider<bool>((ref) => false);

/// Toggle PiP on/off with current script and settings.
Future<void> togglePip(
  WidgetRef ref, {
  required String text,
  required double speed,
  required double fontSize,
  required bool isMirrored,
  double scrollOffset = 0,
}) async {
  final isActive = ref.read(pipActiveProvider);
  if (isActive) {
    await PipChannel.stop();
    ref.read(pipActiveProvider.notifier).state = false;
  } else {
    final supported = await PipChannel.isSupported;
    if (!supported) return;
    await PipChannel.start(
      text: text,
      speed: speed,
      fontSize: fontSize,
      isMirrored: isMirrored,
      scrollOffset: scrollOffset,
    );
    ref.read(pipActiveProvider.notifier).state = true;
  }
}

/// Sync current prompter settings to PiP (font size, mirror).
void syncPipSettings(WidgetRef ref) {
  if (!ref.read(pipActiveProvider)) return;
  final prompter = ref.read(prompterProvider);
  PipChannel.updateSettings(
    fontSize: prompter.fontSize,
    isMirrored: prompter.mirroredX,
  );
}

/// Sync scroll speed to PiP.
void syncPipSpeed(WidgetRef ref) {
  if (!ref.read(pipActiveProvider)) return;
  final prompter = ref.read(prompterProvider);
  PipChannel.updateSpeed(prompter.speed);
}
