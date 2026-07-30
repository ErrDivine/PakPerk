class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.retryable = false,
    this.statusCode,
    this.isOffline = false,
  });

  final String code;
  final String message;
  final bool retryable;
  final int? statusCode;
  final bool isOffline;

  bool get capabilityNotReady =>
      code == 'CAPABILITY_NOT_READY' || statusCode == 409;

  bool get cancelled => code == 'REQUEST_CANCELLED';

  bool get fulltextPolicyDenied => code == 'FULLTEXT_POLICY_DENIED';

  bool get permitsDerivedFallback =>
      !fulltextPolicyDenied &&
      (isOffline || (statusCode != null && statusCode! >= 500));

  @override
  String toString() => 'ApiException($code): $message';
}
