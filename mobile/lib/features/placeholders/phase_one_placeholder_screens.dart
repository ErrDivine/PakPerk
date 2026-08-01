import 'package:flutter/material.dart';

class PhaseOnePlaceholderScreen extends StatelessWidget {
  const PhaseOnePlaceholderScreen({
    required this.title,
    required this.message,
    required this.icon,
    this.onClose,
    this.closeTooltip = 'Back',
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: onClose == null
            ? null
            : IconButton(
                tooltip: closeTooltip,
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 52),
                  const SizedBox(height: 18),
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
