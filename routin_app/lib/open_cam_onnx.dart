import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'dart:async';

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

  // --- GPS LOCATOR VERİLERİ ---
  Position? currentPosition;
  StreamSubscription<Position>? positionStream;
  double currentSpeedKmh = 0.0;
  String locationStatus = "Konum aranıyor...";

  @override
  void initState() {
    super.initState();
    // Kamerayı başlat
    initCamera();
    // GPS başlat
    _initLocation();
  }

  Future<void> _initLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Servis açık mı?
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        locationStatus = "Konum servisi kapalı.";
      });
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          locationStatus = "Konum izni reddedildi.";
        });
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        locationStatus = "Konum izni kalıcı reddedildi.";
      });
      return;
    }

    setState(() {
      locationStatus = "Konum bulunuyor...";
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
          locationStatus = "GPS Aktif";
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
      // ÖNEMLİ: BufferQueueProducer Timeout hatasını önlemek için Native referansı hemen kopyalayarak serbest bırakıyoruz!
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
      final Float32List? inputData = await compute(_processCameraImageInIsolate, isolateParams);

      if (inputData == null) {
        print("Görüntü dönüştürme başarısız (Isolate Hatası)");
        isWorking = false;
        return;
      }


      print("Input hazır: ${inputData.length} değer");

      // ONNX input tensor oluştur
      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputData,
        [1, 3, 640, 640],
      );

      // Inference çalıştır
      final inputs = {'images': inputOrt};
      final runOptions = OrtRunOptions();
      final outputs = session!.run(runOptions, inputs);

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
                  maxIndex < labels.length ? labels[maxIndex] : "Bilinmeyen";

              // ====== YENİ: UZAKLIK VE GERÇEK KOORDİNAT HESABI ======
              double distanceToDefect = 0.0;
              ll.LatLng? defectRealLocation;

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
                  distanceToDefect = 1200 / (bottomY - 320);
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

                // Konum ve hız verilerini ekrana (şimdilik string olarak) bas
                String posText = "Konum/Hız bilgisi yok";
                if (currentPosition != null && defectRealLocation != null) {
                   posText = "Araç Konumu: ${currentPosition!.latitude.toStringAsFixed(5)}, ${currentPosition!.longitude.toStringAsFixed(5)}\n"
                             "Hız: ${currentSpeedKmh.toStringAsFixed(1)} km/h\n"
                             "Çukura Uzaklık: ${distanceToDefect.toStringAsFixed(1)} m\n\n"
                             "📍 Çukurun GERÇEK Konumu:\n${defectRealLocation.latitude.toStringAsFixed(5)}, ${defectRealLocation.longitude.toStringAsFixed(5)}";
                }

                setState(() {
                  result =
                      "⚠️ Yol Hasarı: $detectedClass\nGüven: ${(finalConfidence * 100).toStringAsFixed(1)}%\n\n$posText";
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
    positionStream?.cancel();
    if (cameraController != null && cameraController!.value.isInitialized) {
      cameraController!.dispose();
    }
    session?.release();
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
                    child: const Text('Kamerayı Aç'),
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
                        color: Colors.black.withOpacity(0.5),
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
// Görüntünün işlenmesi 1 milyondan fazla piksel döndürdüğü için arayüzü dondurmasın diye burada çalışır.
Future<Float32List?> _processCameraImageInIsolate(Map<String, dynamic> params) async {
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

    return inputData;
  } catch (e) {
    print("Isolate İçinde Kritik Hata: $e");
    return null;
  }
}

