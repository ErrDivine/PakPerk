import 'dart:convert';

import 'package:xml/xml.dart';

const _maximumMathMlBytes = 256 * 1024;
const _maximumMathMlNodes = 4096;
const _maximumMathMlDepth = 64;
const _maximumLatexScalars = 32000;

/// A deterministic rendering representation of trusted Presentation MathML.
///
/// [source] remains authoritative and must be retained for copy/export. The
/// derived LaTeX is only an input to the maintained on-device renderer.
final class RenderableMathMl {
  const RenderableMathMl({required this.latex, this.altText});

  final String latex;
  final String? altText;
}

/// Converts the parser's closed Presentation MathML subset to renderer input.
///
/// Unsupported or ambiguous markup returns `null`; callers must then show the
/// exact MathML source. This intentionally never repairs or guesses structure.
RenderableMathMl? renderableMathMl(String source) {
  if (source.isEmpty ||
      source.contains('\u0000') ||
      utf8.encode(source).length > _maximumMathMlBytes) {
    return null;
  }
  final upper = source.toUpperCase();
  if (source.contains('<?') ||
      upper.contains('<!DOCTYPE') ||
      upper.contains('<!ENTITY') ||
      upper.contains('<![CDATA[')) {
    return null;
  }
  try {
    final document = XmlDocument.parse(source);
    if (document.children.length != 1 ||
        document.rootElement.name.qualified != 'math') {
      return null;
    }
    final converter = _MathMlConverter();
    final latex = converter.convert(document.rootElement, depth: 1).trim();
    if (latex.isEmpty || latex.runes.length > _maximumLatexScalars) {
      return null;
    }
    final altText = converter.normalizedAttribute(
      document.rootElement,
      'alttext',
      maximumScalars: 1000,
    );
    return RenderableMathMl(latex: latex, altText: altText);
  } on Object {
    return null;
  }
}

final class _MathMlConverter {
  static const _allowedElements = <String>{
    'annotation',
    'math',
    'merror',
    'mfenced',
    'mfrac',
    'mi',
    'mmultiscripts',
    'mn',
    'mo',
    'mover',
    'mpadded',
    'mphantom',
    'mprescripts',
    'mroot',
    'mrow',
    'ms',
    'mspace',
    'msqrt',
    'mstyle',
    'msub',
    'msubsup',
    'msup',
    'mtable',
    'mtd',
    'mtext',
    'mtr',
    'munder',
    'munderover',
    'none',
    'semantics',
  };

  static const _allowedAttributes = <String>{
    'alttext',
    'columnalign',
    'columnspan',
    'display',
    'encoding',
    'fence',
    'linethickness',
    'mathvariant',
    'rowalign',
    'rowspan',
    'separator',
    'stretchy',
  };

  var _nodes = 0;

  String convert(XmlElement element, {required int depth}) {
    final name = _enter(element, depth);
    final value = switch (name) {
      'math' || 'mrow' || 'mpadded' => _container(element, depth),
      'mstyle' => _withMathVariant(element, _container(element, depth)),
      'mi' ||
      'mn' => _withMathVariant(element, _escapeMathToken(_tokenText(element))),
      'mo' => _withMathVariant(element, _operator(_tokenText(element))),
      'mtext' || 'ms' => _withMathVariant(
        element,
        '\\text{${_escapeLatexText(_tokenText(element))}}',
      ),
      'mfrac' => _fraction(element, depth),
      'msqrt' => '\\sqrt{${_container(element, depth)}}',
      'mroot' => _root(element, depth),
      'msub' => _script(element, depth, subscript: true),
      'msup' => _script(element, depth, subscript: false),
      'msubsup' => _subSup(element, depth),
      'munder' => _underOver(element, depth, under: true, over: false),
      'mover' => _underOver(element, depth, under: false, over: true),
      'munderover' => _underOver(element, depth, under: true, over: true),
      'mfenced' => _fenced(element, depth),
      'mphantom' => '\\phantom{${_container(element, depth)}}',
      'mspace' => _space(element),
      'mtable' => _table(element, depth),
      'mtr' || 'mtd' => _container(element, depth),
      'semantics' => _semantics(element, depth),
      'mmultiscripts' => _multiScripts(element, depth),
      'annotation' ||
      'merror' ||
      'mprescripts' ||
      'none' => throw const _UnsupportedMathMl(),
      _ => throw const _UnsupportedMathMl(),
    };
    if (value.runes.length > _maximumLatexScalars) {
      throw const _UnsupportedMathMl();
    }
    return value;
  }

