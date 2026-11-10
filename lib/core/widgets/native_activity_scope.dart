import 'package:flutter/widgets.dart';

/// Identifies the current Android activity hosting the retained Flutter engine.
class NativeActivityScope extends InheritedWidget {
  const NativeActivityScope({
    super.key,
    required this.generation,
    required super.child,
  });

  final int generation;

  static int generationOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NativeActivityScope>()
          ?.generation ??
      0;

  @override
  bool updateShouldNotify(NativeActivityScope oldWidget) =>
      generation != oldWidget.generation;
}
