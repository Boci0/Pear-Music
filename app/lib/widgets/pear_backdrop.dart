import 'package:flutter/material.dart';

/// The room behind every route: the flat graphite canvas colour.
///
/// Screens keep a transparent Scaffold background (see [PlayerTheme]) so
/// this shows through, and it lives behind everything via
/// `MaterialApp.builder`.
class PearBackdrop extends StatelessWidget {
  const PearBackdrop({super.key});

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface);
}