  String _enter(XmlElement element, int depth) {
    if (depth > _maximumMathMlDepth || ++_nodes > _maximumMathMlNodes) {
      throw const _UnsupportedMathMl();
    }
    final name = element.name.qualified;
    if (element.name.prefix != null || !_allowedElements.contains(name)) {
      throw const _UnsupportedMathMl();
    }
    _validateAttributes(element);
    return name;
  }

  void _validateAttributes(XmlElement element) {
    for (final attribute in element.attributes) {
      final name = attribute.name.qualified;
      if (attribute.name.prefix != null ||
          !_allowedAttributes.contains(name) ||
          attribute.value.contains('\u0000') ||
          attribute.value.runes.length > 1000) {
        throw const _UnsupportedMathMl();
      }
    }
    final spanAttributes = <String>[
      if (_attribute(element, 'rowspan') case final value?) value,
      if (_attribute(element, 'columnspan') case final value?) value,
    ];
    if (spanAttributes.any((value) => value != '1')) {
      throw const _UnsupportedMathMl();
    }
  }

  String _container(XmlElement element, int depth) => _elementChildren(
    element,
  ).map((child) => convert(child, depth: depth + 1)).join();

  List<XmlElement> _elementChildren(XmlElement element) {
    final children = <XmlElement>[];
    for (final child in element.children) {
      if (child is XmlElement) {
        children.add(child);
      } else if (child is! XmlText || child.value.trim().isNotEmpty) {
        throw const _UnsupportedMathMl();
      }
    }
    return children;
  }

  String _tokenText(XmlElement element) {
    final buffer = StringBuffer();
    for (final child in element.children) {
      if (child is! XmlText || child is XmlCDATA) {
        throw const _UnsupportedMathMl();
      }
      buffer.write(child.value);
    }
    final value = _normalizeText(buffer.toString());
    if (value == null) throw const _UnsupportedMathMl();
    return value;
  }

  String _fraction(XmlElement element, int depth) {
    final children = _exactChildren(element, 2);
    final numerator = convert(children[0], depth: depth + 1);
    final denominator = convert(children[1], depth: depth + 1);
    final lineThickness = _attribute(element, 'linethickness');
    if (lineThickness == null ||
        lineThickness == '1' ||
        lineThickness == 'medium') {
      return '\\frac{$numerator}{$denominator}';
    }
    if (const {'0', '0px', '0pt'}.contains(lineThickness)) {
      return '\\genfrac{}{}{0pt}{}{$numerator}{$denominator}';
    }
    throw const _UnsupportedMathMl();
  }

  String _root(XmlElement element, int depth) {
    final children = _exactChildren(element, 2);
    final radicand = convert(children[0], depth: depth + 1);
    final index = convert(children[1], depth: depth + 1);
    return '\\sqrt[$index]{$radicand}';
  }

  String _script(XmlElement element, int depth, {required bool subscript}) {
    final children = _exactChildren(element, 2);
    final base = convert(children[0], depth: depth + 1);
    final script = convert(children[1], depth: depth + 1);
    return '{$base}${subscript ? '_' : '^'}{$script}';
  }

  String _subSup(XmlElement element, int depth) {
    final children = _exactChildren(element, 3);
    final base = convert(children[0], depth: depth + 1);
    final subscript = convert(children[1], depth: depth + 1);
    final superscript = convert(children[2], depth: depth + 1);
    return '{$base}_{$subscript}^{$superscript}';
  }

  String _underOver(
    XmlElement element,
    int depth, {
    required bool under,
    required bool over,
  }) {
    final expected = under && over ? 3 : 2;
    final children = _exactChildren(element, expected);
    var value = convert(children[0], depth: depth + 1);
    var index = 1;
    if (under) {
      final underValue = convert(children[index++], depth: depth + 1);
      value = '\\underset{$underValue}{$value}';
    }
    if (over) {
      final overValue = convert(children[index], depth: depth + 1);
      value = '\\overset{$overValue}{$value}';
    }
    return value;
  }

  String _fenced(XmlElement element, int depth) {
    final children = _elementChildren(element);
    if (children.isEmpty) throw const _UnsupportedMathMl();
    final rawSeparator = _attribute(element, 'separator') ?? ',';
    final separator = _normalizeText(rawSeparator);
    if (separator == null || separator.runes.length != 1) {
      throw const _UnsupportedMathMl();
    }
    return '\\left(${children.map((child) => convert(child, depth: depth + 1)).join(_operator(separator))}\\right)';
  }

