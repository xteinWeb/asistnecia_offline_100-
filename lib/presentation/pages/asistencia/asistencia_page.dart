import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:provider/provider.dart';
import 'dart:math';
import 'dart:io';

import '../../../core/theme/app_colors.dart';
import '../../../services/face_detector_service.dart';
import '../../../services/face_recognizer_service.dart';
import '../../../services/sync_service.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/horario_validator.dart';
import '../../../core/constants/db_constants.dart';
import '../../../data/datasources/local/database_helper.dart';
import '../../../domain/usecases/marcar_asistencia_usecase.dart';
import '../../../core/routes/app_router.dart';
import '../../../data/models/empleado_model.dart';
import '../../../data/models/registro_model.dart';

class AsistenciaPage extends StatefulWidget {
  const AsistenciaPage({super.key});

  @override
  State<AsistenciaPage> createState() => _AsistenciaPageState();
}

class _AppState {
  final bool procesando;
  final String mensaje;
  final Color mensajeColor;
  final String? empleadoNombre;
  final String? empleadoCedula;
  final TipoRegistro? tipoRegistro;
  final double? distancia;

  const _AppState({
    required this.procesando,
    required this.mensaje,
    required this.mensajeColor,
    this.empleadoNombre,
    this.empleadoCedula,
    this.tipoRegistro,
    this.distancia,
  });
}

class _AsistenciaPageState extends State<AsistenciaPage> {
  bool _procesando = false;

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _initializingCamera = false;
  XFile? _capturedImage;
  String _userRole = 'OPERADOR';

  EmpleadoModel? _empleadoIdentificado;
  double? _distanciaMatch;
  List<RegistroModel> _registrosHoy = [];
  bool _mostrarPanelSeleccion = false;
  bool _permitirManual = false;

  late final FaceDetectorService _faceDetectorService;
  late final FaceRecognizerService _faceRecognizerService;

  _AppState _state = const _AppState(
    procesando: false,
    mensaje: 'Inicializando cámara frontal...',
    mensajeColor: Colors.white70,
  );

