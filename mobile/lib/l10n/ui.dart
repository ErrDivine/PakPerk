import 'package:flutter/material.dart';
import 'zh.dart';

String uiString(BuildContext context, String value) =>
    Localizations.localeOf(context).languageCode == 'zh'
    ? chineseUi(value)
    : value;

String? uiStringOrNull(BuildContext context, String? value) =>
    value == null ? null : uiString(context, value);

/// Only UI copy uses this widget. Source paper text and user content use Text.
class UiText extends Text {
  const UiText(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.semanticsIdentifier,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.selectionColor,
  });
  @override
  Widget build(BuildContext context) {
    final translated = uiString(context, data!);
    return Text(
      translated,
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel == null
          ? null
          : uiString(context, semanticsLabel!),
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    ).build(context);
  }
}
