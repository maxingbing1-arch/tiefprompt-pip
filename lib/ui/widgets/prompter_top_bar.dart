import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiefprompt/providers/pip_provider.dart';
import 'package:tiefprompt/providers/prompter_provider.dart';
import 'package:tiefprompt/providers/script_provider.dart';
import 'package:tiefprompt/services/pip_channel.dart';

class PrompterTopBar extends ConsumerWidget {
  const PrompterTopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final script = ref.watch(scriptProvider);
    final prompter = ref.watch(prompterProvider);
    final pipActive = ref.watch(pipActiveProvider);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
        padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 12.0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            IconButton(
              icon: Icon(Icons.close,
                  color: Theme.of(context).colorScheme.onSurface),
              onPressed: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: Text(
                script.title ?? context.tr("empty_title"),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 20,
                    color: Theme.of(context).colorScheme.onSurface),
              ),
            ),
            // PiP toggle — only renders on devices that support it.
            FutureBuilder<bool>(
              future: PipChannel.isSupported,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(
                    pipActive
                        ? Icons.picture_in_picture_alt
                        : Icons.picture_in_picture,
                    color: pipActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                  tooltip: pipActive ? 'Exit PiP' : 'Floating window (PiP)',
                  onPressed: () {
                    final text = script.text;
                    if (text.isEmpty) return;
                    togglePip(
                      ref,
                      text: text,
                      speed: prompter.speed,
                      fontSize: prompter.fontSize,
                      isMirrored: prompter.mirroredX,
                      scrollOffset: 0,
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
