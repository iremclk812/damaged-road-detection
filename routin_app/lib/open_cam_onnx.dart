import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class OpenCam extends StatefulWidget {
  const OpenCam({super.key});

  @override
  State<OpenCam> createState() => OpenCamState();
}

class OpenCamState extends State<OpenCam> {
  CameraController? cameraController;
  CameraImage? imgCamera;
  int frameCount = 0;
  List<String> labels = [];

  bool isWorking = false;
  String result = "";
  OrtSession? session;
  int lastProcessingTime = 0; // Buffer/throttle iin son işlenme zamanı

  DateTime sessionStartTime = DateTime.now();
  List<Map<String, dynamic>> detectionBuffer = []; // Tüm tespitlerin tutulduğu log buffer'ı
  double cameraCalibrationFactor = 1200.0; // Kamera açısı ve yüksekliği için kalibrasyon katsayısı

  // --- GPS LOCATOR VERİLERİ ---
  Position? currentPosition;
  StreamSubscription<Position>? positionStream;
  double currentSpeedKmh = 0.0;
  String locationStatus = "Searching location...";

  Uint8List? lastFrameBytes;

  // --- SENSÖR (İVMEÖLÇER/TİTREŞİM) VERİLERİ ---
  StreamSubscription<UserAccelerometerEvent>? accelStream;
  List<Map<String, dynamic>> bumpBuffer = []; // Fiziksel olarak hissedilen çukurlar/sarsıntılar
  double lastVibrationMagnitude = 0.0;
  // Eşiği ayarlayabilirsiniz (m/s^2 cinsinden ani ivme değişimi)
  // Telefon elde tutulurken veya araç normal seyrindeyken ufak sarsıntılar üretebilir.
  // Gerçek bir çukur hissi (anormal sarsıntı) için eşik değerini 6'dan 15'e çıkarıyoruz.
  final double bumpThreshold = 15.0;

  // --- DATABASE VERİLERİ ---
  Database? _sessionDatabase;

  // --- Bounding Box Verileri ---
  double? boxX;
  double? boxY;
  double? boxW;
  double? boxH;
  String? boxLabel;

  @override
  void initState() {
    super.initState();
    // Veritabanını başlat
    _initDatabase().then((_) {
      // Kamerayı başlat
      initCamera();
      // GPS başlat
      _initLocation();
      // Sensör başlat
      _initSensors();
    });
  }

