import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:io';
import 'dart:isolate';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

Future<Uint8List?> encodeBumpFrameTask(Map<String, dynamic> params) async {
  try {
    final int width = params['width'];
    final int height = params['height'];
    final Uint8List yPlane = params['yBytes'];
    final Uint8List uPlane = params['uBytes'];
    final Uint8List vPlane = params['vBytes'];
    final int yRowStride = params['yRowStride'];
    final int uvRowStride = params['uvRowStride'];
    final int uvPixelStride = params['uvPixelStride'];

    final double xScale = width / 640.0;
    final double yScale = height / 640.0;

    final rgbImage = img.Image(width: 640, height: 640);

    for (int py = 0; py < 640; py++) {
      final int srcY = (py * yScale).floor().clamp(0, height - 1);
      for (int px = 0; px < 640; px++) {
        final int srcX = (px * xScale).floor().clamp(0, width - 1);

        final int yIndex = srcY * yRowStride + srcX;
        final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

        final int yp = yPlane[yIndex];
        final int up = uPlane[uvIndex];
        final int vp = vPlane[uvIndex];

        final int r = (yp + (vp - 128) * 1436 ~/ 1024).clamp(0, 255);
        final int g = (yp - (up - 128) * 46549 ~/ 131072 - (vp - 128) * 93604 ~/ 131072).clamp(0, 255);
        final int b = (yp + (up - 128) * 1814 ~/ 1024).clamp(0, 255);

        final int outX = 639 - py;
        final int outY = px;
        rgbImage.setPixelRgb(outX, outY, r, g, b);
      }
    }

    return img.encodeJpg(rgbImage, quality: 70);
  } catch (e) {
    return null;
  }
}

// Global model bytes — isolate tarafından paylaşılır
Uint8List? globalModelBytes;

// Modelin gördüğü ham görüntüyü UI'da çizdirmek için
Uint8List? debugImageBytes;

// =============================================================================
// KALICI ISOLATE YÖNETİCİSİ
// =============================================================================
class _IsolateWorker {
  late Isolate _isolate;
  late ReceivePort _receivePort;
  late SendPort _sendPort;
  bool _isReady = false;
  Completer<void>? _readyCompleter;
  Completer<Map<String, dynamic>?>? _resultCompleter;

  Future<void> init() async {
    _readyCompleter = Completer<void>();
    _receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_isolateEntry, _receivePort.sendPort);

    _receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        _isReady = true;
        _readyCompleter?.complete();
      } else if (message is Map<String, dynamic> &&
          message['_initDone'] == true) {
        _resultCompleter?.complete(<String, dynamic>{});
        _resultCompleter = null;
      } else if (message is Map<String, dynamic>?) {
        _resultCompleter?.complete(message);
        _resultCompleter = null;
      }
    });

    await _readyCompleter!.future;
  }

  Future<void> initModel(Uint8List modelBytes, List<String> labels) async {
    if (!_isReady) return;
    _resultCompleter = Completer<Map<String, dynamic>?>();
    _sendPort.send({
      '_initModel': true,
      'modelBytes': modelBytes,
      'labels': labels,
    });
    await _resultCompleter!.future;
    _resultCompleter = null;
  }

  Future<Map<String, dynamic>?> process(Map<String, dynamic> params) async {
    if (!_isReady) return null;
    _resultCompleter = Completer<Map<String, dynamic>?>();
    _sendPort.send(params);
    return _resultCompleter!.future;
  }

  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
    _isReady = false;
  }
}

void _isolateEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  OrtSession? session;
  List<String> _labels = [];

  receivePort.listen((message) async {
    if (message is! Map<String, dynamic>) return;

    try {
      if (message['_initModel'] == true) {
        final Uint8List modelBytes = message['modelBytes'];
        _labels = List<String>.from(message['labels']);

        OrtEnv.instance.init();
        final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
        session = OrtSession.fromBuffer(modelBytes, opts);

        mainSendPort.send(<String, dynamic>{'_initDone': true});
        return;
      }

      if (session == null) {
        mainSendPort.send(null);
        return;
      }

      final result = _runInference(message, session!, _labels);
      mainSendPort.send(result);
    } catch (e) {
      print('Isolate hata: $e');
      mainSendPort.send(null);
    }
  });
}

