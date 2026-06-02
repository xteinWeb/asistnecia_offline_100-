import 'package:go_router/go_router.dart';
import '../../presentation/pages/splash/splash_page.dart';
import '../../presentation/pages/asistencia/asistencia_page.dart';

class AppRoutes {
  AppRoutes._();

  static const String splash = '/';
  static const String asistencia = '/asistencia';
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.splash,
  routes: [
    GoRoute(
      path: AppRoutes.splash,
      builder: (context, state) => const SplashPage(),
    ),
    GoRoute(
      path: AppRoutes.asistencia,
      builder: (context, state) => const AsistenciaPage(),
    ),
  ],
);