  String _space(XmlElement element) {
    if (_elementChildren(element).isNotEmpty) {
      throw const _UnsupportedMathMl();
    }
    return r'\,';
  }

  String _table(XmlElement element, int depth) {
    final rows = _elementChildren(element);
    if (rows.isEmpty || rows.any((row) => row.name.qualified != 'mtr')) {
      throw const _UnsupportedMathMl();
    }
    int? width;
    final renderedRows = <String>[];
    for (final row in rows) {
      if (_enter(row, depth + 1) != 'mtr') {
        throw const _UnsupportedMathMl();
      }
      final cells = _elementChildren(row);
      if (cells.isEmpty || cells.any((cell) => cell.name.qualified != 'mtd')) {
        throw const _UnsupportedMathMl();
      }
      width ??= cells.length;
      if (cells.length != width) throw const _UnsupportedMathMl();
      renderedRows.add(
        cells
            .map((cell) {
              if (_enter(cell, depth + 2) != 'mtd') {
                throw const _UnsupportedMathMl();
              }
              return _container(cell, depth + 2);
            })
            .join(' & '),
      );
    }
    return '\\begin{matrix}${renderedRows.join(r' \\ ')}\\end{matrix}';
  }

  String _semantics(XmlElement element, int depth) {
    final children = _elementChildren(element);
    for (final annotation in children.where(
      (child) => child.name.qualified == 'annotation',
    )) {
      if (_enter(annotation, depth + 1) != 'annotation') {
        throw const _UnsupportedMathMl();
      }
      _tokenText(annotation);
    }
    final presentation = children.where(
      (child) => child.name.qualified != 'annotation',
    );
    if (presentation.length != 1) throw const _UnsupportedMathMl();
    return convert(presentation.single, depth: depth + 1);
  }

  String _multiScripts(XmlElement element, int depth) {
    final children = _elementChildren(element);
    if (children.length < 3) throw const _UnsupportedMathMl();
    final markerIndex = children.indexWhere(
      (child) => child.name.qualified == 'mprescripts',
    );
    if (children
            .where((child) => child.name.qualified == 'mprescripts')
            .length >
        1) {
      throw const _UnsupportedMathMl();
    }
    final postEnd = markerIndex < 0 ? children.length : markerIndex;
    if ((postEnd - 1).isOdd ||
        markerIndex == children.length - 1 ||
        markerIndex >= 0 && (children.length - markerIndex - 1).isOdd) {
      throw const _UnsupportedMathMl();
    }
    var value = convert(children.first, depth: depth + 1);
    for (var index = 1; index < postEnd; index += 2) {
      value =
          '$value${_scriptPair(children[index], children[index + 1], depth)}';
    }
    if (markerIndex >= 0) {
      final marker = children[markerIndex];
      if (_enter(marker, depth + 1) != 'mprescripts' ||
          _elementChildren(marker).isNotEmpty) {
        throw const _UnsupportedMathMl();
      }
      final prefixes = <String>[];
      for (var index = markerIndex + 1; index < children.length; index += 2) {
        prefixes.add(
          _scriptPair(
            children[index],
            children[index + 1],
            depth,
            emptyBase: true,
          ),
        );
      }
      value = '${prefixes.join()}$value';
    }
    return value;
  }

  String _scriptPair(
    XmlElement subscript,
    XmlElement superscript,
    int depth, {
    bool emptyBase = false,
  }) {
    final sub = _optionalScript(subscript, depth);
    final sup = _optionalScript(superscript, depth);
    if (sub == null && sup == null) return emptyBase ? '{}' : '';
    return '${emptyBase ? '{}' : ''}${sub == null ? '' : '_{$sub}'}${sup == null ? '' : '^{$sup}'}';
  }

  String? _optionalScript(XmlElement element, int depth) =>
      element.name.qualified == 'none'
      ? _emptyScript(element, depth)
      : convert(element, depth: depth + 1);

  String? _emptyScript(XmlElement element, int depth) {
    if (_enter(element, depth + 1) != 'none' ||
        _elementChildren(element).isNotEmpty) {
      throw const _UnsupportedMathMl();
    }
    return null;
  }

