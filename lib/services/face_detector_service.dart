import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectorService {
  late final FaceDetector _faceDetector;

  FaceDetectorService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true, // Permite saber si los ojos están abiertos
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
  }

  /// Procesa una imagen desde una ruta local y retorna las caras detectadas.
  Future<List<Face>> detectFacesFromPath(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    return await _faceDetector.processImage(inputImage);
  }

  /// Cierra el detector para liberar recursos nativos.
  Future<void> dispose() async {
    await _faceDetector.close();
  }
}
