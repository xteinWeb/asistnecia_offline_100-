import '../../core/constants/app_constants.dart';
import '../../core/utils/face_matcher.dart';
import '../../core/utils/horario_validator.dart';
import '../../data/datasources/local/database_helper.dart';
import '../../data/models/registro_model.dart';
import '../../data/models/empleado_model.dart';

class MarcarAsistenciaUseCase {
  final DatabaseHelper _db;

  MarcarAsistenciaUseCase({DatabaseHelper? db}) : _db = db ?? DatabaseHelper();

  Future<({EmpleadoModel empleado, double distancia})?> identificarEmpleado(
    List<double> vectorDetectado,
  ) async {
    if (vectorDetectado.isEmpty) return null;

    final all = await _db.getAllEmpleados();
    final empleados = all.where((e) => e.estado == 'ACTIVO').toList();
    print(
      '=== DIAGNOSTICO BIOMETRICO: Comparando contra ${empleados.length} empleados activos ===',
    );
    if (empleados.isEmpty) {
      print('=== DIAGNOSTICO: No hay empleados activos en SQLite ===');
      return null;
    }

    final umbralStr = await _db.getConfig('umbral_facial') ?? '0.6';
    final umbral =
        double.tryParse(umbralStr) ?? AppConstants.faceMatchThreshold;
    print('=== DIAGNOSTICO: Umbral facial configurado: $umbral ===');

    EmpleadoModel? bestEmpleado;
    double bestDistance = double.infinity;

    for (int i = 0; i < empleados.length; i++) {
      final empleado = empleados[i];
      final vector = empleado.mapaVectorFoto;
      if (vector.isEmpty) {
        print(
          '=== DIAGNOSTICO: Empleado ${empleado.nombre} (${empleado.cedula}) sin firma facial ===',
        );
        continue;
      }
      if (vector.length != vectorDetectado.length) {
        print(
          '=== DIAGNOSTICO: Mismatch de tamano para ${empleado.nombre}: BD ${vector.length} d vs Detectado ${vectorDetectado.length} d ===',
        );
        continue;
      }
      final distance = FaceMatcher.euclideanDistance(vectorDetectado, vector);
      print(
        '=== DIAGNOSTICO: Distancia a ${empleado.nombre} (${empleado.cedula}): $distance ===',
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestEmpleado = empleado;
      }
    }

    if (bestEmpleado != null && bestDistance <= umbral) {
      print(
        '=== DIAGNOSTICO: Coincidencia encontrada! ${bestEmpleado.nombre} con distancia $bestDistance ===',
      );
      return (empleado: bestEmpleado, distancia: bestDistance);
    }

    print(
      '=== DIAGNOSTICO: Ningun empleado supero el umbral. Mejor distancia: $bestDistance a ${bestEmpleado?.nombre} ===',
    );
    return null;
  }

  Future<List<RegistroModel>> getRegistrosDeHoy(String cedula) async {
    final registros = await _db.getRegistrosPorCedula(cedula);
    final hoy = DateTime.now().toIso8601String().substring(0, 10);
    return registros.where((r) => r.fechaHora.startsWith(hoy)).toList();
  }