  late final Stream<DateTime> _clockStream;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _clockStream = Stream.periodic(
      const Duration(seconds: 1),
      (_) => DateTime.now(),
    );
    _faceDetectorService = FaceDetectorService();
    _faceRecognizerService = FaceRecognizerService();
    _initializeCamera();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _userRole = prefs.getString('user_role') ?? 'OPERADOR';
      });

      final db = DatabaseHelper();
      final permitir = await db.getConfig(DbConstants.cfgPermitirManual) ?? '0';
      setState(() {
        _permitirManual = permitir == '1';
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _faceDetectorService.dispose();
    _disposeCamera();
    super.dispose();
  }

  Future<void> _disposeCamera() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _initializingCamera = false;
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (_initializingCamera || _isCameraInitialized) return;

    setState(() {
      _initializingCamera = true;
      _capturedImage = null;
      _state = const _AppState(
        procesando: false,
        mensaje: 'Iniciando cámara del Tótem...',
        mensajeColor: AppColors.info,
      );
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw Exception('No se detectaron cámaras en el dispositivo.');
      }

      CameraDescription selectedCamera = _cameras.first;
      for (final cam in _cameras) {
        if (cam.lensDirection == CameraLensDirection.front) {
          selectedCamera = cam;
          break;
        }
      }

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _initializingCamera = false;
          _state = const _AppState(
            procesando: false,
            mensaje: 'Listo para escanear',
            mensajeColor: Colors.white70,
          );
        });
      }
    } catch (e) {
      await _disposeCamera();
      if (mounted) {
        setState(() {
          _state = _AppState(
            procesando: false,
            mensaje:
                'Error de cámara: ${e.toString().replaceAll('Exception: ', '')}',
            mensajeColor: AppColors.error,
          );
        });
      }
    }
  }

  Future<void> _marcarAsistenciaReal() async {
    if (_procesando || _cameraController == null || !_isCameraInitialized)
      return;

    setState(() {
      _procesando = true;
      _capturedImage = null;
      _empleadoIdentificado = null;
      _distanciaMatch = null;
      _mostrarPanelSeleccion = false;
      _state = const _AppState(
        procesando: true,
        mensaje: 'Capturando rostro...',
        mensajeColor: AppColors.primary,
      );
    });

    try {
      final image = await _cameraController!.takePicture();

      if (mounted) {
        setState(() {
          _capturedImage = image;
          _state = const _AppState(
            procesando: true,
            mensaje: 'Detectando rostro localmente...',
            mensajeColor: AppColors.info,
          );
        });
      }

      // 1. Detectar caras localmente usando ML Kit
      final faces = await _faceDetectorService.detectFacesFromPath(image.path);
      if (faces.isEmpty) {
        throw Exception('Rostro no detectado de forma clara en la imagen.');
      }

      if (mounted) {
        setState(() {
          _state = const _AppState(
            procesando: true,
            mensaje: 'Generando vector local con TFLite...',
            mensajeColor: AppColors.info,
          );
        });
      }

      // 2. Extraer el vector localmente usando el modelo TFLite
      final vector = await _faceRecognizerService.generarVectorDesdeImagen(
        imagePath: image.path,
        face: faces.first,
      );

      if (vector.isEmpty) {
        throw Exception('No se pudo generar la firma biométrica local.');
      }

      if (mounted) {
        setState(() {
          _state = const _AppState(
            procesando: true,
            mensaje: 'Buscando empleado en base de datos local...',
            mensajeColor: AppColors.info,
          );
        });
      }

      // 3. Buscar coincidencia localmente en SQLite
      final useCase = MarcarAsistenciaUseCase();
      final match = await useCase.identificarEmpleado(vector);

      if (match == null) {
        throw Exception('Empleado no reconocido.');
      }

      // 4. Cargar registros de hoy
      final registrosHoy = await useCase.getRegistrosDeHoy(
        match.empleado.cedula,
      );

      if (mounted) {
        setState(() {
          _procesando = false;
          _empleadoIdentificado = match.empleado;
          _distanciaMatch = match.distancia;
          _registrosHoy = registrosHoy;
          _mostrarPanelSeleccion = true;

          _state = _AppState(
            procesando: false,
            mensaje: 'Rostro Identificado. Selecciona tu registro hoy:',
            mensajeColor: AppColors.secondary,
            empleadoNombre: match.empleado.nombre,
            empleadoCedula: match.empleado.cedula,
            distancia: match.distancia,
          );
        });
      }

      Future.delayed(const Duration(seconds: 15)).then((_) {
        if (mounted &&
            _mostrarPanelSeleccion &&
            _empleadoIdentificado?.cedula == match.empleado.cedula &&
            !_procesando) {
          _cancelarFlujoMarcacion();
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _capturedImage = null;
          _state = _AppState(
            procesando: false,
            mensaje: 'Error: ${e.toString().replaceAll('Exception: ', '')}',
            mensajeColor: AppColors.error,
          );
          print('Error: ${e.toString()}');
        });
      }

      await Future.delayed(const Duration(seconds: 4));
      if (mounted && !_mostrarPanelSeleccion) {
        _cancelarFlujoMarcacion();
      }
    }
  }

  Future<void> _mostrarDialogoMarcacionOffline() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.kioskSurface,
        title: const Text(
          'Marcación Offline',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Ingresa tu número de Cédula para marcar asistencia de forma offline:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Número de Cédula',
                  labelStyle: TextStyle(color: Colors.white70),
                  prefixIcon: Icon(Icons.badge_outlined, color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppColors.secondary),
                  ),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Ingresa la cédula' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.secondary,
            ),
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                final cedula = controller.text.trim();
                Navigator.pop(context);
                await _identificarEmpleadoOffline(cedula);
              }
            },
            child: const Text('Aceptar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _identificarEmpleadoOffline(String cedula) async {
    setState(() {
      _procesando = true;
      _capturedImage = null;
      _empleadoIdentificado = null;
      _distanciaMatch = null;
      _mostrarPanelSeleccion = false;
      _state = const _AppState(
        procesando: true,
        mensaje: 'Verificando cédula local...',
        mensajeColor: AppColors.primary,
      );
    });

    try {
      final db = DatabaseHelper();
      final empleado = await db.getEmpleadoByCedula(cedula);

      if (empleado == null) {
        throw Exception('Cédula no registrada en este dispositivo.');
      }

      if (empleado.estado != 'ACTIVO') {
        throw Exception(
          'El empleado correspondiente a esta cédula se encuentra INACTIVO.',
        );
      }

      final useCase = MarcarAsistenciaUseCase();
      final registrosHoy = await useCase.getRegistrosDeHoy(cedula);

      if (mounted) {
        setState(() {
          _procesando = false;
          _empleadoIdentificado = empleado;
          _distanciaMatch = null;
          _registrosHoy = registrosHoy;
          _mostrarPanelSeleccion = true;

          _state = _AppState(
            procesando: false,
            mensaje: 'Cédula Identificada. Selecciona tu registro hoy:',
            mensajeColor: AppColors.secondary,
            empleadoNombre: empleado.nombre,
            empleadoCedula: empleado.cedula,
          );
        });
      }

      Future.delayed(const Duration(seconds: 15)).then((_) {
        if (mounted &&
            _mostrarPanelSeleccion &&
            _empleadoIdentificado?.cedula == cedula &&
            !_procesando) {
          _cancelarFlujoMarcacion();
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _AppState(
            procesando: false,
            mensaje: 'Error: ${e.toString().replaceAll('Exception: ', '')}',
            mensajeColor: AppColors.error,
          );
        });
      }

      await Future.delayed(const Duration(seconds: 4));
      if (mounted && !_mostrarPanelSeleccion) {
        _cancelarFlujoMarcacion();
      }
    }
  }

  Future<void> _registrarMarcacionManual(TipoRegistro tipoSeleccionado) async {
    if (_empleadoIdentificado == null || _procesando) return;

    if (tipoSeleccionado == TipoRegistro.permiso) {
      final db = DatabaseHelper();
      final permiso = await db.getPermisoActivoByCedula(
        _empleadoIdentificado!.cedula,
      );
      if (permiso == null) {
        setState(() {
          _state = _AppState(
            procesando: false,
            mensaje:
                'No hay permiso autorizado registrado hoy para este usuario.',
            mensajeColor: AppColors.error,
            empleadoNombre: _empleadoIdentificado!.nombre,
            empleadoCedula: _empleadoIdentificado!.cedula,
            distancia: _distanciaMatch,
          );
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Registro Inválido: No hay permiso autorizado registrado hoy para este usuario.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
    }

    setState(() {
      _capturedImage = null;
      _procesando = true;
      _state = _AppState(
        procesando: true,
        mensaje: '¡VALIDANDO VIDA! ¡PARPADEA AHORA!',
        mensajeColor: AppColors.secondary,
        empleadoNombre: _empleadoIdentificado!.nombre,
        empleadoCedula: _empleadoIdentificado!.cedula,
        distancia: _distanciaMatch,
      );
    });

    List<XFile> rafagaFotos = [];
    List<double> eyeProbabilities = [];

    try {
      // Damos un tiempo inicial para desahogar el buffer de la primera captura
      await Future.delayed(const Duration(milliseconds: 500));
      rafagaFotos.add(await _cameraController!.takePicture());

      await Future.delayed(const Duration(milliseconds: 400));
      rafagaFotos.add(await _cameraController!.takePicture());

      await Future.delayed(const Duration(milliseconds: 400));
      rafagaFotos.add(await _cameraController!.takePicture());

      if (mounted) {
        setState(() {
          _state = _AppState(
            procesando: true,
            mensaje: 'Procesando prueba de vida local...',
            mensajeColor: AppColors.info,
            empleadoNombre: _empleadoIdentificado!.nombre,
            empleadoCedula: _empleadoIdentificado!.cedula,
            distancia: _distanciaMatch,
          );
        });
      }

      // Validar parpadeo local usando el detector nativo ML Kit
      final tempDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );

      for (final img in rafagaFotos) {
        final inputImage = InputImage.fromFilePath(img.path);
        final faces = await tempDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;
          final probIzq = face.leftEyeOpenProbability;
          final probDer = face.rightEyeOpenProbability;

          if (probIzq != null && probDer != null) {
            eyeProbabilities.add((probIzq + probDer) / 2);
          }
        }
      }

      await tempDetector.close();

      // Borrar fotos de ráfaga
      for (final img in rafagaFotos) {
        try {
          final f = File(img.path);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }

      double maxVal = 0.0;
      double minVal = 1.0;
      for (final val in eyeProbabilities) {
        if (val > maxVal) maxVal = val;
        if (val < minVal) minVal = val;
      }

      final delta = maxVal - minVal;
      final esHumanoVivo =
          eyeProbabilities.isEmpty ||
          (maxVal >= 0.50 && minVal <= 0.40 && delta >= 0.15);

      if (!esHumanoVivo) {
        setState(() {
          _procesando = false;
          _state = _AppState(
            procesando: false,
            mensaje: 'FALLO DE VIDA: ROSTRO ESTÁTICO DETECTADO.',
            mensajeColor: AppColors.error,
            empleadoNombre: _empleadoIdentificado?.nombre ?? '',
            empleadoCedula: _empleadoIdentificado?.cedula ?? '',
            distancia: _distanciaMatch,
          );
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '⚠️ Seguridad: Rostro estático detectado. Por favor, parpadee frente a la cámara.',
            ),
            backgroundColor: AppColors.error,
          ),
        );

        await Future.delayed(const Duration(seconds: 4));
        if (mounted && _mostrarPanelSeleccion) {
          _cancelarFlujoMarcacion();
        }
        return;
      }

      // Registro final en SQLite local
      final useCase = MarcarAsistenciaUseCase();
      if (_empleadoIdentificado == null) return;
      final result = await useCase.registrarMarcadoManual(
        empleado: _empleadoIdentificado!,
        tipoSeleccionado: tipoSeleccionado,
        distancia: _distanciaMatch,
      );

      if (!mounted) return;

      if (result.hasError) {
        setState(() {
          _procesando = false;
          _state = _AppState(
            procesando: false,
            mensaje: result.mensaje,
            mensajeColor: AppColors.error,
            empleadoNombre: _empleadoIdentificado?.nombre ?? '',
            empleadoCedula: _empleadoIdentificado?.cedula ?? '',
            distancia: _distanciaMatch,
          );
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.mensaje),
            backgroundColor: AppColors.error,
          ),
        );
      } else {
        Color color = AppColors.success;
        switch (result.tipoRegistro) {
          case TipoRegistro.normal:
            color = AppColors.success;
            break;
          case TipoRegistro.retardo:
            color = AppColors.colorRetardo;
            break;
          case TipoRegistro.almuerzo:
            color = AppColors.colorAlmuerzo;
            break;
          case TipoRegistro.salida:
            color = AppColors.colorSalida;
            break;
          case TipoRegistro.permiso:
            color = AppColors.colorPermiso;
            break;
          case TipoRegistro.extras:
            color = AppColors.colorExtras;
            break;
          default:
            color = AppColors.success;
        }

        setState(() {
          _procesando = false;
          _mostrarPanelSeleccion = false;
          _state = _AppState(
            procesando: false,
            mensaje: result.mensaje,
            mensajeColor: color,
            empleadoNombre: result.empleadoNombre,
            empleadoCedula: result.empleadoCedula,
            tipoRegistro: result.tipoRegistro,
            distancia: result.distancia,
          );
        });

        // Intentar sincronización local asíncrona inmediata
        context.read<SyncService>().syncAll();

        await Future.delayed(
          const Duration(seconds: AppConstants.resultDisplaySeconds),
        );
        if (mounted) {
          _cancelarFlujoMarcacion();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _procesando = false;
          _state = _AppState(
            procesando: false,
            mensaje: 'Error: ${e.toString().replaceAll('Exception: ', '')}',
            mensajeColor: AppColors.error,
            empleadoNombre: _empleadoIdentificado?.nombre,
            empleadoCedula: _empleadoIdentificado?.cedula,
            distancia: _distanciaMatch,
          );
        });
      }
    }
  }

  Future<void> _mostrarLoginAdministrador() async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.kioskSurface,
        title: const Text(
          'Acceso Administrativo',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: userCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Usuario',
                  labelStyle: TextStyle(color: Colors.white70),
                  prefixIcon: Icon(Icons.person, color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppColors.secondary),
                  ),
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Ingrese el usuario' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: passCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Contraseña',
                  labelStyle: TextStyle(color: Colors.white70),
                  prefixIcon: Icon(Icons.lock, color: Colors.white70),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppColors.secondary),
                  ),
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? 'Ingrese la contraseña'
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.secondary,
            ),
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                final user = userCtrl.text.trim();
                final pass = passCtrl.text.trim();
                final db = DatabaseHelper();
                final usuario = await db.getUsuario(user, pass);
                if (usuario != null && usuario.rol == 'ADMIN') {
                  Navigator.pop(context);
                  _mostrarConfiguracionesAdmin();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Credenciales inválidas o sin rol de administrador.',
                      ),
                      backgroundColor: AppColors.error,
                    ),
                  );
                }
              }
            },
            child: const Text(
              'Ingresar',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarConfiguracionesAdmin() async {
    final db = DatabaseHelper();
    final formKey = GlobalKey<FormState>();

    // Cargar configuraciones actuales
    final url = await db.getConfig(DbConstants.cfgUrlApi) ?? '';
    final umbral = await db.getConfig(DbConstants.cfgUmbralFacial) ?? '0.6';
    final permitir = await db.getConfig(DbConstants.cfgPermitirManual) ?? '0';
    final unidad =
        await db.getConfig(DbConstants.cfgUnidadNegocio) ?? 'Principal';

    final urlCtrl = TextEditingController(text: url);
    final umbralCtrl = TextEditingController(text: umbral);
    final unidadCtrl = TextEditingController(text: unidad);
    bool permitirManual = permitir == '1';

    int pendientesRegistros = 0;
    int pendientesPermisos = 0;

    // Obtener registros pendientes
    try {
      final regPendientes = await db.getRegistrosPendientes();
      final permPendientes = await db.getPermisosPendientes();
      pendientesRegistros = regPendientes.length;
      pendientesPermisos = permPendientes.length;
    } catch (_) {}

    bool syncing = false;

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: AppColors.kioskSurface,
              title: const Row(
                children: [
                  Icon(Icons.settings, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'Configuración del Tótem',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 450,
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // URL de la API
                        TextFormField(
                          controller: urlCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'URL de la API',
                            labelStyle: TextStyle(color: Colors.white70),
                            prefixIcon: Icon(Icons.link, color: Colors.white70),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white24),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Ingrese la URL'
                              : null,
                        ),
                        const SizedBox(height: 16),

                        // Umbral de coincidencia facial
                        TextFormField(
                          controller: umbralCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Umbral Facial (L2 Distance)',
                            labelStyle: TextStyle(color: Colors.white70),
                            helperText:
                                'Menor valor exige más parecido. Recomendado: 0.6',
                            helperStyle: TextStyle(
                              color: Colors.white54,
                              fontSize: 10,
                            ),
                            prefixIcon: Icon(
                              Icons.fingerprint,
                              color: Colors.white70,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white24),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty)
                              return 'Ingrese el umbral';
                            final val = double.tryParse(v);
                            if (val == null || val <= 0 || val > 2.0)
                              return 'Ingrese un decimal válido';
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Unidad de negocio
                        TextFormField(
                          controller: unidadCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            labelText: 'Unidad de Negocio / ID Tótem',
                            labelStyle: TextStyle(color: Colors.white70),
                            prefixIcon: Icon(
                              Icons.business_center,
                              color: Colors.white70,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white24),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                color: AppColors.secondary,
                              ),
                            ),
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Ingrese la unidad'
                              : null,
                        ),
                        const SizedBox(height: 16),

                        // Switch de marcado manual
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Marcación manual por Cédula',
                            style: TextStyle(color: Colors.white, fontSize: 14),
                          ),
                          subtitle: const Text(
                            'Permitir contingencia en pantalla',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          value: permitirManual,
                          activeColor: AppColors.secondary,
                          onChanged: (val) {
                            setStateDialog(() {
                              permitirManual = val;
                            });
                          },
                        ),
                        const Divider(color: Colors.white24, height: 32),

                        // Sincronización
                        Text(
                          'Pendientes por Sincronizar:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Registros de Asistencia: $pendientesRegistros',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              'Permisos Autorizados: $pendientesPermisos',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.secondary,
                              side: const BorderSide(
                                color: AppColors.secondary,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: syncing
                                ? null
                                : () async {
                                    setStateDialog(() {
                                      syncing = true;
                                    });
                                    try {
                                      // Guardar la URL antes de sincronizar por si cambió
                                      await db.setConfig(
                                        DbConstants.cfgUrlApi,
                                        urlCtrl.text.trim(),
                                      );

                                      final syncService =
                                          Provider.of<SyncService>(
                                            context,
                                            listen: false,
                                          );
                                      final res = await syncService.syncAll();

                                      final regPendientes = await db
                                          .getRegistrosPendientes();
                                      final permPendientes = await db
                                          .getPermisosPendientes();

                                      setStateDialog(() {
                                        pendientesRegistros =
                                            regPendientes.length;
                                        pendientesPermisos =
                                            permPendientes.length;
                                      });

                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            res.hasErrors
                                                ? 'Sincronizado con advertencias: ${res.errors.first}'
                                                : '¡Sincronización exitosa!',
                                          ),
                                          backgroundColor: res.hasErrors
                                              ? AppColors.warning
                                              : AppColors.success,
                                        ),
                                      );
                                    } catch (e) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Error al sincronizar: $e',
                                          ),
                                          backgroundColor: AppColors.error,
                                        ),
                                      );
                                    } finally {
                                      setStateDialog(() {
                                        syncing = false;
                                      });
                                    }
                                  },
                            icon: syncing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.secondary,
                                    ),
                                  )
                                : const Icon(Icons.sync),
                            label: const Text('Forzar Sincronización con Nube'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cerrar',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                  ),
                  onPressed: syncing
                      ? null
                      : () async {
                          if (formKey.currentState!.validate()) {
                            await db.setConfig(
                              DbConstants.cfgUrlApi,
                              urlCtrl.text.trim(),
                            );
                            await db.setConfig(
                              DbConstants.cfgUmbralFacial,
                              umbralCtrl.text.trim(),
                            );
                            await db.setConfig(
                              DbConstants.cfgUnidadNegocio,
                              unidadCtrl.text.trim(),
                            );
                            await db.setConfig(
                              DbConstants.cfgPermitirManual,
                              permitirManual ? '1' : '0',
                            );

                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Configuración guardada correctamente',
                                ),
                                backgroundColor: AppColors.success,
                              ),
                            );
                            Navigator.pop(context);
                            _loadConfig();
                            _cancelarFlujoMarcacion();
                          }
                        },
                  child: const Text(
                    'Guardar Cambios',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _cancelarFlujoMarcacion() {
    if (!mounted) return;
    setState(() {
      _capturedImage = null;
      _empleadoIdentificado = null;
      _distanciaMatch = null;
      _registrosHoy = [];
      _mostrarPanelSeleccion = false;
      _procesando = false;
      _state = const _AppState(
        procesando: false,
        mensaje: 'Listo para escanear',
        mensajeColor: Colors.white70,
      );
    });
  }

  Future<void> procesarVector(List<double> vectorDetectado) async {
    if (_procesando) return;
    setState(() {
      _procesando = true;
      _state = const _AppState(
        procesando: true,
        mensaje: 'Buscando coincidencia (Debug)...',
        mensajeColor: AppColors.info,
      );
    });

    try {
      final useCase = MarcarAsistenciaUseCase();
      final match = await useCase.identificarEmpleado(vectorDetectado);

      if (match == null) {
        throw Exception('Empleado no reconocido.');
      }

      final registrosHoy = await useCase.getRegistrosDeHoy(
        match.empleado.cedula,
      );

      if (mounted) {
        setState(() {
          _procesando = false;
          _empleadoIdentificado = match.empleado;
          _distanciaMatch = match.distancia;
          _registrosHoy = registrosHoy;
          _mostrarPanelSeleccion = true;

          _state = _AppState(
            procesando: false,
            mensaje: 'Identificado (Debug). Selecciona tu registro:',
            mensajeColor: AppColors.secondary,
            empleadoNombre: match.empleado.nombre,
            empleadoCedula: match.empleado.cedula,
            distancia: match.distancia,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _AppState(
            procesando: false,
            mensaje: 'Error debug: $e',
            mensajeColor: AppColors.error,
          );
        });
      }
    }
  }

  Future<void> _simularEscaneoFacial() async {
    final db = DatabaseHelper();
    final empleados = await db.getAllEmpleados();

    if (!mounted) return;

    if (empleados.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay empleados en base de datos. Crea uno en la sección "Empleados".',
          ),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    final conVector = empleados
        .where((e) => e.mapaVectorFoto.isNotEmpty)
        .toList();
    if (conVector.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ninguno de los empleados tiene rostro enrolado. Por favor, edita o registra uno con foto.',
          ),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    final emp = conVector[Random().nextInt(conVector.length)];

    final vectorSimulado = emp.mapaVectorFoto.map((v) {
      final ruido = (Random().nextDouble() - 0.5) * 0.04;
      return (v + ruido).clamp(-1.0, 1.0);
    }).toList();

    await procesarVector(vectorSimulado);
  }

  String _getTipoRegistroLabel(TipoRegistro tipo) {
    switch (tipo) {
      case TipoRegistro.normal:
        return 'ENTRADA NORMAL';
      case TipoRegistro.retardo:
        return 'RETARDO REGISTRADO';
      case TipoRegistro.almuerzo:
        return 'REGISTRO DE ALMUERZO';
      case TipoRegistro.salida:
        return 'SALIDA REGISTRADA';
      case TipoRegistro.permiso:
        return 'PERMISO AUTORIZADO';
      case TipoRegistro.extras:
        return 'HORAS EXTRAS';
      case TipoRegistro.noRegistrar:
        return 'REGISTRO RECHAZADO';
    }
  }

  Widget _buildBotonPanel({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    final isDisabled = onPressed == null;
    return Opacity(
      opacity: isDisabled ? 0.35 : 1.0,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: isDisabled ? 0 : 4,
          textStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.kioskBackground,
      appBar: AppBar(
        title: const Text('Tótem de Asistencia'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.psychology_outlined, color: Colors.white30),
            tooltip: 'Simular marcación (Offline Debug)',
            onPressed: _procesando ? null : _simularEscaneoFacial,
          ),
        ],
      ),
      body: Column(
        children: [
          StreamBuilder<DateTime>(
            stream: _clockStream,
            builder: (context, snap) {
              final now = snap.data ?? DateTime.now();
              return GestureDetector(
                onDoubleTap: _mostrarLoginAdministrador,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  color: Colors.transparent,
                  child: Column(
                    children: [
                      Text(
                        DateFormat('HH:mm:ss').format(now),
                        style: const TextStyle(
                          fontSize: 64,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        DateFormat(
                          'EEEE, d \'de\' MMMM \'de\' yyyy',
                          'es',
                        ).format(now).toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          Expanded(
            child: Center(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  color: AppColors.kioskSurface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white24, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_isCameraInitialized &&
                          _cameraController != null &&
                          _capturedImage == null)
                        Positioned.fill(
                          child: AspectRatio(
                            aspectRatio: _cameraController!.value.aspectRatio,
                            child: CameraPreview(_cameraController!),
                          ),
                        ),

                      if (_capturedImage != null)
                        Positioned.fill(
                          child: Image.file(
                            File(_capturedImage!.path),
                            fit: BoxFit.cover,
                          ),
                        ),

                      if (!_isCameraInitialized && _capturedImage == null)
                        const Positioned.fill(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.videocam_off_outlined,
                                size: 100,
                                color: Colors.white10,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'CÁMARA DEL TÓTEM INICIALIZANDO...',
                                style: TextStyle(
                                  color: Colors.white30,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (_isCameraInitialized &&
                          _cameraController != null &&
                          _capturedImage == null &&
                          !_procesando)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: AppColors.secondary.withOpacity(0.3),
                                width: 3,
                              ),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Center(
                              child: Container(
                                width: 180,
                                height: 180,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: AppColors.secondary.withOpacity(0.7),
                                    width: 2,
                                    style: BorderStyle.solid,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),

                      if (_procesando)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  AppColors.secondary.withOpacity(0.0),
                                  AppColors.secondary.withOpacity(0.1),
                                  AppColors.secondary.withOpacity(0.3),
                                  AppColors.secondary.withOpacity(0.1),
                                  AppColors.secondary.withOpacity(0.0),
                                ],
                                stops: const [0.0, 0.4, 0.5, 0.6, 1.0],
                              ),
                            ),
                          ),
                        ),

                      if (_procesando && _state.mensaje.contains('PARPADEA'))
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withOpacity(0.75),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 110,
                                      height: 110,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 5,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              AppColors.secondaryLight,
                                            ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.remove_red_eye_rounded,
                                      size: 56,
                                      color: AppColors.secondaryLight,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),
                                const Text(
                                  '¡PRUEBA DE SEGURIDAD!',
                                  style: TextStyle(
                                    color: AppColors.secondaryLight,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '👀 ¡PARPADEE VARIAS VECES! 👀',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 15,
                                        color: AppColors.secondary,
                                        offset: Offset(0, 0),
                                      ),
                                    ],
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: Colors.white12),
                                  ),
                                  child: const Text(
                                    'Parpadee de forma continua frente a la cámara',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      if (!_mostrarPanelSeleccion && !_procesando)
                        Positioned(
                          bottom: 24,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ElevatedButton.icon(
                                onPressed: (!_isCameraInitialized)
                                    ? null
                                    : _marcarAsistenciaReal,
                                icon: const Icon(Icons.face_unlock_rounded),
                                label: const Text('MARCAR CON ROSTRO'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.secondary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 32,
                                    vertical: 18,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(30),
                                  ),
                                  elevation: 8,
                                  textStyle: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ),
                              if (_permitirManual) ...[
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  onPressed: _mostrarDialogoMarcacionOffline,
                                  icon: const Icon(
                                    Icons.keyboard_alt_outlined,
                                    color: Colors.white70,
                                  ),
                                  label: const Text(
                                    'MARCAR CON CÉDULA (OFFLINE)',
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(
                                      color: Colors.white24,
                                      width: 2,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(30),
                                    ),
                                    textStyle: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),

          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: _state.mensajeColor.withOpacity(0.12),
              border: Border(
                top: BorderSide(
                  color: _state.mensajeColor.withOpacity(0.3),
                  width: 2,
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: SafeArea(
              child: _mostrarPanelSeleccion && _empleadoIdentificado != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '¡ROSTRO IDENTIFICADO!'.toUpperCase(),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _state.mensajeColor,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _empleadoIdentificado!.nombre,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        Text(
                          'CÉDULA: ${_empleadoIdentificado!.cedula}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 18),

                        Builder(
                          builder: (context) {
                            final yaTieneEntrada = _registrosHoy.any(
                              (r) =>
                                  r.tipo ==
                                      TipoRegistro.normal.name.toUpperCase() ||
                                  r.tipo ==
                                      TipoRegistro.retardo.name.toUpperCase(),
                            );
                            final yaTieneSalida = _registrosHoy.any(
                              (r) =>
                                  r.tipo ==
                                  TipoRegistro.salida.name.toUpperCase(),
                            );
                            final yaTieneAlmuerzo = _registrosHoy.any(
                              (r) =>
                                  r.tipo ==
                                  TipoRegistro.almuerzo.name.toUpperCase(),
                            );

                            String statusText = 'Secuencia: Esperando Entrada';
                            if (yaTieneEntrada)
                              statusText =
                                  'Secuencia: Dentro / Esperando Almuerzo o Salida';
                            if (yaTieneAlmuerzo)
                              statusText =
                                  'Secuencia: En Almuerzo / Esperando Retorno';
                            if (yaTieneSalida)
                              statusText = 'Secuencia: Jornada Finalizada';

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                statusText,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            );
                          },
                        ),

                        Builder(
                          builder: (context) {
                            final yaTieneEntrada = _registrosHoy.any(
                              (r) =>
                                  r.tipo ==
                                      TipoRegistro.normal.name.toUpperCase() ||
                                  r.tipo ==
                                      TipoRegistro.retardo.name.toUpperCase(),
                            );
                            final yaTieneSalida = _registrosHoy.any(
                              (r) =>
                                  r.tipo ==
                                  TipoRegistro.salida.name.toUpperCase(),
                            );

                            return Wrap(
                              spacing: 8,
                              runSpacing: 10,
                              alignment: WrapAlignment.center,
                              children: [
                                _buildBotonPanel(
                                  label: 'ENTRADA',
                                  icon: Icons.login_rounded,
                                  color: Colors.green,
                                  onPressed: (yaTieneEntrada || _procesando)
                                      ? null
                                      : () => _registrarMarcacionManual(
                                          TipoRegistro.normal,
                                        ),
                                ),
                                _buildBotonPanel(
                                  label: 'ALMUERZO',
                                  icon: Icons.restaurant_rounded,
                                  color: Colors.orange,
                                  onPressed:
                                      (!yaTieneEntrada ||
                                          yaTieneSalida ||
                                          _procesando)
                                      ? null
                                      : () => _registrarMarcacionManual(
                                          TipoRegistro.almuerzo,
                                        ),
                                ),
                                _buildBotonPanel(
                                  label: 'SALIDA',
                                  icon: Icons.logout_rounded,
                                  color: Colors.red,
                                  onPressed:
                                      (!yaTieneEntrada ||
                                          yaTieneSalida ||
                                          _procesando)
                                      ? null
                                      : () => _registrarMarcacionManual(
                                          TipoRegistro.salida,
                                        ),
                                ),
                                _buildBotonPanel(
                                  label: 'PERMISO',
                                  icon: Icons.card_membership_rounded,
                                  color: Colors.purple,
                                  onPressed: _procesando
                                      ? null
                                      : () => _registrarMarcacionManual(
                                          TipoRegistro.permiso,
                                        ),
                                ),
                                _buildBotonPanel(
                                  label: 'EXTRAS',
                                  icon: Icons.more_time_rounded,
                                  color: Colors.blue,
                                  onPressed: _procesando
                                      ? null
                                      : () => _registrarMarcacionManual(
                                          TipoRegistro.extras,
                                        ),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 12),

                        TextButton.icon(
                          onPressed: _procesando
                              ? null
                              : _cancelarFlujoMarcacion,
                          icon: const Icon(
                            Icons.cancel_outlined,
                            color: Colors.white54,
                            size: 16,
                          ),
                          label: const Text(
                            'No soy yo, Cancelar',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_state.procesando) ...[
                          const CircularProgressIndicator(
                            color: AppColors.info,
                          ),
                          const SizedBox(height: 16),
                        ] else ...[
                          Icon(
                            _state.empleadoNombre != null
                                ? Icons.check_circle_outline
                                : Icons.sensors_rounded,
                            size: 48,
                            color: _state.mensajeColor,
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(
                          _state.mensaje.toUpperCase(),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _state.mensajeColor,
                            letterSpacing: 1.2,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_state.empleadoNombre != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _state.empleadoNombre!,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'CÉDULA DE CIUDADANÍA: ${_state.empleadoCedula}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (_state.tipoRegistro != null) ...[
                            const SizedBox(height: 12),
                            Chip(
                              backgroundColor: _state.mensajeColor.withOpacity(
                                0.25,
                              ),
                              label: Text(
                                _getTipoRegistroLabel(_state.tipoRegistro!),
                                style: TextStyle(
                                  color: _state.mensajeColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              side: BorderSide(color: _state.mensajeColor),
                            ),
                          ],
                          if (_state.distancia != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Precisión facial: ${(100 - _state.distancia! * 100).toStringAsFixed(1)}% (dist. ${_state.distancia!.toStringAsFixed(3)})',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
