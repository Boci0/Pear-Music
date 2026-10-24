import 'package:flutter/material.dart';

import '../theme/glass.dart';

/// The redesign's empty screen: an icon in a Graphite panel, a title in
/// spaced capitals, one line of help and an optional action.
class PearEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  /// Button label; no button unless both this and [onAction] are given.
  final String? actionLabel;
  final VoidCallback? onAction;

  const PearEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                color: PearGlassTokens.angularPanel,
                shape: PearGlassTokens.angularShape(),
              ),
              child: SizedBox(
                width: 72,
                height: 72,
                child: Icon(icon, size: 32, color: primary),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: primary,
                  side: BorderSide(color: primary.withValues(alpha: 0.6)),
                  shape: const RoundedRectangleBorder(
                  ),
                ),
                child: Text(
                  actionLabel!.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
