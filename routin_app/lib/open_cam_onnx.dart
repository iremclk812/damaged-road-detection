
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

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

  @override
  void initState() {
    super.initState();
    // Kamerayı başlat
    initCamera();
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
      frameCount++;
      // Her 20 framede bir çalıştır - dengeli
      if (!isWorking && frameCount % 20 == 0) {
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
      // YUV420 veya BGRA8888 -> RGB dnşm
      img.Image? image = convertYUV420ToImage(imgCamera!);

      if (image == null) {
        print("Grnt dnştrme başarısız");
        isWorking = false;
        return;
      }

      print("Grnt boyutu (Orijinal): ${image.width}x${image.height}");

      // 1. Android kamera sensr genellikle yana yatıktır (Landscape).
      // Ekranımız Portrait ise 90 derece dndrmemiz gerekebilir.
      img.Image rotatedImage = img.copyRotate(image, angle: 90);

      // 2. 640x640'a resize et - MODEL BU BOYUTU BEKLİYOR
      img.Image resizedImage = img.copyResize(rotatedImage, width: 640, height: 640);

      // Normalize edilmiş Float32List oluştur [1, 3, 640, 640] - CHW formatı
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

              print("🔍 Tespit adayı: $detectedClass");
              print("   Objectness: ${(confidence * 100).toStringAsFixed(1)}%");
              print("   Class score: ${(maxScore * 100).toStringAsFixed(1)}%");
              print("   Final: ${(finalConfidence * 100).toStringAsFixed(1)}%");
              print("   Bbox: x=$x, y=$y, w=$w, h=$h");

              // Final confidence ile karar ver
              if (finalConfidence > 0.25) {
                potHoleDetected = true;

                setState(() {
                  result =
                      "⚠️ Yol Hasarı: $detectedClass\nGüven: ${(finalConfidence * 100).toStringAsFixed(1)}%";
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

  img.Image? convertYUV420ToImage(CameraImage cameraImage) {
    try {
      final int width = cameraImage.width;
      final int height = cameraImage.height;

      final img.Image image = img.Image(width: width, height: height);

      final int uvRowStride = cameraImage.planes[1].bytesPerRow;
      final int? uvPixelStride = cameraImage.planes[1].bytesPerPixel;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int uvIndex = uvPixelStride ??
              1 * (x / 2).floor() + uvRowStride * (y / 2).floor();
          final int index = y * width + x;

          final yp = cameraImage.planes[0].bytes[index];
          final up = cameraImage.planes[1].bytes[uvIndex];
          final vp = cameraImage.planes[2].bytes[uvIndex];

          int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91)
              .round()
              .clamp(0, 255);
          int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);

          image.setPixelRgb(x, y, r, g, b);
        }
      }

      return image;
    } catch (e) {
      print("Görüntü dönüştürme hatası: $e");
      return null;
    }
  }

  @override
  void dispose() {
    super.dispose();
    if (cameraController != null && cameraController!.value.isInitialized) {
      cameraController!.dispose();
    }
    session?.release();
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
                            frameCount++;
                            if (!isWorking && frameCount % 20 == 0) {
                              // 30 frame
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
                        color: Colors.red.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
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
