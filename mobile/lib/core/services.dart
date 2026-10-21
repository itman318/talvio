import 'api_client.dart';
import 'media_cache.dart';
import 'push_service.dart';
import 'socket_service.dart';

/// Long-lived singletons shared through Provider.
class AppServices {
  AppServices()
      : api = ApiClient() {
    socket = SocketService(api);
    media = MediaCache(api);
    push = PushService(api);
    api.onTokenRefreshed = socket.updateToken;
  }

  final ApiClient api;
  late final SocketService socket;
  late final MediaCache media;
  late final PushService push;
}
