import 'package:flutter/foundation.dart';

enum AppEnvironment { dev, prod }

class Environment {
  static const AppEnvironment active = AppEnvironment.prod;

  // URL del servidor de desarrollo (Local). Mapeada al puerto 8085 según la configuración de Fortinet y Docker Compose.
  static const String devBaseUrl = 'http://181.79.25.235:8085';

  // URL del servidor de producción.
  static const String prodBaseUrl = 'http://181.79.25.235:8085';

  static String get apiUrl {
    if (kIsWeb) {
      final uri = Uri.base;
      if (uri.host == 'localhost' || uri.host == '127.0.0.1') {
        return 'http://${uri.host}:8085';
      }
      return '${uri.scheme}://${uri.host}:8085';
    }
    switch (active) {
      case AppEnvironment.dev:
        return devBaseUrl;
      case AppEnvironment.prod:
        return prodBaseUrl;
    }
  }
}
