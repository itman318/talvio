import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Pictures that never change at their address (profile photos, stickers) are kept on the device,
/// so chat lists and sticker packs show them at once instead of downloading them again on every start.
/// A JSON index works on every platform (phones and desktop alike).
final CacheManager imageStore = CacheManager(Config(
  'hush_images',
  stalePeriod: const Duration(days: 60),
  maxNrOfCacheObjects: 3000,
  repo: JsonCacheInfoRepository(databaseName: 'hush_images'),
));
