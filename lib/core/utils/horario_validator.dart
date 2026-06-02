import '../constants/app_constants.dart';
import '../../domain/entities/horario.dart';
import '../../domain/entities/permiso.dart';

enum TipoRegistro {
  normal,   // Entrada/salida a tiempo
  retardo,  // Llegada tarde
  salida,   // Salida
  almuerzo, // Registro de almuerzo
  extras,   // Tiempo extra
  permiso,  // Autorizado por permiso
  noRegistrar, // Sin horario ni permiso
}

class ResultadoValidacion {
  final TipoRegistro tipo;
  final String evento;       // ENTRADA / SALIDA
  final String descripcion;  // Mensaje al empleado
  final bool registrar;

  const ResultadoValidacion({
    required this.tipo,
    required this.evento,
    required this.descripcion,
    required this.registrar,
  });
}

class HorarioValidator {
  static ResultadoValidacion validar({
    required Horario? horario,
    required Permiso? permisoActivo,
    required DateTime ahora,
  }) {
    // 1. Sin horario asignado
    if (horario == null) {
      if (permisoActivo != null && permisoActivo.isActivoEn(ahora)) {
        return const ResultadoValidacion(
          tipo: TipoRegistro.permiso,
          evento: AppConstants.eventoEntrada,
          descripcion: 'Permiso autorizado registrado.',
          registrar: true,
        );
      }
      return const ResultadoValidacion(
        tipo: TipoRegistro.noRegistrar,
        evento: AppConstants.eventoEntrada,
        descripcion: 'Sin horario asignado y sin permiso activo.',
        registrar: false,
      );
    }

    // 2. Verificar si el día actual está en el horario
    final diaActual = _diaAbreviado(ahora.weekday);
    if (!horario.diasList.contains(diaActual)) {
      if (permisoActivo != null && permisoActivo.isActivoEn(ahora)) {
        return const ResultadoValidacion(
          tipo: TipoRegistro.permiso,
          evento: AppConstants.eventoEntrada,
          descripcion: 'Permiso autorizado registrado.',
          registrar: true,
        );
      }
      return const ResultadoValidacion(
        tipo: TipoRegistro.noRegistrar,
        evento: AppConstants.eventoEntrada,
        descripcion: 'Día no laborable y sin permiso activo.',
        registrar: false,
      );
    }

    // 3. Parsear horas del horario
    final horaInicio = _parseHora(horario.horaInicio, ahora);
    final horaFinal = _parseHora(horario.horaFinal, ahora);
    if (horaInicio == null || horaFinal == null) {
      return const ResultadoValidacion(
        tipo: TipoRegistro.noRegistrar,
        evento: AppConstants.eventoEntrada,
        descripcion: 'Error al leer el horario.',
        registrar: false,
      );
    }

    final tolerancia = const Duration(minutes: AppConstants.toleranciaRetardoMinutos);

    // 4. Tipo ALMUERZO
    if (horario.tipo == AppConstants.horarioAlmuerzo) {
      return ResultadoValidacion(
        tipo: TipoRegistro.almuerzo,
        evento: _eventoParaHora(ahora, horaInicio, horaFinal),
        descripcion: 'Registro de almuerzo.',
        registrar: true,
      );
    }

    // 5. Tipo LABORAL
    if (ahora.isAfter(horaInicio.subtract(const Duration(minutes: 5))) &&
        ahora.isBefore(horaFinal)) {
      // Verificar si es salida
      if (ahora.isAfter(horaFinal.subtract(const Duration(minutes: 30)))) {
        return ResultadoValidacion(
          tipo: TipoRegistro.salida,
          evento: AppConstants.eventoSalida,
          descripcion: 'Salida registrada. ¡Hasta mañana!',
          registrar: true,
        );
      }

      // Entrada normal o retardo
      final esRetardo = ahora.isAfter(horaInicio.add(tolerancia));
      if (esRetardo) {
        final minutosTarde = ahora.difference(horaInicio).inMinutes;
        return ResultadoValidacion(
          tipo: TipoRegistro.retardo,
          evento: AppConstants.eventoEntrada,
          descripcion: 'Retardo de $minutosTarde minutos registrado.',
          registrar: true,
        );
      } else {
        return const ResultadoValidacion(
          tipo: TipoRegistro.normal,
          evento: AppConstants.eventoEntrada,
          descripcion: '¡Bienvenido! Entrada registrada.',
          registrar: true,
        );
      }
    }

    // 6. Fuera del horario laboral
    if (ahora.isAfter(horaFinal)) {
      return const ResultadoValidacion(
        tipo: TipoRegistro.extras,
        evento: AppConstants.eventoSalida,
        descripcion: 'Registro fuera de horario (horas extras).',
        registrar: true,
      );
    }

    // 7. Muy temprano (antes del horario)
    if (permisoActivo != null && permisoActivo.isActivoEn(ahora)) {
      return const ResultadoValidacion(
        tipo: TipoRegistro.permiso,
        evento: AppConstants.eventoEntrada,
        descripcion: 'Permiso autorizado registrado.',
        registrar: true,
      );
    }

    return const ResultadoValidacion(
      tipo: TipoRegistro.noRegistrar,
      evento: AppConstants.eventoEntrada,
      descripcion: 'Fuera del horario de registro.',
      registrar: false,
    );
  }

  static String _eventoParaHora(
      DateTime ahora, DateTime inicio, DateTime fin) {
    final mitad = inicio.add(fin.difference(inicio) ~/ 2);
    return ahora.isBefore(mitad)
        ? AppConstants.eventoEntrada
        : AppConstants.eventoSalida;
  }

  static DateTime? _parseHora(String horaStr, DateTime referencia) {
    final parts = horaStr.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return DateTime(
        referencia.year, referencia.month, referencia.day, hour, minute);
  }

  static String _diaAbreviado(int weekday) {
    const map = {
      1: 'L',
      2: 'M',
      3: 'Mi',
      4: 'J',
      5: 'V',
      6: 'S',
      7: 'D',
    };
    return map[weekday] ?? '';
  }
}
