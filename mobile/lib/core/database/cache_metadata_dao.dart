import 'app_database.dart';

class CacheMetadataDao {
  CacheMetadataDao(this.database);

  final PakPerkDatabase database;

  Future<Object?> read(String key) => database.readMetadata(key);

  Future<void> put(String key, Object? value, {DateTime? updatedAt}) =>
      database.putMetadata(key, value, updatedAt: updatedAt);

  Future<void> remove(String key) async {
    await (database.delete(
      database.cacheMetadata,
    )..where((table) => table.key.equals(key))).go();
  }
}