  Future<void> _initDatabase() async {
    // Session bazlı değil, kalıcı olarak cihaza kaydetmek için filePath alalım
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

  void _initSensors() {
    // Sadece yerçekimi HARİÇ ivmeyi (kullanıcı/araç hareketi) dinler.
    accelStream = userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      if (mounted) {
        // x, y, z vektörlerinin bileşkesini (magnitude) alıyoruz
        double magnitude = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

        lastVibrationMagnitude = magnitude;

        // Anormal bir sarsıntı (çukur) tespit edildiğinde:
        if (magnitude > bumpThreshold) {
          _recordPhysicalBump(magnitude);
        }
      }
    });
  }

  void _recordPhysicalBump(double magnitude) async {
    double lat = currentPosition?.latitude ?? 0.0;
    double lng = currentPosition?.longitude ?? 0.0;

    // Aynı saniyede peş peşe 10 tane ivme verisi girmesin diye son eklenenle zaman farkına bakıyoruz
    if (bumpBuffer.isNotEmpty) {
      final lastTime = bumpBuffer.last['time'] as DateTime;
      if (DateTime.now().difference(lastTime).inMilliseconds < 1000) {
        return; // Aynı sarsıntının kuyruğu, yoksay
      }
    }

    String? savedImagePath;
    if (lastFrameBytes != null) {
      try {
        final dbPath = await getDatabasesPath();
        final imgFile = File(p.join(dbPath, 'bump_${DateTime.now().millisecondsSinceEpoch}.jpg'));
        await imgFile.writeAsBytes(lastFrameBytes!);
        savedImagePath = imgFile.path;
      } catch (e) {
        print("Görüntü kaydedilemedi: $e");
      }
    }

    // Veritabanına kaydet
    if (_sessionDatabase != null) {
      _sessionDatabase!.insert('session_vibrations', {
        'timestamp': DateTime.now().toIso8601String(),
        'latitude': lat,
        'longitude': lng,
        'magnitude': magnitude,
      });

      _sessionDatabase!.insert('session_detections', {
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

    // Sarsıntı olarak Buffer'da tut
    bumpBuffer.add({
      'time': DateTime.now(),
      'latitude': lat,
      'longitude': lng,
      'magnitude': magnitude,
    });

    // Buffer'ı temiz tut (son 20 sarsıntıyı tut)
    if (bumpBuffer.length > 20) {
      bumpBuffer.removeAt(0);
    }
    
    // Sensör direkt sarsıntı algıladı, uyarıyı ekrana yazdır (Kamera modeli bozuk yol algılamasa bile)
    setState(() {
      result = "🚨 BUMP DETECTED (Sensor)!\nMagnitude: ${magnitude.toStringAsFixed(1)}\n"
               "Vehicle Location: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}\n"
               "Speed: ${currentSpeedKmh.toStringAsFixed(1)} km/h";
      
      // Kutu çizimini iptal et (sadece sensör verisi ise)
      boxX = null;
      boxY = null;
      boxW = null;
      boxH = null;
      boxLabel = null;
    });
  }

  Future<void> _initLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Servis açık mı?
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        locationStatus = "Location service is disabled.";
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          locationStatus = "Location permission denied.";
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        locationStatus = "Location permission permanently denied.";
      });
      return;
    }

    setState(() {
      locationStatus = "Locating...";
    });

    // Anlık konum akışı başlat, çok hassas veri gerek - Otonom araç gibi
    positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation, // En yüksek hassasiyet
        distanceFilter: 1, // Her 1 metrede gncelle
      ),
    ).listen((Position position) {
      if (mounted) {
        setState(() {
          currentPosition = position;
          // Geolocator hızı m/s (metre/saniye) cinsinden verir, biz km/h yapıyoruz (* 3.6)
          currentSpeedKmh = (position.speed * 3.6);
          locationStatus = "GPS Active";
        });
      }
    });
  }

  void initCamera() async {
    final cameras = await availableCameras();
    // Medium çözünürlük - tespit için yeterli
    cameraController = CameraController(cameras[0], ResolutionPreset.medium);
    await cameraController!.initialize();

    if (!mounted) return;

    setState(() {});

    // Model yükle
    await loadModel();

    // Stream başlat
    cameraController!.startImageStream((image) {
      int currentTime = DateTime.now().millisecondsSinceEpoch;
      // Her 5 saniyede bir frame al
      if (!isWorking && (currentTime - lastProcessingTime >= 5000)) {
        imgCamera = image;
        runModelOnStreamFrame();
      }
    });
  }

  Future<void> loadModel() async {
    try {
      print("Model yükleniyor...");

      // Labels - RDDC2020 road damage classes (hardcoded)
      labels = ['D00', 'D10', 'D20', 'D40'];
      print("Labels: $labels");
      print(
          "D00=Boyuna Çatlak, D10=Enine Çatlak, D20=Timsah Çatlak, D40=Çukur");

      // ONNX modeli yükle
      const assetFileName = 'assets/road_damage.onnx';
      final rawAssetFile = await rootBundle.load(assetFileName);
      final bytes = rawAssetFile.buffer.asUint8List();

      // SessionOptions oluştur
      final sessionOptions = OrtSessionOptions();

      // Session oluştur
      session = OrtSession.fromBuffer(bytes, sessionOptions);

      print("✓ ONNX model yüklendi!");

      // Model bilgilerini göster
      final inputNames = session!.inputNames;
      final outputNames = session!.outputNames;
      print("Input names: $inputNames");
      print("Output names: $outputNames");
    } catch (e) {
      print("Model yükleme hatası: $e");
    }
  }

  Future<void> runModelOnStreamFrame() async {
    if (imgCamera == null || session == null) return;

    // FPS Dengeleyici (Buffer/Throttle): Yeni bir kareyi girmeden nce araya bekleme payı koy(Maks saniyede ~2-3 kare işler)
    int currentTime = DateTime.now().millisecondsSinceEpoch;
    if (currentTime - lastProcessingTime < 500) {
        return; // 500 ms (yarım saniye) gemeden yeni frame işleme
    }

    if (isWorking) return; // Zaten bir kare işleniyorsa atla
    isWorking = true;
    lastProcessingTime = currentTime;

    try {
      // Isolate için veriyi Map haline getiriyoruz (CameraImage kopyalanamaz, sadece verilerini aktarabiliriz)
      final List<Map<String, dynamic>> planeData = imgCamera!.planes.map((plane) {
        return {
          'bytes': Uint8List.fromList(plane.bytes), // Hard Copy yapılarak native bellek kilidi kaldırılır
          'bytesPerRow': plane.bytesPerRow,
          'bytesPerPixel': plane.bytesPerPixel,
        };
      }).toList();

      final Map<String, dynamic> isolateParams = {
        'width': imgCamera!.width,
        'height': imgCamera!.height,
        'planes': planeData,
      };

      // Ağır işlemleri (YUV->RGB Dönüşümü, Döndürme, Yeniden Boyutlandırma, Float32List oluşturma)
      // başka bir Thread'de (Isolate'te) bilgisayarı dondurmadan yapıyoruz!
      final Map<String, dynamic>? isolateResult = await compute(_processCameraImageInIsolate, isolateParams);

      if (isolateResult == null) {
        print("Görüntü dönüştürme başarısız (Isolate Hatası)");
        isWorking = false;
        return;
      }

      final Float32List inputData = isolateResult['tensor'];
      final Uint8List jpgBytes = isolateResult['image'];
      lastFrameBytes = jpgBytes; // Son kareyi kaydet (sensör sarsılırsa kullanmak için)

      print("Input hazır: ${inputData.length} değer");

      // ONNX input tensor oluştur
      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputData,
        [1, 3, 640, 640],
      );

      // Inference çalıştır
      final inputs = {'images': inputOrt};
      final runOptions = OrtRunOptions();
      
      // RUNASYNC kullanarak UI'ın donmasını engelliyoruz
      final outputs = await session!.runAsync(runOptions, inputs) ?? [];

      print("Inference tamamlandı");

      // Output işle
      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];

        if (outputTensor != null) {
          final outputData = outputTensor.value as List<List<List<double>>>;
          print(
              "Output shape: [${outputData.length}, ${outputData[0].length}, ${outputData[0][0].length}]");

          // Tespit kontrolü
          bool potHoleDetected = false;
          int totalDetections = 0;
          int highConfidenceCount = 0;

          // YOLOv5 output: [1, 25200, 9] formatı
          // 9 = 4 (bbox) + 1 (confidence) + 4 (classes: D00, D10, D20, D40)

          for (var detection in outputData[0]) {
            // Confidence score
            double confidence = detection[4];

            totalDetections++;

            // Her 5000 detection'da bir örnek göster
            if (totalDetections % 5000 == 0) {
              print("Örnek detection $totalDetections: confidence=$confidence");
            }

            // Güven eşiği - düşük tutuyoruz
            if (confidence > 0.3) {
              highConfidenceCount++;

              // Bbox koordinatları
              double x = detection[0];
              double y = detection[1];
              double w = detection[2];
              double h = detection[3];

              // Class skorları (index 5'ten sonra) - 4 class var
              List<double> classScores = detection.sublist(5);
              int maxIndex = 0;
              double maxScore = classScores[0];

              for (int i = 1; i < classScores.length && i < 4; i++) {
                if (classScores[i] > maxScore) {
                  maxScore = classScores[i];
                  maxIndex = i;
                }
              }

              // Final confidence = objectness * class score
              double finalConfidence = confidence * maxScore;

              String detectedClass =
                  maxIndex < labels.length ? labels[maxIndex] : "Unknown";

              // ====== YENİ: UZAKLIK VE GERÇEK KOORDİNAT HESABI ======
              double distanceToDefect = 0.0;
              ll.LatLng? defectRealLocation;
              bool isCorrelatedWithSensor = false;

              if (currentPosition != null) {
                // 'y' kutunun merkezi, 'h' yüksekliğidir.
                // y + (h/2) formülü, dikdörtgenin/çukurun ekrandaki en alt kısmını yani kameraya en yakın noktasını verir.
                double bottomY = y + (h / 2);

                // --- 1. Mesafe Formülü (Ampirik Kamera Yüksekliği Yaklaşımı) ---
                // Görüntü (640x640): 0 noktası ekranın en üstü, 640 en altı.
                // Çukur çizgisinin tabanı `bottomY` ne kadar yüksekse (640'a yakınsa), çukur araca o kadar YAKINDIR.
                // Ufuk çizgisi 320 civarıdır (Ufuktaki nesnenin uzaklığı sonsuzdur).
                // DİKKAT: Bu '1200' çarpanı arabanın kamera yüksekliği ve kameranın cama vurduğu açıya göre belirlenen VARSAYIMSAL (KALİBRE EDİLMESİ GEREKEN) bir katsayıdır.
                // Sensör (Tilt/Pitch) entegre edilene kadar çukur uzaklık tahmini bu ampirik formülle yapılır.
                if (bottomY > 320) {
                  // Basit Kalibrasyon Katsayısı: Bu katsayı aracın kamera yüksekliği ve açısına göre ayarlanabilir.
                  // Matematik: Uzaklık = Katsayı / (bottomY - UfukÇizgisiY)
                  distanceToDefect = cameraCalibrationFactor / (bottomY - 320);
                } else {
                  // Y ekseninde çukur ufuk çizgisinin yukarısında bulunamaz. Bulunduysa model hatalı veya uzağı seçmiştir.
                  distanceToDefect = 50.0; // Max mesafe varsayıyoruz.
                }

                // --- 2. Gecikme (Latency) Telafisi ---
                // Fotoğraf çekildi, Isolate dönüştürdü, Model çalıştı... Yaklaşık 1-2 saniye geriden geliyoruz.
                // Araç bu sırada ilerlemeye devam etti.
                // Hız (m/s) * Gecikme (saniye) = Gidilen Mesafe.
                // Bu mesafeyi çukurun asıl uzaklığından çıkartmalıyız ki, veritabanına yazdığımızda aracı geçmiş olmasın.
                double latencyDelaySeconds = 1.0; // 1 saniye ping varsayalım
                double offsetDueToSpeed = (currentSpeedKmh / 3.6) * latencyDelaySeconds;
                double adjustedDistance = distanceToDefect - offsetDueToSpeed;

                // Aracın çukuru çoktan geçmiş olma ihtimaline karşı min mesafeyi 0 yapalım
                if (adjustedDistance < 0) adjustedDistance = 0;

                // --- 3. Pusula (Heading) ve LatLong2 ile Çukurun Gerçek Konumunu Bulma ---
                final ll.Distance distanceTool = ll.Distance();
                final ll.LatLng myVehicleLocation = ll.LatLng(currentPosition!.latitude, currentPosition!.longitude);

                // Araç konumundan, pusula yönüne doğru 'adjustedDistance' kadar ilerle ve o noktanın koordinatını ver!
                defectRealLocation = distanceTool.offset(myVehicleLocation, adjustedDistance, currentPosition!.heading);

                // =======================================================
                // ====== 4. SENSÖR (FİZİKSEL SARSINTI) KORELASYONU ======
                // Modelimizin görsel olarak bulduğu çukur ile, aracın o sırada veya saniyeler önce girdiği çukur uyuşuyor mu?

                // Aracın şimdiki veya 1-2 saniye içindeki konumlarına (buffer'a) bak
                for (var bump in bumpBuffer) {
                  ll.LatLng bumpLocation = ll.LatLng(bump['latitude'], bump['longitude']);
                  double distanceBetweenBumpAndVisual = distanceTool.as(
                    ll.LengthUnit.Meter,
                    bumpLocation,
                    defectRealLocation!
                  );

                  // Eğer fiziksel sarsıntı yeri ile kameranın gördüğü çukur bölgesi 15 metre çapındaysa (çok yakınlar)
                  if (distanceBetweenBumpAndVisual < 15.0) {
                    isCorrelatedWithSensor = true;
                    // Güven puanına +%20 bonus ver
                    finalConfidence = (finalConfidence + 0.20).clamp(0.0, 1.0);
                    break;
                  }
                }
              } else {
                 defectRealLocation = const ll.LatLng(0.0, 0.0);
              }

              // Çıktıya sensör desteği metnini ekleyelim
              if (isCorrelatedWithSensor) {
                  detectedClass += " (SENSOR CONFIRMED 🚨)";
              }
            // ========================================================

              print("🔍 Tespit adayı: $detectedClass");
              print("   Objectness: ${(confidence * 100).toStringAsFixed(1)}%");
              print("   Class score: ${(maxScore * 100).toStringAsFixed(1)}%");
              print("   Final: ${(finalConfidence * 100).toStringAsFixed(1)}%");
              print("   Bbox: x=$x, y=$y, w=$w, h=$h");

              // Final confidence ile karar ver
              if (finalConfidence > 0.25) {
                potHoleDetected = true;

                Duration travelTime = DateTime.now().difference(sessionStartTime);

                String? savedImagePath;
                try {
                  final dbPath = await getDatabasesPath();
                  final imgFile = File(p.join(dbPath, 'defect_${DateTime.now().millisecondsSinceEpoch}.jpg'));
                  await imgFile.writeAsBytes(jpgBytes);
                  savedImagePath = imgFile.path;
                } catch (e) {
                  print("Görüntü kaydedilemedi: $e");
                }

                // Veritabanına tespiti kaydet
                if (_sessionDatabase != null) {
                  _sessionDatabase!.insert('session_detections', {
                    'timestamp': DateTime.now().toIso8601String(),
                    'defectType': detectedClass,
                    'confidence': finalConfidence,
                    'latitude': defectRealLocation?.latitude ?? 0.0,
                    'longitude': defectRealLocation?.longitude ?? 0.0,
                    'speedKmh': currentSpeedKmh,
                    'distanceToDefect': distanceToDefect,
                    'isSensorConfirmed': isCorrelatedWithSensor ? 1 : 0,
                    'imagePath': savedImagePath,
                  });
                }

                // Hatayı ana detectionBuffer'a (hız, seyahat süresi, koordinatlar ile) kaydet
                detectionBuffer.add({
                  'timestamp': DateTime.now(),
                  'travelTime': travelTime.toString(),
                  'defectType': detectedClass,
                  'confidence': finalConfidence,
                  'vehicleLocation': currentPosition != null ? '${currentPosition!.latitude}, ${currentPosition!.longitude}' : 'Unknown',
                  'defectLocation': defectRealLocation != null ? '${defectRealLocation.latitude}, ${defectRealLocation.longitude}' : 'Unknown',
                  'speedKmh': currentSpeedKmh,
                  'distanceToDefect': distanceToDefect,
                  'isSensorConfirmed': isCorrelatedWithSensor,
                });
                String posText = "No Location/Speed data";
                if (currentPosition != null && defectRealLocation != null) {
                   posText = "Vehicle Location: ${currentPosition!.latitude.toStringAsFixed(5)}, ${currentPosition!.longitude.toStringAsFixed(5)}\n"
                             "Speed: ${currentSpeedKmh.toStringAsFixed(1)} km/h\n"
                             "Distance to Defect: ${distanceToDefect.toStringAsFixed(1)} m\n\n"
                             "📍 EXACT Defect Location:\n${defectRealLocation.latitude.toStringAsFixed(5)}, ${defectRealLocation.longitude.toStringAsFixed(5)}";
                }

                setState(() {
                  result =
                      "⚠️ Road Damage: $detectedClass\nConfidence: ${(finalConfidence * 100).toStringAsFixed(1)}%\n\n$posText";

                  // Bounding box için değişkenleri kaydet
                  boxX = x;
                  boxY = y;
                  boxW = w;
                  boxH = h;
                  boxLabel = "$detectedClass (Confidence: ${(finalConfidence * 100).toStringAsFixed(1)}%)";
                });

                break;
              }
            }
          }

          print(
              "📊 Toplam detection: $totalDetections, Yüksek güven: $highConfidenceCount");

          if (!potHoleDetected) {
            setState(() {
              result = "";
              boxX = null;
              boxY = null;
              boxW = null;
              boxH = null;
              boxLabel = null;
            });
          }
        }
      }

      inputOrt.release();
      runOptions.release();
      for (final output in outputs) {
        output?.release();
      }
    } catch (e) {
      print("Model çalıştırma hatası: $e");
    }

    isWorking = false;
  }


  @override
  void dispose() {
    accelStream?.cancel();
    positionStream?.cancel();
    if (cameraController != null && cameraController!.value.isInitialized) {
      cameraController!.dispose();
    }
    session?.release();
    _sessionDatabase?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: cameraController == null || !cameraController!.value.isInitialized
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.photo_camera_front,
                    color: Colors.blueAccent,
                    size: 60,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      initCamera();
                    },
                    child: const Text('Open Camera'),
                  ),
                ],
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: cameraController!.value.previewSize?.height ?? MediaQuery.of(context).size.width,
                      height: cameraController!.value.previewSize?.width ?? MediaQuery.of(context).size.height,
                      child: CameraPreview(cameraController!),
                    ),
                  ),
                ),

                // Geri butonu
                Positioned(
                  top: 40,
                  left: 20,
                  child: IconButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),

                // BOUNDING BOX ÇİZİMİ
                if (result.isNotEmpty && boxX != null && boxY != null && boxW != null && boxH != null)
                  Builder(
                    builder: (context) {
                      double screenW = MediaQuery.of(context).size.width;
                      double screenH = MediaQuery.of(context).size.height;

                      // Çıktı normalize mi (0 - 1 arası) yoksa direkt piksel mi (0 - 640) kontrolü (YOLO versiyonuna göre değişir)
                      double rX = boxX! > 2.0 ? boxX! / 640.0 : boxX!;
                      double rY = boxY! > 2.0 ? boxY! / 640.0 : boxY!;
                      double rW = boxW! > 2.0 ? boxW! / 640.0 : boxW!;
                      double rH = boxH! > 2.0 ? boxH! / 640.0 : boxH!;

                      // Kameraya orantıla ve limitleri (clamp) belirle ki Flutter hata verip gizlemesin
                      double finalWidth = (rW * screenW).clamp(20.0, screenW);
                      double finalHeight = (rH * screenH).clamp(20.0, screenH);
                      double finalLeft = (rX * screenW) - (finalWidth / 2);
                      double finalTop = (rY * screenH) - (finalHeight / 2);

                      return Positioned(
                        left: finalLeft,
                        top: finalTop,
                        width: finalWidth,
                        height: finalHeight,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.greenAccent, width: 3.0),
                            borderRadius: BorderRadius.circular(12.0),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.greenAccent.withValues(alpha: 0.3),
                                blurRadius: 10.0,
                                spreadRadius: 2.0,
                              ),
                            ],
                          ),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withValues(alpha: 0.8),
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(8.0),
                                  bottomRight: Radius.circular(8.0),
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              child: Text(
                                boxLabel ?? "",
                                style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // Kamera değiştir butonu
                Positioned(
                  top: 40,
                  right: 20,
                  child: IconButton(
                    onPressed: () async {
                      final cameras = await availableCameras();
                      if (cameras.length > 1) {
                        final currentCamera = cameraController!.description;
                        final newCamera = cameras.firstWhere(
                          (camera) => camera != currentCamera,
                          orElse: () => cameras[0],
                        );

                        await cameraController!.dispose();
                        cameraController = CameraController(
                          newCamera,
                          ResolutionPreset.medium,
                        );
                        await cameraController!.initialize();

                        if (mounted) {
                          setState(() {});

                          cameraController!.startImageStream((image) {
                            int currentTime = DateTime.now().millisecondsSinceEpoch;
                            if (!isWorking && (currentTime - lastProcessingTime >= 5000)) {
                              imgCamera = image;
                              runModelOnStreamFrame();
                            }
                          });
                        }
                      }
                    },
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.flip_camera_ios,
                        color: Colors.white,
                        size: 24,
                      ),
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
                        backgroundColor: Colors.black.withOpacity(0.7),
                        foregroundColor: Colors.orangeAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                      onPressed: () {
                        Navigator.pushNamed(context, '/history');
                      },
                      icon: const Icon(Icons.history),
                      label: const Text(
                        "View Records",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

                // Tespit uyarısı
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
                                fontSize: 16,
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
}

// === ISOLATE (ARKA PLAN THREAD) İÇİN TOP-LEVEL FONKSİYON ===
Future<Map<String, dynamic>?> _processCameraImageInIsolate(Map<String, dynamic> params) async {
  try {
    final int width = params['width'];
    final int height = params['height'];
    final List<Map<String, dynamic>> planes = params['planes'];

    final img.Image image = img.Image(width: width, height: height);

    final Uint8List yPlane = planes[0]['bytes'];
    final Uint8List uPlane = planes[1]['bytes'];
    final Uint8List vPlane = planes[2]['bytes'];

    final int uvRowStride = planes[1]['bytesPerRow'];
    final int? uvPixelStride = planes[1]['bytesPerPixel'];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Eski çalışan orijinal matematik formülüne dönüş yapıldı
        final int uvIndex = uvPixelStride ??
            1 * (x / 2).floor() + uvRowStride * (y / 2).floor();
        final int index = y * width + x;

        final yp = yPlane[index];
        final up = uPlane[uvIndex];
        final vp = vPlane[uvIndex];

        int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
        int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round().clamp(0, 255);
        int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

        image.setPixelRgb(x, y, r, g, b);
      }
    }

    // 1. Android kamerası veriyi yana yatık (landscape) verir, düzeltiyoruz.
    img.Image rotatedImage = img.copyRotate(image, angle: 90);

    // 2. Modeli (YOLO v5) beslemek için 640x640'a boyutlandırıyoruz.
    img.Image resizedImage = img.copyResize(rotatedImage, width: 640, height: 640);

    // 3. Modeli beslemek için 1D listeye (Float32List - [1, 3, 640, 640]) çeviriyoruz.
    var inputData = Float32List(1 * 3 * 640 * 640);
    int pixelIndex = 0;

    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < 640; y++) {
        for (int x = 0; x < 640; x++) {
          final pixel = resizedImage.getPixel(x, y);
          double value;
          if (c == 0)
            value = pixel.r / 255.0; // R
          else if (c == 1)
            value = pixel.g / 255.0; // G
          else
            value = pixel.b / 255.0; // B

          inputData[pixelIndex++] = value;
        }
      }
    }

    return {
      'tensor': inputData,
      'image': img.encodeJpg(resizedImage)
    };
  } catch (e) {
    print("Isolate İçinde Kritik Hata: $e");
    return null;
  }
}