  List<XmlElement> _exactChildren(XmlElement element, int count) {
    final children = _elementChildren(element);
    if (children.length != count) throw const _UnsupportedMathMl();
    return children;
  }

  String _withMathVariant(XmlElement element, String value) {
    final variant = _attribute(element, 'mathvariant');
    if (variant == null || variant == 'normal') return value;
    final command = switch (variant) {
      'bold' => 'mathbf',
      'italic' => 'mathit',
      'bold-italic' => 'boldsymbol',
      'double-struck' => 'mathbb',
      'fraktur' => 'mathfrak',
      'script' => 'mathcal',
      'monospace' => 'mathtt',
      'sans-serif' => 'mathsf',
      _ => throw const _UnsupportedMathMl(),
    };
    return '\\$command{$value}';
  }

  String? normalizedAttribute(
    XmlElement element,
    String name, {
    required int maximumScalars,
  }) {
    final raw = _attribute(element, name);
    if (raw == null) return null;
    final value = _normalizeText(raw);
    if (value == null ||
        value.runes.length > maximumScalars ||
        value.runes.any(_isUnsafeControl)) {
      return null;
    }
    return value;
  }

  String? _attribute(XmlElement element, String name) {
    for (final attribute in element.attributes) {
      if (attribute.name.qualified == name) return attribute.value;
    }
    return null;
  }
}

String _operator(String value) => switch (value) {
  '−' => '-',
  '±' => r'\pm ',
  '∓' => r'\mp ',
  '×' => r'\times ',
  '÷' => r'\div ',
  '⋅' || '·' => r'\cdot ',
  '≤' => r'\le ',
  '≥' => r'\ge ',
  '≠' => r'\ne ',
  '≈' => r'\approx ',
  '∞' => r'\infty ',
  '∑' => r'\sum ',
  '∏' => r'\prod ',
  '∫' => r'\int ',
  '∂' => r'\partial ',
  '∇' => r'\nabla ',
  '→' => r'\to ',
  '←' => r'\leftarrow ',
  '↔' => r'\leftrightarrow ',
  '⇒' => r'\Rightarrow ',
  '⇐' => r'\Leftarrow ',
  '⇔' => r'\Leftrightarrow ',
  '∈' => r'\in ',
  '∉' => r'\notin ',
  '⊂' => r'\subset ',
  '⊆' => r'\subseteq ',
  '⊃' => r'\supset ',
  '⊇' => r'\supseteq ',
  '∩' => r'\cap ',
  '∪' => r'\cup ',
  '∧' => r'\land ',
  '∨' => r'\lor ',
  '¬' => r'\neg ',
  '\u2061' || '\u2062' || '\u2063' => r'\,',
  _ => _escapeMathToken(value),
};

String _escapeMathToken(String value) {
  final output = StringBuffer();
  for (final rune in value.runes) {
    if (_isUnsafeControl(rune)) throw const _UnsupportedMathMl();
    output.write(switch (String.fromCharCode(rune)) {
      '\\' => r'\backslash{}',
      '#' => r'\#',
      r'$' => r'\$',
      '%' => r'\%',
      '&' => r'\&',
      '_' => r'\_',
      '{' => r'\{',
      '}' => r'\}',
      '^' => r'\wedge ',
      '~' => r'\sim ',
      final character => character,
    });
  }
  return output.toString();
}

String _escapeLatexText(String value) {
  final output = StringBuffer();
  for (final rune in value.runes) {
    if (_isUnsafeControl(rune)) throw const _UnsupportedMathMl();
    output.write(switch (String.fromCharCode(rune)) {
      '\\' => r'\textbackslash{}',
      '#' => r'\#',
      r'$' => r'\$',
      '%' => r'\%',
      '&' => r'\&',
      '_' => r'\_',
      '{' => r'\{',
      '}' => r'\}',
      '^' => r'\textasciicircum{}',
      '~' => r'\textasciitilde{}',
      final character => character,
    });
  }
  return output.toString();
}

String? _normalizeText(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.contains('\u0000')) return null;
  return normalized;
}

bool _isUnsafeControl(int rune) =>
    rune < 0x20 ||
    rune == 0x7f ||
    rune >= 0x200b && rune <= 0x200f ||
    rune >= 0x202a && rune <= 0x202e ||
    rune == 0x2060 ||
    rune >= 0x2064 && rune <= 0x206f;

final class _UnsupportedMathMl implements Exception {
  const _UnsupportedMathMl();
}