// =============================================================================
// INFERENCE
// Tüm tespitler döndürülüyor — sadece saf gürültü filtreleniyor.
// =============================================================================
Map<String, dynamic>? _runInference(
  Map<String, dynamic> params,
  OrtSession session,
  List<String> labels,
) {
  final int width = params['width'];
  final int height = params['height'];
  final double speedKmh = (params['speedKmh'] as num?)?.toDouble() ?? 0.0;
  final bool hasGps = params['hasGps'] as bool? ?? false;

  final Uint8List yPlane = params['yBytes'];
  final Uint8List uPlane = params['uBytes'];
  final Uint8List vPlane = params['vBytes'];
  final int yRowStride = params['yRowStride'];
  final int uvRowStride = params['uvRowStride'];
  final int uvPixelStride = params['uvPixelStride'];

  final inputData = Float32List(1 * 3 * 640 * 640);

  final double xScale = width / 640.0;
  final double yScale = height / 640.0;

  const int rOffset = 0;
  const int gOffset = 640 * 640;
  const int bOffset = 640 * 640 * 2;

  for (int py = 0; py < 640; py++) {
    final int srcY = (py * yScale).floor().clamp(0, height - 1);

    for (int px = 0; px < 640; px++) {
      final int srcX = (px * xScale).floor().clamp(0, width - 1);

      final int yIndex = srcY * yRowStride + srcX;
      final int uvIndex =
          (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

      final int yp = yPlane[yIndex];
      final int up = uPlane[uvIndex];
      final int vp = vPlane[uvIndex];

      final int r = (yp + (vp - 128) * 1436 ~/ 1024).clamp(0, 255);
      final int g = (yp -
              (up - 128) * 46549 ~/ 131072 -
              (vp - 128) * 93604 ~/ 131072)
          .clamp(0, 255);
      final int b = (yp + (up - 128) * 1814 ~/ 1024).clamp(0, 255);

      final int outX = 639 - py;
      final int outY = px;
      final int outIdx = outY * 640 + outX;

      inputData[rOffset + outIdx] = r / 255.0;
      inputData[gOffset + outIdx] = g / 255.0;
      inputData[bOffset + outIdx] = b / 255.0;
    }
  }

  // skipInference: debug görüntüsü için
  if (params['skipInference'] == true) {
    try {
      final rgbImage = img.Image(width: 640, height: 640);
      for (int py = 0; py < 640; py++) {
        for (int px = 0; px < 640; px++) {
          final int idx = py * 640 + px;
          final int r = (inputData[rOffset + idx] * 255).round().clamp(0, 255);
          final int g = (inputData[gOffset + idx] * 255).round().clamp(0, 255);
          final int b = (inputData[bOffset + idx] * 255).round().clamp(0, 255);
          rgbImage.setPixelRgb(px, py, r, g, b);
        }
      }
      final jpegBytes = img.encodeJpg(rgbImage, quality: 75);
      return {'jpegBytes': jpegBytes, 'detections': <Map<String, dynamic>>[], 'blurSkipped': false};
    } catch (e) {
      print('Bump JPEG encode hata: $e');
      return null;
    }
  }

  final inputOrt =
      OrtValueTensor.createTensorWithDataList(inputData, [1, 3, 640, 640]);
  final runOptions = OrtRunOptions();
  final outputs = session.run(runOptions, {'images': inputOrt});

  // Tüm tespitleri topla — sadece tek en iyiyi değil
  final List<Map<String, dynamic>> detections = [];

  if (outputs.isNotEmpty && outputs[0] != null) {
    final outputData = outputs[0]!.value as List<List<List<double>>>;

    for (var det in outputData[0]) {
      final double confidence = det[4];

      // Sadece saf gürültüyü kes — eşik çok düşük tutuldu
      if (confidence <= 0.03) continue;

      final classScores = det.sublist(5);
      int maxIdx = 0;
      double maxScore = classScores[0];

      final int classLimit = math.min(classScores.length, labels.length);

      for (int i = 1; i < classLimit; i++) {
        if (classScores[i] > maxScore) {
          maxScore = classScores[i];
          maxIdx = i;
        }
      }

      final double finalConf = confidence * maxScore;

      // Çok düşük tut — model ne gördüyse göster
      if (finalConf > 0.02) {
        detections.add({
          'detectedClass': maxIdx < labels.length ? labels[maxIdx] : 'Unknown',
          'confidence': confidence,
          'finalConfidence': finalConf,
          'x': det[0],
          'y': det[1],
          'w': det[2],
          'h': det[3],
        });
      }
    }
  }

  inputOrt.release();
  runOptions.release();
  for (final o in outputs) {
    o?.release();
  }

  // JPEG: en az 1 tespit varsa oluştur
  Uint8List? jpegBytes;
  if (detections.isNotEmpty) {
    try {
      final rgbImage = img.Image(width: 640, height: 640);

      for (int py = 0; py < 640; py++) {
        for (int px = 0; px < 640; px++) {
          final int idx = py * 640 + px;
          final int r =
              (inputData[rOffset + idx] * 255).round().clamp(0, 255);
          final int g =
              (inputData[gOffset + idx] * 255).round().clamp(0, 255);
          final int b =
              (inputData[bOffset + idx] * 255).round().clamp(0, 255);

          rgbImage.setPixelRgb(px, py, r, g, b);
        }
      }

      jpegBytes = img.encodeJpg(rgbImage, quality: 75);
    } catch (e) {
      print('JPEG encode hata: $e');
    }
  }

  return {
    'detections': detections,
    'jpegBytes': jpegBytes,
    'blurSkipped': false,
  };
}

// =============================================================================
// ANA WIDGET
// =============================================================================
class OpenCam extends StatefulWidget {
  const OpenCam({super.key});

  @override
  State<OpenCam> createState() => OpenCamState();
}

class OpenCamState extends State<OpenCam> with WidgetsBindingObserver {
  CameraController? cameraController;
  CameraImage? imgCamera;
  List<String> labels = [];

  bool isWorking = false;
  String result = '';
  int lastProcessingTime = 0;

  DateTime sessionStartTime = DateTime.now();
  List<Map<String, dynamic>> detectionBuffer = [];
  double cameraCalibrationFactor = 1200.0;

  Position? currentPosition;
  StreamSubscription<Position>? positionStream;
  double currentSpeedKmh = 0.0;
  String locationStatus = 'Searching location...';

  double _minAvailableZoom = 1.0;
  double _maxAvailableZoom = 1.0;
  double _currentZoomLevel = 1.0;
  double _baseZoomLevel = 1.0;

  bool _showZoomSlider = false;
  bool _showBumpSlider = false;

  StreamSubscription<AccelerometerEvent>? accelStream;
  List<Map<String, dynamic>> bumpBuffer = [];
  double lastVibrationMagnitude = 0.0;
  double bumpThreshold = 10.0;

  bool _showHorizonGuide = true;
  Timer? _horizonTimer;
  Timer? _bumpWarningTimer;

  Database? _sessionDatabase;

  // Tek box yerine liste
  List<Map<String, dynamic>> activeBoxes = [];

  final _IsolateWorker _worker = _IsolateWorker();
  bool _workerReady = false;
  bool _isEncodingBump = false;

  int _blurSkippedCount = 0;
  int _totalFrameCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();

    _horizonTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() => _showHorizonGuide = false);
      }
    });
  }

  Future<void> _initAll() async {
    await _initDB();
    await _loadModel();
    await _worker.init();
    await _worker.initModel(globalModelBytes!, labels);
    _workerReady = true;

    _initializeCamera();
    _initSensors();
    _initLocation();
  }

  Future<void> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'roadguard_database.db');

    _sessionDatabase = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE session_detections(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT,
  defectType TEXT,
  confidence REAL,
  latitude REAL,
  longitude REAL,
  speedKmh REAL,
  distanceToDefect REAL,
  isSensorConfirmed INTEGER,
  imagePath TEXT
)
''');

        await db.execute('''
