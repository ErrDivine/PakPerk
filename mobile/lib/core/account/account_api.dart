import 'package:dio/dio.dart';

import '../api/api_error_mapper.dart';
import '../api/api_exception.dart';
import '../api/auth_interceptor.dart';
import 'account_profile.dart';

final class AccountApiResult {
  const AccountApiResult({required this.profile, required this.etag});

  final AccountProfile profile;
  final String etag;
}

final class AccountApi {
  const AccountApi(this._dio);

  final Dio _dio;

  Future<AccountApiResult> getCurrent() async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/me',
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.safe,
        ),
      );
      return _decode(response);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw const ApiException(
        code: 'INVALID_API_RESPONSE',
        message: 'The account service returned an invalid profile.',
        retryable: true,
        statusCode: 502,
      );
    }
  }

  Future<AccountApiResult> update({
    required int expectedProfileVersion,
    required AccountProfilePatch patch,
  }) async {
    if (expectedProfileVersion <= 0 || patch.isEmpty) {
      throw ArgumentError(
        'A profile version and at least one field are required.',
      );
    }
    try {
      final response = await _dio.patch<Object?>(
        '/v1/me',
        data: patch.toJson(),
        options: pakPerkRequestOptions(
          auth: RequestAuthPolicy.required,
          retry: AuthRetryPolicy.idempotencyProtected,
          headers: {'If-Match': '"profile-$expectedProfileVersion"'},
        ),
      );
      return _decode(response);
    } on DioException catch (error) {
      throw mapDioException(error);
    } on FormatException {
      throw const ApiException(
        code: 'INVALID_API_RESPONSE',
        message: 'The account service returned an invalid profile.',
        retryable: true,
        statusCode: 502,
      );
    }
  }

  AccountApiResult _decode(Response<Object?> response) {
    final root = response.data;
    if (root is! Map) {
      throw const FormatException('Expected account JSON.');
    }
    final account = root['account'];
    if (account is! Map) {
      throw const FormatException('Expected account payload.');
    }
    final profile = AccountProfile.fromJson(Map<String, dynamic>.from(account));
    final etags = response.headers['etag'];
    final etag = switch (etags) {
      [final value] when value == '"profile-${profile.profileVersion}"' =>
        value,
      _ => throw const FormatException('Invalid profile ETag.'),
    };
    return AccountApiResult(profile: profile, etag: etag);
  }
}
