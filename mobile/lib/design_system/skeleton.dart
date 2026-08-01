import 'package:flutter/material.dart';

/// Theme roles for cache-miss placeholders.
///
/// A skeleton is intentionally a theme extension instead of a one-off widget:
/// later cache surfaces can share accessible light/dark values without
/// introducing another palette or replacing valid stale content with loading
/// chrome.
@immutable
class PakPerkSkeletonTheme extends ThemeExtension<PakPerkSkeletonTheme> {
  const PakPerkSkeletonTheme({required this.base, required this.highlight});

  static const light = PakPerkSkeletonTheme(
    base: Color(0xFFE5DFD3),
    highlight: Color(0xFFF2EEE5),
  );

  static const dark = PakPerkSkeletonTheme(
    base: Color(0xFF354139),
    highlight: Color(0xFF465249),
  );

  final Color base;
  final Color highlight;

  @override
  PakPerkSkeletonTheme copyWith({Color? base, Color? highlight}) {
    return PakPerkSkeletonTheme(
      base: base ?? this.base,
      highlight: highlight ?? this.highlight,
    );
  }

  @override
  PakPerkSkeletonTheme lerp(
    covariant ThemeExtension<PakPerkSkeletonTheme>? other,
    double t,
  ) {
    if (other is! PakPerkSkeletonTheme) return this;
    return PakPerkSkeletonTheme(
      base: Color.lerp(base, other.base, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
    );
  }
}

/// Accessible paper-shaped placeholder used only when no cached abstract can
/// be rendered. It deliberately has one live-region announcement and excludes
/// its decorative blocks from the semantics tree.
class PaperCardSkeleton extends StatelessWidget {
  const PaperCardSkeleton({super.key});

  static const semanticsLabel = 'Loading the paper feed';

  @override
  Widget build(BuildContext context) {
    final colors =
        Theme.of(context).extension<PakPerkSkeletonTheme>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? PakPerkSkeletonTheme.dark
            : PakPerkSkeletonTheme.light);
    final decoration = BoxDecoration(
      gradient: LinearGradient(
        colors: [colors.base, colors.highlight, colors.base],
      ),
      borderRadius: BorderRadius.circular(8),
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _SkeletonBlock(
                width: 88,
                height: 24,
                decoration: decoration,
              ),
            ),
            const SizedBox(height: 32),
            _SkeletonLine(widthFactor: .92, height: 28, decoration: decoration),
            const SizedBox(height: 12),
            _SkeletonLine(widthFactor: .72, height: 28, decoration: decoration),
            const SizedBox(height: 20),
            _SkeletonLine(widthFactor: .48, height: 16, decoration: decoration),
            const SizedBox(height: 36),
            for (final width in const [.98, .94, .96, .81, .89]) ...[
              _SkeletonLine(
                widthFactor: width,
                height: 17,
                decoration: decoration,
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 28),
            Row(
              children: [
                for (var index = 0; index < 3; index += 1) ...[
                  if (index > 0) const SizedBox(width: 12),
                  Expanded(
                    child: _SkeletonBlock(height: 48, decoration: decoration),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({
    required this.widthFactor,
    required this.height,
    required this.decoration,
  });

  final double widthFactor;
  final double height;
  final Decoration decoration;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    alignment: Alignment.centerLeft,
    widthFactor: widthFactor,
    child: _SkeletonBlock(height: height, decoration: decoration),
  );
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    this.width,
    required this.height,
    required this.decoration,
  });

  final double? width;
  final double height;
  final Decoration decoration;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(decoration: decoration),
  );
}
