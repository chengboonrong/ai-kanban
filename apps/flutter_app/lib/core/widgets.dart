import 'package:flutter/material.dart';

import 'api.dart';

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
  int? maxLength,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(
    title: title,
    initial: initial,
    action: action,
    maxLength: maxLength,
  ),
);

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.action,
    this.maxLength,
  });
  final String title, initial, action;
  final int? maxLength;

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
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      onSubmitted: (_) => _submit(),
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
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
