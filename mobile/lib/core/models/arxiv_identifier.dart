class ArxivIdentifier {
  const ArxivIdentifier._({required this.baseId, required this.version});

  static final RegExp _syntax = RegExp(
    r'^(?:(\d{4}\.\d{4,5})|([A-Za-z][A-Za-z0-9.-]*/\d{7}))'
    r'(?:v(\d+))?$',
  );

  final String baseId;
  final int? version;

  String get queryId => version == null ? baseId : '${baseId}v$version';
  String get encodedRouteSegment => Uri.encodeComponent(queryId);
  Uri get canonicalAbsUri => _canonicalUri('abs');
  Uri get canonicalPdfUri => _canonicalUri('pdf');

  Uri _canonicalUri(String resource) {
    return Uri(
      scheme: 'https',
      host: 'arxiv.org',
      pathSegments: [resource, ...queryId.split('/')],
    );
  }

  static ArxivIdentifier? tryParse(String value) {
    if (value.isEmpty || value.length > 64 || value != value.trim()) {
      return null;
    }
    final match = _syntax.firstMatch(value);
    if (match == null) return null;
    final rawBase = match.group(1) ?? match.group(2);
    if (rawBase == null) return null;
    final rawVersion = match.group(3);
    final version = rawVersion == null ? null : int.tryParse(rawVersion);
    if (rawVersion != null &&
        (version == null || version == 0 || version > 0xffffffff)) {
      return null;
    }
    return ArxivIdentifier._(baseId: rawBase, version: version);
  }
}
