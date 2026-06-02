import 'dart:io';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../../data/datasources/local/database_helper.dart';
import '../../data/models/empleado_model.dart';
import '../../services/face_recognizer_service.dart';

class RegistrarEmpleadoUseCase {
  final DatabaseHelper _db;
  final FaceRecognizerService _faceService;

  RegistrarEmpleadoUseCase({
    DatabaseHelper? db,
    FaceRecognizerService? faceService,
  })  : _db = db ?? DatabaseHelper(),
        _faceService = faceService ?? FaceRecognizerService();

  Future<EmpleadoModel> execute({
    required String cedula,
    required String nombre,
    required String imagePath,
    Face? face,
    String? horarioId,
    String? fechaIniContrato,
    String? fechaFinContrato,
  }) async {
    // Verificar que el archivo existe
    if (!File(imagePath).existsSync()) {
      throw Exception('Archivo de imagen no encontrado.');
    }

    // Generar vector localmente usando TFLite (con fallback simulado si no está cargado el .tflite)
    final vector = await _faceService.generarVectorDesdeImagen(
      imagePath: imagePath,
      face: face,
      cedula: cedula,
    );

    if (vector.isEmpty) {
      throw Exception('No se pudo generar el vector facial local.');
    }

    // Crear modelo offline
    final empleado = EmpleadoModel(
      cedula: cedula,
      nombre: nombre,
      mapaVectorFoto: vector,
      horarioId: horarioId,
      fechaIniContrato: fechaIniContrato,
      fechaFinContrato: fechaFinContrato,
      estado: 'ACTIVO',
      sincronizado: false,
    );

    // Guardar en SQLite local (Drift)
    await _db.insertEmpleado(empleado);

    return empleado;
  }
}
