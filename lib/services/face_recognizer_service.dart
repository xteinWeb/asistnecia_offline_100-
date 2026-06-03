import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../domain/entities/empleado.dart';
import '../core/constants/api_constants.dart';
import '../core/constants/db_constants.dart';
import '../data/datasources/local/database_helper.dart';

class FaceRecognizerService {
  Interpreter? _interpreter;
  bool _isModelLoaded = false;
  static const int modelInputSize = 112; // MobileFaceNet standard input size
  final DatabaseHelper _db;

  FaceRecognizerService({DatabaseHelper? db}) : _db = db ?? DatabaseHelper() {
    _initInterpreter();
  }

  bool get isModelLoaded => _isModelLoaded;

  Future<void> _initInterpreter() async {
    try {
      // Intentar cargar el intérprete de TFLite desde assets
      _interpreter = await Interpreter.fromAsset(
        'assets/models/facenet.tflite',
      );
      _isModelLoaded = true;
      print('=== MODELO TFLITE (FACENET 128) CARGADO CORRECTAMENTE ===');
    } catch (e) {
      print(
        '=== ADVERTENCIA: No se pudo cargar el modelo TFLite de assets ($e) ===',
      );
      print(
        '=== SE INICIARÁ EL SIMULADOR DE INFERENCIA FACIAL PARA DESARROLLO ===',
      );
      _isModelLoaded = false;
      _interpreter = null;
    }
  }

  /// Genera un vector embedding para una imagen de rostro dada.
  /// Intenta primero utilizar el backend Node.js (128 d) para garantizar compatibilidad con los vectores
  /// descargados en la base de datos sincronizada.
  /// Si el backend no es accesible (offline), realiza la inferencia local con el modelo TFLite de 128 d.
  Future<List<double>> generarVectorDesdeImagen({
    required String imagePath,
    Face? face,
    String? cedula,
  }) async {
    // 1. Intentar extraer vector desde el backend Node.js API (mantiene compatibilidad 128-d con SQLite sincronizado)
    try {
      final baseUrl =
          await _db.getConfig(DbConstants.cfgUrlApi) ??
          ApiConstants.defaultBaseUrl;
      final uri = Uri.parse('$baseUrl${ApiConstants.nuevoEmpleado}');
      final file = File(imagePath);
      if (await file.exists()) {
        File uploadFile = file;
        try {
          final bytes = await file.readAsBytes();
          img.Image? originalImage = img.decodeImage(bytes);
          if (originalImage != null) {
            final orientedImage = img.bakeOrientation(originalImage);
            final tempDir = Directory.systemTemp;
            final tempFile = File(
              '${tempDir.path}/temp_face_api_${DateTime.now().millisecondsSinceEpoch}.jpg',
            );
            await tempFile.writeAsBytes(
              img.encodeJpg(orientedImage, quality: 90),
            );
            uploadFile = tempFile;
            print(
              '=== DIAGNOSTICO: Imagen rotada segun EXIF y guardada en temporal para la API ===',
            );
          }
        } catch (rotError) {
          print(
            '=== ADVERTENCIA: Error al rotar la imagen segun EXIF: $rotError ===',
          );
        }

        final request = http.MultipartRequest('POST', uri);
        request.files.add(
          await http.MultipartFile.fromPath(
            'face',
            uploadFile.path,
            contentType: MediaType('image', 'jpeg'),
          ),
        );
        if (cedula != null && cedula.isNotEmpty) {
          request.fields['cedula'] = cedula;
        }

        print('=== DIAGNOSTICO: Enviando peticion a la API: $uri ===');
        final streamedResponse = await request.send().timeout(
          const Duration(milliseconds: ApiConstants.receiveTimeoutMs),
        );
        final response = await http.Response.fromStream(streamedResponse);

        // Borrar el archivo temporal si se creó uno
        if (uploadFile.path != file.path) {
          try {
            await uploadFile.delete();
          } catch (_) {}
        }

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          List? vectorRaw;
          if (body.containsKey('data') && body['data'] is Map) {
            final data = body['data'] as Map<String, dynamic>;
            vectorRaw = data['vector'] as List?;
          }
          vectorRaw ??= body['vector'] as List?;

          if (vectorRaw != null) {
            final vector = vectorRaw.map((e) => (e as num).toDouble()).toList();
            print('=== VECTOR EXTRAIDO DESDE LA API (${vector.length} d) ===');
            return vector;
          }
        } else {
          print(
            '=== ERROR API DE EXTRACCION: Status: ${response.statusCode}, Body: ${response.body} ===',
          );
        }
      }
    } catch (e, stack) {
      final baseUrl =
          await _db.getConfig(DbConstants.cfgUrlApi) ??
          ApiConstants.defaultBaseUrl;
      final targetUri = '$baseUrl${ApiConstants.nuevoEmpleado}';
      print('=== ERROR AL CONECTAR A LA API ($targetUri): $e ===');
      print(stack);
    }

    // 2. Si falla o estamos desconectados, se cae de vuelta a la inferencia local con TFLite
    if (!_isModelLoaded || _interpreter == null) {
      // MODO SIMULACIÓN: Genera un vector basado en la cédula para pruebas deterministas
      // Si no hay cédula, genera valores semi-aleatorios para emular una detección
      final seedText = cedula ?? 'sim_face_${Random().nextInt(100)}';
      final rand = Random(seedText.hashCode);
      return List.generate(128, (_) => rand.nextDouble() * 2 - 1.0);
    }

