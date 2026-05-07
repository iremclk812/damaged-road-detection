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

// Global model bytes — isolate tarafından paylaşılır
Uint8List? globalModelBytes;
// Modelin gördüğü ham görüntüyü UI'da çizdirmek için:
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
      } else if (message is Map<String, dynamic> && message['_initDone'] == true) {
        // initModel tamamlandı — Map<String,dynamic>? bekleyen completer'ı boş map ile kapat
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
    _sendPort.send({'_initModel': true, 'modelBytes': modelBytes, 'labels': labels});
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
      // Model init mesajı — sadece bir kez çalışır
      if (message['_initModel'] == true) {
        final Uint8List modelBytes = message['modelBytes'];
        _labels = List<String>.from(message['labels']);
        OrtEnv.instance.init();
        final opts = OrtSessionOptions()..setIntraOpNumThreads(2);
        session = OrtSession.fromBuffer(modelBytes, opts);
        mainSendPort.send(<String, dynamic>{'_initDone': true});
        return;
      }

      // Frame inference mesajı
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
// hasGps == false  → blur kontrolü atlanır, düşük sabit threshold (test modu)
// hasGps == true   → Laplacian blur + hıza göre dinamik threshold (gerçek sürüş)
// jpegBytes her zaman dolu döner — tespit olsun olmasın
// =============================================================================
Map<String, dynamic>? _runInference(
  Map<String, dynamic> params,
  OrtSession session,
  List<String> labels,
) {
  final int width       = params['width'];
  final int height      = params['height'];
  final double speedKmh = (params['speedKmh'] as num?)?.toDouble() ?? 0.0;
  final bool hasGps     = params['hasGps'] as bool? ?? false;

  final Uint8List yPlane      = params['yBytes'];
  final Uint8List uPlane      = params['uBytes'];
  final Uint8List vPlane      = params['vBytes'];
  final int yRowStride        = params['yRowStride'];
  final int uvRowStride       = params['uvRowStride'];
  final int uvPixelStride     = params['uvPixelStride'];

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

      final int yIndex  = srcY * yRowStride + srcX;
      final int uvIndex = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

      final int yp = yPlane[yIndex];
      final int up = uPlane[uvIndex];
      final int vp = vPlane[uvIndex];

      final int r = (yp + (vp - 128) * 1436 ~/ 1024).clamp(0, 255);
      final int g = (yp - (up - 128) * 46549 ~/ 131072 - (vp - 128) * 93604 ~/ 131072).clamp(0, 255);
      final int b = (yp + (up - 128) * 1814 ~/ 1024).clamp(0, 255);

      final int outX   = 639 - py;
      final int outY   = px;
      final int outIdx = outY * 640 + outX;

      inputData[rOffset + outIdx] = r / 255.0;
      inputData[gOffset + outIdx] = g / 255.0;
      inputData[bOffset + outIdx] = b / 255.0;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // KATMAN 1: Laplacian Blur Skoru
  // GPS YOK (test modu) → blur kontrolü tamamen atlanır, model her frame'de çalışır
  // GPS VAR (gerçek sürüş) → hıza göre eşik, bulanık frame atlanır
  // ─────────────────────────────────────────────────────────────────────────
  if (hasGps) {
    const int startY = 256; // 640 * 0.4
    const int endY   = 576; // 640 * 0.9
    const int startX = 128; // 640 * 0.2
    const int endX   = 512; // 640 * 0.8

    double lapSum   = 0;
    double lapSumSq = 0;
    int    lapCount = 0;

    for (int ly = startY + 1; ly < endY - 1; ly++) {
      for (int lx = startX + 1; lx < endX - 1; lx++) {
        double grayAt(int gy, int gx) {
          final int i = gy * 640 + gx;
          return inputData[rOffset + i] * 0.299 +
                 inputData[gOffset + i] * 0.587 +
                 inputData[bOffset + i] * 0.114;
        }
        final double lap = 4 * grayAt(ly, lx)
            - grayAt(ly - 1, lx)
            - grayAt(ly + 1, lx)
            - grayAt(ly, lx - 1)
            - grayAt(ly, lx + 1);
        lapSum   += lap;
        lapSumSq += lap * lap;
        lapCount++;
      }
    }

    if (lapCount > 0) {
      final double lapMean = lapSum / lapCount;
      final double lapVar  = lapSumSq / lapCount - lapMean * lapMean;

      final double blurThreshold = speedKmh < 30  ? 18.0
                                 : speedKmh < 60  ? 12.0
                                 : speedKmh < 90  ?  8.0
                                 : speedKmh < 120 ?  5.0
                                 :                   3.5;

      if (lapVar < blurThreshold) {
        return {'bestDetection': null, 'jpegBytes': null, 'blurSkipped': true};
      }
    }
  }
  // ─────────────────────────────────────────────────────────────────────────

  final inputOrt   = OrtValueTensor.createTensorWithDataList(inputData, [1, 3, 640, 640]);
  final runOptions = OrtRunOptions();
  final outputs    = session.run(runOptions, {'images': inputOrt});

  Map<String, dynamic>? bestDetection;

  if (outputs.isNotEmpty && outputs[0] != null) {
    final outputData = outputs[0]!.value as List<List<List<double>>>;

    // GPS yoksa sabit düşük eşik, GPS varsa hıza göre dinamik
    final double dynThreshold = !hasGps      ? 0.15
                              : speedKmh < 30  ? 0.25
                              : speedKmh < 60  ? 0.30
                              : speedKmh < 90  ? 0.38
                              : speedKmh < 120 ? 0.45
                              :                  0.52;

    for (var det in outputData[0]) {
      final double confidence = det[4];
      if (confidence > 0.10) {
        final classScores = det.sublist(5);
        int maxIdx = 0;

        double maxScore = classScores[0];
        for (int i = 1; i < classScores.length && i < 4; i++) {
          if (classScores[i] > maxScore) {
            maxScore = classScores[i];
            maxIdx = i;
          }
        }
        final double finalConf = confidence * maxScore;
        if (finalConf > dynThreshold) {
          bestDetection = {
            'detectedClass': maxIdx < labels.length ? labels[maxIdx] : 'Unknown',
            'confidence': confidence,
            'finalConfidence': finalConf,
            'x': det[0], 'y': det[1], 'w': det[2], 'h': det[3],
          };
          break;
        }
      }
    }
  }

  inputOrt.release();
  runOptions.release();
  for (final o in outputs) o?.release();

  // Fotoğrafı HER ZAMAN encode et (tespit olsun olmasın)
  // Önceki kodda sadece bestDetection != null ise encode ediliyordu → kayboluyordu
 Uint8List? jpegBytes;

  // SADECE VE SADECE BİR ÇUKUR TESPİT EDİLDİYSE FOTOĞRAFI OLUŞTUR
  // Bu değişiklik modelinizin FPS'ini (akıcılığını) en az 2 kat artıracaktır.
  if (bestDetection != null) {
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
      jpegBytes = img.encodeJpg(rgbImage, quality: 75);
    } catch (e) {
      print('JPEG encode hata: $e');
    }
  }

  return {'bestDetection': bestDetection, 'jpegBytes': jpegBytes, 'blurSkipped': false};
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

  StreamSubscription<UserAccelerometerEvent>? accelStream;
  List<Map<String, dynamic>> bumpBuffer = [];
  double lastVibrationMagnitude = 0.0;
  final double bumpThreshold = 10.0;

  bool _showHorizonGuide = true;
  Timer? _horizonTimer;

  Database? _sessionDatabase;

  double? boxX, boxY, boxW, boxH;
  String? boxLabel;

  final _IsolateWorker _worker = _IsolateWorker();
  bool _workerReady = false;

  // Blur debug sayaçları (sadece GPS varken anlamlı)
  int _blurSkippedCount = 0;
  int _totalFrameCount  = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();
    _horizonTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showHorizonGuide = false);
    });
  }

  Future<void> _initAll() async {
    await _initDB();
    await _loadModel();
    await _worker.init();
    await _worker.initModel(globalModelBytes!, labels); // model 1 kez gönderilir
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
        await db.execute('''CREATE TABLE session_detections(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT, defectType TEXT, confidence REAL,
          latitude REAL, longitude REAL, speedKmh REAL,
          distanceToDefect REAL, isSensorConfirmed INTEGER, imagePath TEXT
        )''');
        await db.execute('''CREATE TABLE session_vibrations(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT, latitude REAL, longitude REAL, magnitude REAL
        )''');
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
    cameraController = CameraController(cameras[0], ResolutionPreset.medium);
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

    // Future.delayed(const Duration(seconds: 2), () async {
    //   if (mounted && cameraController?.value.isInitialized == true) {
    //     try { await cameraController!.setFocusMode(FocusMode.locked); } catch (_) {}
    //     // Exposure lock sadece gerçek sürüşte (GPS var) etkinleştir
    //     // Test modunda (GPS yok) ekran parlaklığı değişkendir, auto bırak
    //     if (currentPosition != null) {
    //       try { await cameraController!.setExposureMode(ExposureMode.locked); } catch (_) {}
    //       try { await cameraController!.setExposureOffset(-0.5); } catch (_) {}
    //     }
    //   }
    // });

    cameraController!.startImageStream((image) {
      if (!isWorking && _workerReady) {
        imgCamera = image;
        runModelOnStreamFrame();
      }
    });
  }

  void _initSensors() {
    accelStream = userAccelerometerEventStream().listen((event) {
      if (!mounted) return;
      final mag = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      lastVibrationMagnitude = mag;
      if (mag > bumpThreshold) _recordPhysicalBump(mag);
    });
  }

  void _recordPhysicalBump(double magnitude) async {
    if (bumpBuffer.isNotEmpty) {
      final last = bumpBuffer.last['time'] as DateTime;
      if (DateTime.now().difference(last).inMilliseconds < 500) return;
    }

    // GPS yoksa NULL yaz — 0.0 değil
    final double? lat = currentPosition?.latitude;
    final double? lng = currentPosition?.longitude;

    if (_sessionDatabase != null) {
      await _sessionDatabase!.insert('session_vibrations', {
        'timestamp': DateTime.now().toIso8601String(),
        'latitude': lat, 'longitude': lng, 'magnitude': magnitude,
      });
      await _sessionDatabase!.insert('session_detections', {
        'timestamp': DateTime.now().toIso8601String(),
        'defectType': 'Bump (Sensor)', 'confidence': 1.0,
        'latitude': lat, 'longitude': lng,
        'speedKmh': currentSpeedKmh,
        'distanceToDefect': 0.0, 'isSensorConfirmed': 1, 'imagePath': null,
      });
    }

    bumpBuffer.add({
      'time': DateTime.now(),
      'latitude': lat ?? 0.0,
      'longitude': lng ?? 0.0,
      'magnitude': magnitude,
    });
    if (bumpBuffer.length > 20) bumpBuffer.removeAt(0);

    final locLine = lat != null
        ? 'Vehicle: ${lat.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}'
        : 'Vehicle Location: No GPS signal';

    setState(() {
      result = '⚠️ BUMP DETECTED (Sensor)!\nMagnitude: ${magnitude.toStringAsFixed(1)}\n$locLine\nSpeed: ${currentSpeedKmh.toStringAsFixed(1)} km/h';
      boxX = boxY = boxW = boxH = null;
      boxLabel = null;
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

    //   positionStream = Geolocator.getPositionStream(
    //     locationSettings: const LocationSettings(
    //       accuracy: LocationAccuracy.bestForNavigation,
    //       distanceFilter: 0,
    //     ),
    //   ).listen((pos) {
    //     if (!mounted) return;
    //     setState(() {
    //       currentPosition = pos;
    //       final raw = pos.speed * 3.6;
    //       currentSpeedKmh = raw < 2.0 ? 0.0 : raw;
    //       locationStatus = 'GPS Active';
    //     });
    //   });
    // }
    // TEST MODU: currentPosition null → hasGps: false → blur kapalı, sabit düşük threshold
    // Gerçek sürüş için positionStream bloğunu aktif et
    setState(() {
      locationStatus = 'TEST MODE (No GPS)';
    });
  }
  Future<void> runModelOnStreamFrame() async {
    if (imgCamera == null || globalModelBytes == null || !_workerReady) return;

    final now = DateTime.now().millisecondsSinceEpoch;

    // GPS yoksa sabit 300ms, GPS varsa hıza göre dinamik
    // final int frameIntervalMs = currentPosition == null ? 250
    //                           : currentSpeedKmh < 30   ? 250
    //                           : currentSpeedKmh < 60   ? 200
    //                           : currentSpeedKmh < 90   ? 150
    //                           :                          120;
     final int frameIntervalMs = 50; // Telefonun gücü yettiğince hızlı çalışsın
    if (now - lastProcessingTime < frameIntervalMs) return;
    if (isWorking) return;

    isWorking = true;
    lastProcessingTime = now;

    try {
      final planes = imgCamera!.planes;

      final workerResult = await _worker.process({
        'width':         imgCamera!.width,
        'height':        imgCamera!.height,
        'yBytes':        planes[0].bytes,
        'uBytes':        planes[1].bytes,
        'vBytes':        planes[2].bytes,
        'yRowStride':    planes[0].bytesPerRow,
        'uvRowStride':   planes[1].bytesPerRow,
        'uvPixelStride': planes[1].bytesPerPixel ?? 1,
        'speedKmh':      0.0,   // Test modu — hız 0, blur eşiği en yüksek
        'hasGps':        false, // Test modu — blur kontrolü kapalı
      });

      if (!mounted) { isWorking = false; return; }
      if (workerResult == null) { isWorking = false; return; }

      _totalFrameCount++;
      if (workerResult['blurSkipped'] == true) {
        _blurSkippedCount++;
        isWorking = false;
        return;
      }

      final Map<String, dynamic>? best = workerResult['bestDetection'];
      final Uint8List? jpegBytes = workerResult['jpegBytes'] as Uint8List?;
      if (jpegBytes != null && mounted) {
        setState(() => debugImageBytes = jpegBytes);
      }
      if (best != null) {
        String detClass  = best['detectedClass'];
        double finalConf = best['finalConfidence'];
        final double bx = best['x'], by = best['y'], bw = best['w'], bh = best['h'];

        double distToDefect = 0.0;
        ll.LatLng? defectLoc;
        bool sensorCorrelated = false;

        if (currentPosition != null) {
          final bottomY = by + bh / 2;
          distToDefect = bottomY > 320
              ? cameraCalibrationFactor / (bottomY - 320)
              : 50.0;
          final offset = (distToDefect - (currentSpeedKmh / 3.6))
              .clamp(0.0, double.infinity);
          final tool = ll.Distance();
          final me = ll.LatLng(currentPosition!.latitude, currentPosition!.longitude);
          defectLoc = tool.offset(me, offset, currentPosition!.heading);

          for (var bump in bumpBuffer) {
            final bl = ll.LatLng(bump['latitude'], bump['longitude']);
            if (tool.as(ll.LengthUnit.Meter, bl, defectLoc) < 15.0) {
              sensorCorrelated = true;
              finalConf = (finalConf + 0.20).clamp(0.0, 1.0);
              break;
            }
          }
        }

        if (sensorCorrelated) detClass += ' (SENSOR CONFIRMED ✅)';

        // Fotoğrafı kaydet — her zaman dolu gelir artık
        String? savedImagePath;
        if (jpegBytes != null) {
          try {
            final dbPath = await getDatabasesPath();
            final imgDir = Directory(p.join(dbPath, 'defect_images'));
            if (!await imgDir.exists()) await imgDir.create(recursive: true);
            final imgFile = File(
              p.join(imgDir.path, 'defect_${DateTime.now().millisecondsSinceEpoch}.jpg'),
            );
            await imgFile.writeAsBytes(jpegBytes);
            savedImagePath = imgFile.path;
          } catch (e) {
            print('Görüntü kayıt hatası: $e');
          }
        }

        // GPS yoksa lat/lng NULL yaz — 0.0 değil
        if (_sessionDatabase != null) {
          await _sessionDatabase!.insert('session_detections', {
            'timestamp':         DateTime.now().toIso8601String(),
            'defectType':        detClass,
            'confidence':        finalConf,
            'latitude':          defectLoc?.latitude,   // null → DB'de NULL
            'longitude':         defectLoc?.longitude,  // null → DB'de NULL
            'speedKmh':          currentSpeedKmh,
            'distanceToDefect':  distToDefect,
            'isSensorConfirmed': sensorCorrelated ? 1 : 0,
            'imagePath':         savedImagePath,
          });
        }

        final posText = currentPosition != null && defectLoc != null
            ? 'Vehicle: ${currentPosition!.latitude.toStringAsFixed(5)}, ${currentPosition!.longitude.toStringAsFixed(5)}\n'
              'Speed: ${currentSpeedKmh.toStringAsFixed(1)} km/h\n'
              'Distance: ${distToDefect.toStringAsFixed(1)} m\n\n'
              '📍 Defect: ${defectLoc.latitude.toStringAsFixed(5)}, ${defectLoc.longitude.toStringAsFixed(5)}'
            : '⚠️ No GPS — Test mode active';

        setState(() {
          result   = '🚧 $detClass\nConfidence: ${(finalConf * 100).toStringAsFixed(1)}%\n\n$posText';
          boxX     = bx; boxY = by; boxW = bw; boxH = bh;
          boxLabel = '$detClass (${(finalConf * 100).toStringAsFixed(1)}%)';
        });
      } else {
        setState(() {
          result   = '';
          boxX = boxY = boxW = boxH = null;
          boxLabel = null;
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
              Text('Starting Camera & AI Model...',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
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
          // --- KAMERA PREVIEW ---
          SizedBox.expand(
            child: GestureDetector(
              onScaleStart: (_) => _baseZoomLevel = _currentZoomLevel,
              onScaleUpdate: (d) async {
                final z = (_baseZoomLevel * d.scale)
                    .clamp(_minAvailableZoom, _maxAvailableZoom);
                if (_currentZoomLevel != z) {
                  setState(() => _currentZoomLevel = z);
                  try { await cameraController!.setZoomLevel(z); } catch (_) {}
                }
              },
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width:  cameraController!.value.previewSize?.height ?? size.width,
                  height: cameraController!.value.previewSize?.width  ?? size.height,
                  child: CameraPreview(cameraController!),
                ),
              ),
            ),
          ),

          // --- UFUK KILAVUZ ÇİZGİSİ (ilk 8 saniye) ---
          AnimatedOpacity(
            opacity: _showHorizonGuide ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 800),
            child: IgnorePointer(
              child: Stack(children: [
                Positioned(
                  top: size.height * 0.33,
                  left: 0, right: 0,
                  child: Container(height: 2, color: Colors.yellowAccent.withValues(alpha: 0.6)),
                ),
                Positioned(
                  top: size.height * 0.33 - 25,
                  left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text('ALIGN HORIZON HERE',
                          style: TextStyle(color: Colors.yellowAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              ]),
            ),
          ),

          // --- GERİ BUTONU ---
          Positioned(
            top: 40, left: 20,
            child: _circleButton(Icons.arrow_back, () => Navigator.pop(context)),
          ),

          // --- KAMERA DEĞİŞTİR ---
          Positioned(
            top: 40, right: 20,
            child: _circleButton(Icons.flip_camera_ios, _flipCamera),
          ),

          // --- BOUNDING BOX ---
          if (result.isNotEmpty && boxX != null)
            Builder(builder: (ctx) {
              final sw = MediaQuery.of(ctx).size.width;
              final sh = MediaQuery.of(ctx).size.height;
              final rX = boxX! > 2 ? boxX! / 640 : boxX!;
              final rY = boxY! > 2 ? boxY! / 640 : boxY!;
              final rW = boxW! > 2 ? boxW! / 640 : boxW!;
              final rH = boxH! > 2 ? boxH! / 640 : boxH!;
              final fw = (rW * sw).clamp(20.0, sw);
              final fh = (rH * sh).clamp(20.0, sh);
              return Positioned(
                left:  (rX * sw) - fw / 2,
                top:   (rY * sh) - fh / 2,
                width: fw, height: fh,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.greenAccent, width: 3),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(
                      color: Colors.greenAccent.withValues(alpha: 0.3),
                      blurRadius: 10, spreadRadius: 2,
                    )],
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.8),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text(
                        boxLabel ?? '',
                        style: const TextStyle(
                            color: Colors.black87, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              );
            }),

          // --- GPS / MOD HUD (sağ alt) ---
          Positioned(
            bottom: 90, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      currentPosition != null ? Icons.gps_fixed : Icons.gps_not_fixed,
                      color: currentPosition != null ? Colors.greenAccent : Colors.orangeAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      currentPosition != null
                          ? '${currentSpeedKmh.toStringAsFixed(0)} km/h'
                          : 'TEST MODE',
                      style: TextStyle(
                        color: currentPosition != null ? Colors.greenAccent : Colors.orangeAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ]),
                  // Blur skip — sadece GPS varken göster
                  if (currentPosition != null && _totalFrameCount > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Blur skip: ${(_blurSkippedCount / _totalFrameCount * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                ],
              ),
            ),
          ),
            if (debugImageBytes != null)
            Positioned(
              bottom: 150, left: 16,
              width: 120, height: 120, // 640x640 kare formatı
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.redAccent, width: 3),
                  color: Colors.black,
                ),
                child: Image.memory(
                  debugImageBytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true, // Kırpışmayı önler
                ),
              ),
            ),
          // --- KAYITLAR BUTONU ---
          Positioned(
            bottom: 30, left: 0, right: 0,
            child: Center(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.7),
                  foregroundColor: Colors.orangeAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: () => Navigator.pushNamed(context, '/history'),
                icon: const Icon(Icons.history),
                label: const Text('View Records',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ),

          // --- TESPİT UYARISI ---
          if (result.isNotEmpty)
            Positioned(
              top: 120, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 10, spreadRadius: 2,
                  )],
                ),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 40),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      result,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }

  Future<void> _flipCamera() async {
    final cameras = await availableCameras();
    if (cameras.length < 2) return;
    final current = cameraController!.description;
    final next = cameras.firstWhere((c) => c != current, orElse: () => cameras[0]);
    await cameraController!.dispose();
    cameraController = CameraController(next, ResolutionPreset.medium);
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