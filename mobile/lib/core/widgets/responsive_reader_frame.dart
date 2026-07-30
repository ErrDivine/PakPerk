import 'package:flutter/material.dart';

/// Keeps the phone-first reader readable on tablets and desktop-sized windows.
class ResponsiveReaderFrame extends StatelessWidget {
  const ResponsiveReaderFrame({
    required this.child,
    this.maxWidth = 840,
    super.key,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox.expand(child: child),
      ),
    );
  }
}