    try {
      // 1. Cargar la imagen completa
      final file = File(imagePath);
      if (!await file.exists()) {
        throw Exception(
          'El archivo de imagen no existe en la ruta: $imagePath',
        );
      }
      final bytes = await file.readAsBytes();
      final originalImage = img.decodeImage(bytes);
      if (originalImage == null) {
        throw Exception('No se pudo decodificar la imagen.');
      }

      img.Image faceImage = originalImage;

      // 2. Si se provee la cara detectada por ML Kit, recortamos ese fragmento
      if (face != null) {
        final rect = face.boundingBox;

        // Evitar desbordamiento de límites de la imagen original
        final x = max(0, rect.left.toInt());
        final y = max(0, rect.top.toInt());
        final width = min(rect.width.toInt(), originalImage.width - x);
        final height = min(rect.height.toInt(), originalImage.height - y);

        faceImage = img.copyCrop(
          originalImage,
          x: x,
          y: y,
          width: width,
          height: height,
        );
      }

      // Obtener las dimensiones esperadas del modelo TFLite de forma dinámica
      final inputShape = _interpreter!
          .getInputTensor(0)
          .shape; // e.g. [1, 160, 160, 3]
      final int modelHeight = inputShape[1];
      final int modelWidth = inputShape[2];

      final outputShape = _interpreter!
          .getOutputTensor(0)
          .shape; // e.g. [1, 128]
      final int outDim = outputShape[1];

      // 3. Redimensionar al tamaño dinámico del modelo (ej. 160x160 para Facenet)
      final resizedImage = img.copyResize(
        faceImage,
        width: modelWidth,
        height: modelHeight,
      );

      // 4. Preparar el buffer de entrada en formato Float32List de [1, H, W, 3]
      // Normalizando a (x - 127.5) / 128.0
      var input = List.generate(
        1,
        (_) => List.generate(
          modelHeight,
          (_) => List.generate(modelWidth, (_) => List.filled(3, 0.0)),
        ),
      );

      for (int y = 0; y < modelHeight; y++) {
        for (int x = 0; x < modelWidth; x++) {
          final pixel = resizedImage.getPixel(x, y);
          input[0][y][x][0] = (pixel.r - 127.5) / 128.0;
          input[0][y][x][1] = (pixel.g - 127.5) / 128.0;
          input[0][y][x][2] = (pixel.b - 127.5) / 128.0;
        }
      }

      // 5. Preparar el buffer de salida de tamaño outDim (dinámico, ej. 128)
      var output = List.generate(1, (_) => List.filled(outDim, 0.0));

      // 6. Correr la inferencia local offline en el chip del dispositivo
      _interpreter!.run(input, output);

      // 7. Aplicar Normalización L2 al vector resultante para garantizar
      // compatibilidad exacta con los umbrales L2 de la base de datos central.
      final localVector = output[0].map((e) => e.toDouble()).toList();
      double sum = 0.0;
      for (final val in localVector) {
        sum += val * val;
      }
      final double norm = sqrt(sum);
      if (norm > 0) {
        for (int i = 0; i < localVector.length; i++) {
          localVector[i] /= norm;
        }
      }

      print(
        '=== INFERENCIA TFLITE LOCAL: Vector generado offline con exito (dimension: ${localVector.length}) ===',
      );
      return localVector;
    } catch (e) {
      print('Error en inferencia facial TFLite local: $e');
      // Fallback a simulación si falla
      final seedText = cedula ?? 'sim_face_fallback';
      final rand = Random(seedText.hashCode);
      return List.generate(128, (_) => rand.nextDouble() * 2 - 1.0);
    }
  }

  /// Compara el vector detectado contra la lista de empleados de la base de datos local.
  /// Retorna el empleado coincidente si supera el umbral (threshold) de distancia euclidiana.
  Future<({Empleado empleado, double distancia})?> buscarCoincidenciaLocal({
    required List<double> vectorDetectado,
    required List<Empleado> empleadosActivos,
    double threshold =
        0.6, // Umbral para la distancia Euclidiana L2 normalizada
  }) async {
    if (empleadosActivos.isEmpty) return null;

    Empleado? bestEmpleado;
    double bestDistance = double.infinity;

    for (final empleado in empleadosActivos) {
      final List<double> vectorEmpleado = empleado.mapaVectorFoto;
      if (vectorEmpleado.isEmpty) continue;

      try {
        if (vectorEmpleado.length != vectorDetectado.length) continue;

        // Calcular distancia Euclidiana L2
        double sum = 0.0;
        for (int i = 0; i < vectorDetectado.length; i++) {
          final diff = vectorDetectado[i] - vectorEmpleado[i];
          sum += diff * diff;
        }
        final distance = sqrt(sum);

        if (distance < bestDistance) {
          bestDistance = distance;
          bestEmpleado = empleado;
        }
      } catch (e) {
        print('Error comparando vector para empleado ${empleado.cedula}: $e');
      }
    }

    if (bestEmpleado != null && bestDistance <= threshold) {
      return (empleado: bestEmpleado, distancia: bestDistance);
    }

    return null;
  }
}
