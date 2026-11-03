import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum FeedbackKind { success, error, warning, info }

extension on FeedbackKind {
  Color get color => switch (this) {
    FeedbackKind.success => const Color(0xFF17633D),
    FeedbackKind.error => const Color(0xFF9F242B),
    FeedbackKind.warning => const Color(0xFF755000),
    FeedbackKind.info => const Color(0xFF244F70),
  };

  IconData get icon => switch (this) {
    FeedbackKind.success => Icons.check_circle_outline,
    FeedbackKind.error => Icons.error_outline,
    FeedbackKind.warning => Icons.warning_amber_rounded,
    FeedbackKind.info => Icons.info_outline,
  };

  String get title => switch (this) {
    FeedbackKind.success => 'Completed',
    FeedbackKind.error => 'Action failed',
    FeedbackKind.warning => 'Check this',
    FeedbackKind.info => 'Information',
  };
}

class ActionFeedback extends SnackBar {
  static Future<bool> copy(
    BuildContext context,
    String text, {
    required String message,
  }) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) show(context, message, kind: FeedbackKind.success);
      return true;
    } catch (_) {
      if (context.mounted) {
        show(
          context,
          'Unable to copy to the clipboard. Try again.',
          kind: FeedbackKind.error,
        );
      }
      return false;
    }
  }

  ActionFeedback({
    super.key,
    required String message,
    FeedbackKind kind = FeedbackKind.info,
    String? title,
  }) : super(
         content: ActionStatus(message: message, kind: kind, title: title),
         backgroundColor: kind.color,
         behavior: SnackBarBehavior.floating,
         showCloseIcon: true,
         closeIconColor: Colors.white,
         duration: kind == FeedbackKind.error
             ? const Duration(days: 1)
             : const Duration(seconds: 8),
         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
       );

  static void show(
    BuildContext context,
    String message, {
    FeedbackKind kind = FeedbackKind.info,
    String? title,
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      ActionFeedback(message: message, kind: kind, title: title),
    );
  }
}

class ActionStatus extends StatelessWidget {
  const ActionStatus({
    super.key,
    required this.message,
    this.kind = FeedbackKind.info,
    this.title,
  });

  final String message;
  final FeedbackKind kind;
  final String? title;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: kind.color,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(kind.icon, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title ?? kind.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.4,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
