import '../models/arxiv_identifier.dart';

enum PaperInputKind { arxivId, arxivUrl, title }

enum PaperInputError { empty, invalidIdentifier, unsupportedUrl, invalidTitle }

class PaperInputException implements FormatException {
  const PaperInputException(this.reason, this.message, [this.source]);

  final PaperInputError reason;

  @override
  final String message;

  @override
  final Object? source;

  @override
  int? get offset => null;

  @override
  String toString() => 'PaperInputException: $message';
}

class ClassifiedPaperInput {
  const ClassifiedPaperInput._({
    required this.kind,
    required this.normalizedValue,
    this.identifier,
  });

  final PaperInputKind kind;
  final String normalizedValue;
  final ArxivIdentifier? identifier;

  bool get isExact => identifier != null;

  static ClassifiedPaperInput exact({
    required PaperInputKind kind,
    required ArxivIdentifier identifier,
  }) => ClassifiedPaperInput._(
    kind: kind,
    normalizedValue: identifier.queryId,
    identifier: identifier,
  );

  static ClassifiedPaperInput title(String value) => ClassifiedPaperInput._(
    kind: PaperInputKind.title,
    normalizedValue: value,
  );
}

/// Classifies add-paper input without performing network I/O.
///
/// URL-shaped values fail closed unless they are one of the explicitly
/// accepted canonical HTTPS arXiv forms. All other non-ID text becomes a
/// bounded title query; it is never interpreted as an outbound URL.
class PaperInputClassifier {
  const PaperInputClassifier();

  static const int minimumTitleCharacters = 3;
  static const int maximumTitleCharacters = 300;

  ClassifiedPaperInput classify(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const PaperInputException(
        PaperInputError.empty,
        'Enter an arXiv link, arXiv identifier, or paper title.',
      );
    }

    if (_looksLikeUrl(trimmed)) return _classifyUrl(trimmed);

    final identifier = _parseBareIdentifier(trimmed);
    if (identifier != null) {
      return ClassifiedPaperInput.exact(
        kind: PaperInputKind.arxivId,
        identifier: identifier,
      );
    }
    if (_looksLikeMalformedArxivIdentifier(trimmed)) {
      throw PaperInputException(
        PaperInputError.invalidIdentifier,
        'That arXiv identifier is not valid.',
        input,
      );
    }

    final title = _normalizeTitle(trimmed);
    final length = title.runes.length;
    if (length < minimumTitleCharacters ||
        length > maximumTitleCharacters ||
        _containsDisallowedControl(title)) {
      throw PaperInputException(
        PaperInputError.invalidTitle,
        'Paper titles must contain 3 to 300 characters.',
        input,
      );
    }
    return ClassifiedPaperInput.title(title);
  }

  ClassifiedPaperInput _classifyUrl(String value) {
    if (value.contains('%') || value.contains(r'\')) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'Paste a canonical HTTPS arXiv abstract or PDF link.',
        value,
      );
    }

    final uri = Uri.tryParse(value);
    final validAuthority =
        uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'arxiv.org' &&
        uri.userInfo.isEmpty &&
        !uri.hasPort &&
        !uri.hasQuery &&
        !uri.hasFragment;
    if (!validAuthority) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'Paste a canonical HTTPS arXiv abstract or PDF link.',
        value,
      );
    }

    final segments = uri.pathSegments;
    if (segments.length < 2 ||
        (segments.first != 'abs' && segments.first != 'pdf')) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'Paste a canonical HTTPS arXiv abstract or PDF link.',
        value,
      );
    }
    final identifierSegments = segments.skip(1).toList(growable: false);
    if (identifierSegments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'Paste a canonical HTTPS arXiv abstract or PDF link.',
        value,
      );
    }
    var candidate = identifierSegments.join('/');
    if (segments.first == 'pdf' && candidate.endsWith('.pdf')) {
      candidate = candidate.substring(0, candidate.length - 4);
    } else if (segments.first == 'abs' && candidate.endsWith('.pdf')) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'Paste a canonical HTTPS arXiv abstract or PDF link.',
        value,
      );
    }
    final identifier = ArxivIdentifier.tryParse(candidate);
    if (identifier == null) {
      throw PaperInputException(
        PaperInputError.unsupportedUrl,
        'That arXiv link does not contain a supported paper identifier.',
        value,
      );
    }
    return ClassifiedPaperInput.exact(
      kind: PaperInputKind.arxivUrl,
      identifier: identifier,
    );
  }

  ArxivIdentifier? _parseBareIdentifier(String value) {
    final candidate = value.toLowerCase().startsWith('arxiv:')
        ? value.substring(6)
        : value;
    return ArxivIdentifier.tryParse(candidate);
  }

  bool _looksLikeUrl(String value) {
    if (value.contains('://')) return true;
    final lower = value.toLowerCase();
    return lower.startsWith('www.') ||
        lower.startsWith('arxiv.org/') ||
        lower.startsWith('export.arxiv.org/');
  }

  bool _looksLikeMalformedArxivIdentifier(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('arxiv:') ||
        RegExp(r'^\d{4}\.\S+$').hasMatch(value) ||
        RegExp(r'^[A-Za-z][A-Za-z0-9.-]*/\S+$').hasMatch(value);
  }

  String _normalizeTitle(String value) =>
      value.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');

  bool _containsDisallowedControl(String value) => value.runes.any(
    (scalar) =>
        (scalar < 0x20 && scalar != 0x09 && scalar != 0x0a && scalar != 0x0d) ||
        scalar == 0x7f,
  );
}