CREATE TABLE session_vibrations(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT,
  latitude REAL,
  longitude REAL,
  magnitude REAL
)
''');
      },
    );
  }

  Future<void> _loadModel() async {
    if (globalModelBytes != null) return;

    labels = ['D00', 'D10', 'D20', 'D40'];

    final raw = await rootBundle.load('assets/road_damage.onnx');
    globalModelBytes = raw.buffer.asUint8List();
  }

  void _initializeCamera() async {
    final cameras = await availableCameras();

    cameraController = CameraController(
      cameras[0],
      ResolutionPreset.medium,
    );

    await cameraController!.initialize();

    if (!mounted) return;

    await cameraController!.setFocusMode(FocusMode.auto);

    _minAvailableZoom = await cameraController!.getMinZoomLevel();
    _maxAvailableZoom = await cameraController!.getMaxZoomLevel();

    _currentZoomLevel = _minAvailableZoom < _maxAvailableZoom
        ? _minAvailableZoom + (_maxAvailableZoom - _minAvailableZoom) * 0.15
        : _minAvailableZoom;

    await cameraController!.setZoomLevel(_currentZoomLevel);

    setState(() {});

    cameraController!.startImageStream((image) {
      if (!isWorking && _workerReady) {
        imgCamera = image;
        runModelOnStreamFrame();
      }
    });
  }

  void _initSensors() {
    accelStream = accelerometerEventStream().listen((event) {
      if (!mounted) return;

      final double totalAccel = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      final double netMagnitude = (totalAccel - 9.81).abs();

      lastVibrationMagnitude = netMagnitude;

      if (netMagnitude > bumpThreshold) {
        _recordPhysicalBump(netMagnitude);
      }
    });
  }

  void _recordPhysicalBump(double magnitude) async {
    if (bumpBuffer.isNotEmpty) {
      final last = bumpBuffer.last['time'] as DateTime;
      if (DateTime.now().difference(last).inMilliseconds < 1000) return;
    }

    final double? lat = currentPosition?.latitude;
    final double? lng = currentPosition?.longitude;

    if (_sessionDatabase != null) {
      await _sessionDatabase!.insert('session_vibrations', {
        'timestamp': DateTime.now().toIso8601String(),
        'latitude': lat,
        'longitude': lng,
        'magnitude': magnitude,
      });

      String? savedImagePath;

      if (imgCamera != null && !_isEncodingBump) {
        _isEncodingBump = true;
        try {
          final planes = imgCamera!.planes;
          final currentJpegBytes = await compute(encodeBumpFrameTask, {
            'width': imgCamera!.width,
            'height': imgCamera!.height,
            'yBytes': planes[0].bytes,
            'uBytes': planes[1].bytes,
            'vBytes': planes[2].bytes,
            'yRowStride': planes[0].bytesPerRow,
            'uvRowStride': planes[1].bytesPerRow,
            'uvPixelStride': planes[1].bytesPerPixel ?? 1,
          });

          if (currentJpegBytes != null) {
            final dbPath = await getDatabasesPath();
            final imgDir = Directory(p.join(dbPath, 'defect_images'));
            if (!await imgDir.exists()) await imgDir.create(recursive: true);
            final imgFile = File(p.join(imgDir.path, 'bump_sensor_${DateTime.now().millisecondsSinceEpoch}.jpg'));
            await imgFile.writeAsBytes(currentJpegBytes);
            savedImagePath = imgFile.path;
          }
        } catch (e) {
          print('Bump Isolate Görüntü kayıt hatası: $e');
        }
        _isEncodingBump = false;
      }

      await _sessionDatabase!.insert('session_detections', {
        'timestamp': DateTime.now().toIso8601String(),
        'defectType': 'Bump (Sensor)',
        'confidence': 1.0,
        'latitude': lat,
        'longitude': lng,
        'speedKmh': currentSpeedKmh,
        'distanceToDefect': 0.0,
        'isSensorConfirmed': 1,
        'imagePath': savedImagePath,
      });
    }

    bumpBuffer.add({
      'time': DateTime.now(),
      'latitude': lat ?? 0.0,
      'longitude': lng ?? 0.0,
      'magnitude': magnitude,
    });

    if (bumpBuffer.length > 20) {
      bumpBuffer.removeAt(0);
    }

    final locLine = lat != null
        ? 'Vehicle: ${lat.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}'
        : 'Vehicle Location: No GPS signal';

    setState(() {
      result =
          '⚠️ BUMP DETECTED (Sensor)!\nMagnitude: ${magnitude.toStringAsFixed(1)}\n$locLine\nSpeed: ${currentSpeedKmh.toStringAsFixed(1)} km/h';
      activeBoxes = [];
    });

    _bumpWarningTimer?.cancel();
    _bumpWarningTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && result.startsWith('⚠️')) {
        setState(() {
          result = '';
        });
      }
    });
  }

  Future<void> _initLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => locationStatus = 'Location service disabled.');
      return;
    }

    var perm = await Geolocator.checkPermission();

    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => locationStatus = 'Location permission denied.');
      return;
    }

    setState(() => locationStatus = 'Locating...');

    try {
      currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
      );
    } catch (_) {}

    setState(() {
      currentSpeedKmh = 50.0;
      locationStatus = 'TEST MODE (50 km/h)';
    });
  }

  Future<void> runModelOnStreamFrame() async {
    if (imgCamera == null || globalModelBytes == null || !_workerReady) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    const int frameIntervalMs = 0;

    if (now - lastProcessingTime < frameIntervalMs) return;
    if (isWorking) return;

    isWorking = true;
    lastProcessingTime = now;

    try {
      final planes = imgCamera!.planes;

      final workerResult = await _worker.process({
        'width': imgCamera!.width,
        'height': imgCamera!.height,
        'yBytes': planes[0].bytes,
        'uBytes': planes[1].bytes,
        'vBytes': planes[2].bytes,
        'yRowStride': planes[0].bytesPerRow,
        'uvRowStride': planes[1].bytesPerRow,
        'uvPixelStride': planes[1].bytesPerPixel ?? 1,
        'speedKmh': currentSpeedKmh,
        'hasGps': currentPosition != null,
      });

      if (!mounted) {
        isWorking = false;
        return;
      }

      if (workerResult == null) {
        isWorking = false;
        return;
      }

      _totalFrameCount++;

      if (workerResult['blurSkipped'] == true) {
        _blurSkippedCount++;
        isWorking = false;
        return;
      }

      final List<Map<String, dynamic>> detections =
          List<Map<String, dynamic>>.from(workerResult['detections'] ?? []);
      final Uint8List? jpegBytes = workerResult['jpegBytes'] as Uint8List?;

      if (jpegBytes != null && mounted) {
        setState(() => debugImageBytes = jpegBytes);
      }

      if (detections.isNotEmpty) {
        // DB ve konum hesabı için en yüksek confidence'lı tespiti kullan
        final best = detections.reduce((a, b) =>
            (a['finalConfidence'] as double) > (b['finalConfidence'] as double)
                ? a
                : b);

        String detClass = best['detectedClass'];
        double finalConf = best['finalConfidence'];

        final double bx = best['x'];
        final double by = best['y'];

        double distToDefect = 0.0;
        ll.LatLng? defectLoc;
        bool sensorCorrelated = false;

        if (currentPosition != null) {
          final bottomY = by + (best['h'] as double) / 2;

          distToDefect = bottomY > 320
              ? cameraCalibrationFactor / (bottomY - 320)
              : 50.0;

          final offset =
              (distToDefect - (currentSpeedKmh / 3.6)).clamp(0.0, double.infinity);

          final tool = ll.Distance();
          final me = ll.LatLng(
            currentPosition!.latitude,
            currentPosition!.longitude,
          );

          defectLoc = tool.offset(me, offset, currentPosition!.heading);

          for (var bump in bumpBuffer) {
            final bl = ll.LatLng(
              bump['latitude'],
              bump['longitude'],
            );

            if (tool.as(ll.LengthUnit.Meter, bl, defectLoc) < 15.0) {
              sensorCorrelated = true;
              finalConf = (finalConf + 0.20).clamp(0.0, 1.0);
              break;
            }
          }
        }

        if (sensorCorrelated) {
          detClass += ' (SENSOR CONFIRMED ✅)';
        }

        String? savedImagePath;

        if (jpegBytes != null) {
          try {
            final dbPath = await getDatabasesPath();
            final imgDir = Directory(p.join(dbPath, 'defect_images'));

            if (!await imgDir.exists()) {
              await imgDir.create(recursive: true);
            }

            final imgFile = File(
              p.join(
                imgDir.path,
                'defect_${DateTime.now().millisecondsSinceEpoch}.jpg',
              ),
            );

            await imgFile.writeAsBytes(jpegBytes);
            savedImagePath = imgFile.path;
          } catch (e) {
            print('Görüntü kayıt hatası: $e');
          }
        }

        if (_sessionDatabase != null) {
          await _sessionDatabase!.insert('session_detections', {
            'timestamp': DateTime.now().toIso8601String(),
            'defectType': detClass,
            'confidence': finalConf,
            'latitude': defectLoc?.latitude,
            'longitude': defectLoc?.longitude,
            'speedKmh': currentSpeedKmh,
            'distanceToDefect': distToDefect,
            'isSensorConfirmed': sensorCorrelated ? 1 : 0,
            'imagePath': savedImagePath,
          });
        }

        final posText = currentPosition != null && defectLoc != null
            ? 'Vehicle: ${currentPosition!.latitude.toStringAsFixed(5)}, ${currentPosition!.longitude.toStringAsFixed(5)}\n'
                'Speed: ${currentSpeedKmh.toStringAsFixed(1)} km/h\n'
                'Distance: ${distToDefect.toStringAsFixed(1)} m\n\n'
                '📍 Defect: ${defectLoc.latitude.toStringAsFixed(5)}, ${defectLoc.longitude.toStringAsFixed(5)}'
            : '⚠️ No GPS — Test mode active';

        // Tüm box'ları UI için hazırla
        final List<Map<String, dynamic>> boxes = detections.map((d) {
          final double conf = d['finalConfidence'] as double;
          final String cls = d['detectedClass'] as String;
          final isSensor = sensorCorrelated && d == best;
          final label = isSensor
              ? '$cls (SENSOR ✅) ${(conf * 100).toStringAsFixed(1)}%'
              : '$cls ${(conf * 100).toStringAsFixed(1)}%';
          return {
            'x': d['x'],
            'y': d['y'],
            'w': d['w'],
            'h': d['h'],
            'label': label,
            'isBest': d == best,
          };
        }).toList();

        setState(() {
          result =
              '🚧 $detClass\nConfidence: ${(finalConf * 100).toStringAsFixed(1)}%\n\n$posText';
          activeBoxes = boxes;
        });
      } else {
        setState(() {
          result = '';
          activeBoxes = [];
        });
      }
    } catch (e) {
      print('Frame işleme hatası: $e');
    }

    isWorking = false;
  }

  @override
  void dispose() {
    _horizonTimer?.cancel();
    _bumpWarningTimer?.cancel();
    accelStream?.cancel();
    positionStream?.cancel();

    if (cameraController?.value.isInitialized == true) {
      cameraController!.stopImageStream();
      cameraController!.dispose();
    }

    _worker.dispose();
    _sessionDatabase?.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.orangeAccent),
              SizedBox(height: 20),
              Text(
                'Starting Camera & AI Model...',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          SizedBox.expand(
            child: GestureDetector(
              onTap: () {
                if (_showZoomSlider || _showBumpSlider) {
                  setState(() {
                    _showZoomSlider = false;
                    _showBumpSlider = false;
                  });
                }
              },
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: cameraController!.value.previewSize?.height ?? size.width,
                  height: cameraController!.value.previewSize?.width ?? size.height,
                  child: CameraPreview(cameraController!),
                ),
              ),
            ),
          ),

          AnimatedOpacity(
            opacity: _showHorizonGuide ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 800),
            child: IgnorePointer(
              child: Stack(
                children: [
                  Positioned(
                    top: size.height * 0.33,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 2,
                      color: Colors.yellowAccent.withValues(alpha: 0.6),
                    ),
                  ),
                  Positioned(
                    top: size.height * 0.33 - 25,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text(
                          'ALIGN HORIZON HERE',
                          style: TextStyle(
                            color: Colors.yellowAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Positioned(
            top: 40,
            left: 20,
            child: _circleButton(
              Icons.arrow_back,
              () => Navigator.pop(context),
            ),
          ),

          // Zoom button
          Positioned(
            top: 40,
            right: 80,
            child: _circleButton(
              Icons.camera_alt,
              () {
                setState(() {
                  _showZoomSlider = !_showZoomSlider;
                  _showBumpSlider = false;
                });
              },
              Colors.lightBlueAccent,
            ),
          ),

          // Sensitivity button
          Positioned(
            top: 40,
            right: 140,
            child: _circleButton(
              Icons.vibration,
              () {
                setState(() {
                  _showBumpSlider = !_showBumpSlider;
                  _showZoomSlider = false;
                });
              },
              Colors.redAccent,
            ),
          ),

          Positioned(
            top: 40,
            right: 20,
            child: _circleButton(
              Icons.flip_camera_ios,
              _flipCamera,
            ),
          ),

          // Zoom Slider Overlay
          if (_showZoomSlider)
            Positioned(
              top: 100,
              right: 20,
              child: Container(
                width: 60,
                height: 250,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Column(
                  children: [
                    Text(
                      '${_currentZoomLevel.toStringAsFixed(1)}x',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Slider(
                          value: _currentZoomLevel,
                          min: _minAvailableZoom,
                          max: _maxAvailableZoom,
                          activeColor: Colors.orangeAccent,
                          inactiveColor: Colors.white24,
                          onChanged: (val) async {
                            setState(() => _currentZoomLevel = val);
                            try {
                              await cameraController!.setZoomLevel(val);
                            } catch (_) {}
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Bump Sensitivity Slider Overlay
          if (_showBumpSlider)
            Positioned(
              top: 100,
              right: 80,
              child: Container(
                width: 60,
                height: 250,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Column(
                  children: [
                    Text(
                      bumpThreshold.toStringAsFixed(1),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Slider(
                          value: bumpThreshold,
                          min: 1.0,
                          max: 30.0,
                          activeColor: Colors.redAccent,
                          inactiveColor: Colors.white24,
                          onChanged: (val) {
                            setState(() => bumpThreshold = val);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ---------------------------------------------------------------
          // TÜM TESPİTLERİ ÇİZ
          // Her tespit için ayrı bir bounding box ve label göster.
          // En yüksek confidence'lı (best) box yeşil, diğerleri sarı.
          // ---------------------------------------------------------------
          if (activeBoxes.isNotEmpty)
            ...activeBoxes.map((box) {
              final sw = size.width;
              final sh = size.height;

              final double rawX = box['x'] as double;
              final double rawY = box['y'] as double;
              final double rawW = box['w'] as double;
              final double rawH = box['h'] as double;

              final rX = rawX > 2 ? rawX / 640 : rawX;
              final rY = rawY > 2 ? rawY / 640 : rawY;
              final rW = rawW > 2 ? rawW / 640 : rawW;
              final rH = rawH > 2 ? rawH / 640 : rawH;

              final fw = (rW * sw).clamp(20.0, sw);
              final fh = (rH * sh).clamp(20.0, sh);

              final bool isBest = box['isBest'] as bool;
              final Color boxColor = isBest ? Colors.greenAccent : Colors.yellowAccent;

              return Positioned(
                left: (rX * sw) - fw / 2,
                top: (rY * sh) - fh / 2,
                width: fw,
                height: fh,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: boxColor,
                      width: isBest ? 3 : 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: boxColor.withValues(alpha: 0.3),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: boxColor.withValues(alpha: 0.8),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        box['label'] as String,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),

          Positioned(
            bottom: 90,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        currentPosition != null
                            ? Icons.gps_fixed
                            : Icons.gps_not_fixed,
                        color: currentPosition != null
                            ? Colors.greenAccent
                            : Colors.orangeAccent,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        currentPosition != null
                            ? '${currentSpeedKmh.toStringAsFixed(0)} km/h'
                            : 'TEST MODE',
                        style: TextStyle(
                          color: currentPosition != null
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (currentPosition != null && _totalFrameCount > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Blur skip: ${(_blurSkippedCount / _totalFrameCount * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          if (debugImageBytes != null)
            Positioned(
              bottom: 150,
              left: 16,
              width: 120,
              height: 120,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.redAccent,
                    width: 3,
                  ),
                  color: Colors.black,
                ),
                child: Image.memory(
                  debugImageBytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),

          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.7),
                  foregroundColor: Colors.orangeAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
                onPressed: () => Navigator.pushNamed(context, '/history'),
                icon: const Icon(Icons.history),
                label: const Text(
                  'View Records',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),

          if (result.isNotEmpty)
            Positioned(
              top: 120,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 40,
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Text(
                        result,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onPressed, [Color iconColor = Colors.white]) {
    return IconButton(
      onPressed: onPressed,
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: iconColor,
          size: 24,
        ),
      ),
    );
  }

  Future<void> _flipCamera() async {
    final cameras = await availableCameras();

    if (cameras.length < 2) return;

    final current = cameraController!.description;

    final next = cameras.firstWhere(
      (c) => c != current,
      orElse: () => cameras[0],
    );

    await cameraController!.dispose();

    cameraController = CameraController(
      next,
      ResolutionPreset.medium,
    );

    await cameraController!.initialize();

    if (!mounted) return;

    setState(() {});

    cameraController!.startImageStream((image) {
      if (!isWorking && _workerReady) {
        imgCamera = image;
        runModelOnStreamFrame();
      }
    });
  }
}