  Future<MarcarAsistenciaResult> registrarMarcadoManual({
    required EmpleadoModel empleado,
    required TipoRegistro tipoSeleccionado,
    double? distancia,
  }) async {
    final ahora = DateTime.now();
    final registrosHoy = await getRegistrosDeHoy(empleado.cedula);

    String evento = AppConstants.eventoEntrada;
    String descripcion = '';

    if (tipoSeleccionado == TipoRegistro.permiso) {
      final permiso = await _db.getPermisoActivoByCedula(empleado.cedula);
      if (permiso == null) {
        return MarcarAsistenciaResult.error(
          'No hay permiso autorizado registrado hoy para este usuario.',
        );
      }
      final yaTieneEntrada = registrosHoy.any(
        (r) => r.evento == AppConstants.eventoEntrada,
      );
      evento = yaTieneEntrada
          ? AppConstants.eventoSalida
          : AppConstants.eventoEntrada;
      descripcion = 'Marcación por Permiso Autorizado registrada con éxito.';
    } else {
      final yaTieneEntrada = registrosHoy.any(
        (r) =>
            r.tipo == TipoRegistro.normal.name.toUpperCase() ||
            r.tipo == TipoRegistro.retardo.name.toUpperCase(),
      );
      final yaTieneSalida = registrosHoy.any(
        (r) => r.tipo == TipoRegistro.salida.name.toUpperCase(),
      );
      final yaTieneAlmuerzo = registrosHoy.any(
        (r) => r.tipo == TipoRegistro.almuerzo.name.toUpperCase(),
      );

      switch (tipoSeleccionado) {
        case TipoRegistro.normal:
        case TipoRegistro.retardo:
          if (yaTieneEntrada) {
            return MarcarAsistenciaResult.error(
              'Registro Inválido: Ya has registrado tu Entrada el día de hoy.',
            );
          }
          evento = AppConstants.eventoEntrada;
          descripcion = '¡Bienvenido! Entrada registrada correctamente.';
          break;

        case TipoRegistro.almuerzo:
          if (!yaTieneEntrada) {
            return MarcarAsistenciaResult.error(
              'Registro Inválido: No puedes registrar Almuerzo sin antes registrar Entrada hoy.',
            );
          }
          if (yaTieneSalida) {
            return MarcarAsistenciaResult.error(
              'Registro Inválido: Ya has registrado la Salida de tu jornada hoy.',
            );
          }
          evento = yaTieneAlmuerzo
              ? AppConstants.eventoEntrada
              : AppConstants.eventoSalida;
          descripcion = yaTieneAlmuerzo
              ? 'Retorno de almuerzo registrado.'
              : 'Salida a almuerzo registrada.';
          break;

        case TipoRegistro.salida:
          if (!yaTieneEntrada) {
            return MarcarAsistenciaResult.error(
              'Registro Inválido: No puedes registrar Salida sin antes haber marcado tu Entrada hoy.',
            );
          }
          if (yaTieneSalida) {
            return MarcarAsistenciaResult.error(
              'Registro Inválido: Ya has marcado tu Salida final por el día de hoy.',
            );
          }
          evento = AppConstants.eventoSalida;
          descripcion =
              'Salida de jornada registrada correctamente. ¡Hasta mañana!';
          break;

        case TipoRegistro.extras:
          evento = yaTieneEntrada
              ? AppConstants.eventoSalida
              : AppConstants.eventoEntrada;
          descripcion = 'Marcación de Horas Extras registrada correctamente.';
          break;

        default:
          return MarcarAsistenciaResult.error(
            'Tipo de registro no soportado en marcado manual.',
          );
      }
    }

    final unidad = await _db.getConfig('unidad_negocio') ?? 'Principal';

    final registro = RegistroModel(
      fechaHora: ahora.toIso8601String().substring(0, 19),
      cedula: empleado.cedula,
      evento: evento,
      tipo: tipoSeleccionado.name.toUpperCase(),
      unidadNegocio: unidad,
      sincronizado: false,
    );

    await _db.insertRegistro(registro);

    return MarcarAsistenciaResult(
      registrado: true,
      mensaje: descripcion,
      empleadoNombre: empleado.nombre,
      empleadoCedula: empleado.cedula,
      tipoRegistro: tipoSeleccionado,
      distancia: distancia,
      registro: registro,
    );
  }

  Future<MarcarAsistenciaResult> execute(List<double> vectorDetectado) async {
    final match = await identificarEmpleado(vectorDetectado);
    if (match == null) {
      return MarcarAsistenciaResult.error('Empleado no reconocido.');
    }

    return registrarMarcadoManual(
      empleado: match.empleado,
      tipoSeleccionado: TipoRegistro.normal,
      distancia: match.distancia,
    );
  }
}

class MarcarAsistenciaResult {
  final bool registrado;
  final String mensaje;
  final String? empleadoNombre;
  final String? empleadoCedula;
  final TipoRegistro? tipoRegistro;
  final double? distancia;
  final RegistroModel? registro;
  final String? error;

  const MarcarAsistenciaResult({
    required this.registrado,
    required this.mensaje,
    this.empleadoNombre,
    this.empleadoCedula,
    this.tipoRegistro,
    this.distancia,
    this.registro,
    this.error,
  });

  factory MarcarAsistenciaResult.error(String error) =>
      MarcarAsistenciaResult(registrado: false, mensaje: error, error: error);

  bool get hasError => error != null;
}
