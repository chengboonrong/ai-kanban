import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

/// The draft's header block: mono lines between a 2px ink rule above and a 1px ink rule below,
/// stating what the screen holds.
class HeaderBlock extends StatelessWidget {
  const HeaderBlock({super.key, required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = t.mono(
      Theme.of(context).textTheme.bodyMedium!
          .copyWith(fontSize: 14, height: 1.7),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: t.headRule, bottom: t.inkRule),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final l in lines) Text(l, style: style)],
        ),
      ),
    );
  }
}

/// Runs [action], showing any failure as a SnackBar.
Future<void> runWithFeedback(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorMessage(e))));
    }
  }
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String action = 'Save',
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(title: title, initial: initial, action: action),
);

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.action,
  });
  final String title, initial, action;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  void _submit() => Navigator.pop(
    context,
    _controller.text.trim().isEmpty ? null : _controller.text.trim(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.action)),
    ],
  );
}

Future<bool> confirm(
  BuildContext context,
  String message, {
  String action = 'Delete',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        final t = context.tokens;
        return AlertDialog(
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(message),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            // Every confirm guards a destructive step: the fill is danger, the one red a confirm may carry.
            FilledButton(
              style:
                  FilledButton.styleFrom(
                    backgroundColor: t.danger,
                    foregroundColor: t.paper2,
                  ).copyWith(
                    side: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.focused)
                          ? BorderSide(color: t.ink, width: 2)
                          : BorderSide(color: t.danger),
                    ),
                  ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        );
      },
    ) ??
    false;
