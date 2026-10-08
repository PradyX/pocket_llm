import 'package:flutter/material.dart';

/// Asks whether a conversation and its messages should be removed.
///
/// Shared by the conversation list and the chat header, which offer the same
/// destructive action. One wording in one place keeps the two from drifting
/// apart about what is about to be deleted, and closing the dialog any other
/// way than confirming counts as a refusal.
Future<bool> confirmDeleteConversation(
  BuildContext context,
  String title,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete conversation?'),
      content: Text(
        '"$title" and its messages will be removed from this device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
