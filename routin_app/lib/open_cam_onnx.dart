import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:math' as math;

class OpenCam extends StatefulWidget {
  const OpenCam({super.key});

  @override
  State<OpenCam> createState() => OpenCamState();
}

class OpenCamState extends State<OpenCam> {
  CameraController? cameraController;
  CameraImage? pendingImage;
  List<String> labels = [];
  List<Map<String, dynamic>> detectedObjects = []; // Ekranda izilecek kutular iin
  
  bool isWorking = false;
  String result = "";
  OrtSession? session;
  int lastProcessingTime = 0; // Buffer/throttle iin son işlenme zamanı
  bool isStreaming = false;

  static const int processIntervalMs = 900;
  static const int targetSize = 640;
  static const double objectnessThreshold = 0.25;
  static const double finalConfidenceThreshold = 0.65;
  static const double nmsIouThreshold = 0.45;
  static const int maxRenderedBoxes = 12;

  double calculateIOU(Map<String, dynamic> box1, Map<String, dynamic> box2) {
    double x1 = box1['x'] - box1['w'] / 2;
    double y1 = box1['y'] - box1['h'] / 2;
    double w1 = box1['w'];
    double h1 = box1['h'];

    double x2 = box2['x'] - box2['w'] / 2;
    double y2 = box2['y'] - box2['h'] / 2;
    double w2 = box2['w'];
    double h2 = box2['h'];

    double interX1 = math.max(x1, x2);
    double interY1 = math.max(y1, y2);
    double interX2 = math.min(x1 + w1, x2 + w2);
    double interY2 = math.min(y1 + h1, y2 + h2);

    if (interX2 <= interX1 || interY2 <= interY1) return 0.0;

    double intersectionArea = (interX2 - interX1) * (interY2 - interY1);
    double area1 = w1 * h1;
    double area2 = w2 * h2;
    double unionArea = area1 + area2 - intersectionArea;

    return intersectionArea / unionArea;
  }

  List<Map<String, dynamic>> applyNMS(List<Map<String, dynamic>> boxes, double iouThreshold) {
    if (boxes.isEmpty) return [];

    boxes.sort((a, b) => b['confidence'].compareTo(a['confidence']));
    List<Map<String, dynamic>> selected = [];

    for (var box in boxes) {
      bool keep = true;
      for (var selectedBox in selected) {
        if (box['class'] == selectedBox['class']) {
          double iou = calculateIOU(box, selectedBox);
          if (iou > iouThreshold) {
            keep = false;
            break;
          }
        }
      }
      if (keep) {
        selected.add(box);
      }
    }
    return selected;
  }

  @override
  void initState() {
    super.initState();
    // Kamerayı başlat
    initCamera();
  }

  void initCamera() async {
    final cameras = await availableCameras();
    // Düşük çözünürlük buffer baskısını azaltır ve stream timeout olasılığını düşürür.
    cameraController = CameraController(
      cameras[0],
      ResolutionPreset.low,
      imageFormatGroup: ImageFormatGroup.yuv420,
      enableAudio: false,
    );
    await cameraController!.initialize();

    if (!mounted) return;

    setState(() {});

    // Model yükle
    await loadModel();

    startImageStream();
  }

  void startImageStream() {
    if (cameraController == null || !cameraController!.value.isInitialized) return;

    isStreaming = true;
    cameraController!.startImageStream((image) {
      pendingImage = image;
      if (isWorking || !isStreaming) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastProcessingTime < processIntervalMs) return;
      lastProcessingTime = now;

      processLatestFrame();
    });
  }

  Future<void> processLatestFrame() async {
    if (isWorking || session == null || !isStreaming) return;
    final image = pendingImage;
    if (image == null) return;

    pendingImage = null;
    await runModelOnStreamFrame(image);

    // İnference sürerken gelen en güncel frame'i kaçırmamak için zincirleme devam eder.
    if (pendingImage != null && mounted) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastProcessingTime >= processIntervalMs) {
        lastProcessingTime = now;
        processLatestFrame();
      }
    }
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

  Future<void> runModelOnStreamFrame(CameraImage image) async {
    if (session == null || isWorking) return;
    isWorking = true;

    try {

      // Görüntü boyutları
      int width = image.width;
      int height = image.height;

      // YOLOv5 modeline uygun 640x640 giriş ölçüsü
      var inputData = Float32List(1 * 3 * targetSize * targetSize);

      Uint8List yp = image.planes[0].bytes;
      Uint8List up = image.planes[1].bytes;
      Uint8List vp = image.planes[2].bytes;

      int uvRowStride = image.planes[1].bytesPerRow;
      int uvPixelStride = image.planes[1].bytesPerPixel ?? 1;

      // Döndürme olmadan doğrudan resize ederek RGB'ye çevirip CHW dizilimine uygun yerleştiriyoruz.
      // DİKKAT: Cihaz kamerası donanımda 90 derece döndürülmüş olabilir fakat 0 skor alınmaması için düz eşleme yapıyoruz.
      for (int y = 0; y < targetSize; y++) {
        for (int x = 0; x < targetSize; x++) {
          int srcX = (x * width) ~/ targetSize;
          int srcY = (y * height) ~/ targetSize;

          final int uvIndex = uvPixelStride * (srcX ~/ 2) + uvRowStride * (srcY ~/ 2);
          final int index = srcY * width + srcX;

          final ypVal = yp[index];
          final upVal = up[uvIndex];
          final vpVal = vp[uvIndex];

          int r = (ypVal + vpVal * 1436 / 1024 - 179).round().clamp(0, 255);
          int g = (ypVal - upVal * 46549 / 131072 + 44 - vpVal * 93604 / 131072 + 91).round().clamp(0, 255);
          int b = (ypVal + upVal * 1814 / 1024 - 227).round().clamp(0, 255);

          // R, G, B sırasıyla kanallara düz olarak (0-1 arasında) eklenir
          int pixelOffset = y * targetSize + x;
          inputData[pixelOffset] = r / 255.0; // Red
          inputData[targetSize * targetSize + pixelOffset] = g / 255.0; // Green
          inputData[2 * targetSize * targetSize + pixelOffset] = b / 255.0; // Blue
        }
      }

      final inputOrt = OrtValueTensor.createTensorWithDataList(
        inputData,
        [1, 3, targetSize, targetSize],
      );

      final inputs = {'images': inputOrt};
      final runOptions = OrtRunOptions();
      final outputs = session!.run(runOptions, inputs);

      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];

        if (outputTensor != null) {
          final outputData = outputTensor.value as List<List<List<double>>>;

          List<Map<String, dynamic>> newDetections = [];

          for (var detection in outputData[0]) {
            double confidence = detection[4];

            if (confidence < 0 || confidence > 1) {
              confidence = 1 / (1 + math.exp(-confidence));
            }

            if (confidence > objectnessThreshold) {
              double x = detection[0];
              double y = detection[1];
              double w = detection[2];
              double h = detection[3];

              if (w <= 1 || h <= 1) continue;

              List<double> classScores = detection.sublist(5);
              int maxIndex = 0;
              double maxScore = classScores[0];

              for (int i = 1; i < classScores.length && i < 4; i++) {
                double score = classScores[i];
                if (score < 0 || score > 1) {
                  score = 1 / (1 + math.exp(-score));
                }
                if (score > maxScore) {
                  maxScore = score;
                  maxIndex = i;
                }
              }

              double finalConfidence = confidence * maxScore;

              if (finalConfidence > finalConfidenceThreshold) {
                String detectedClass =
                    maxIndex < labels.length ? labels[maxIndex] : "Bilinmeyen";

                newDetections.add({
                  'class': detectedClass,
                  'confidence': finalConfidence,
                  'x': x,
                  'y': y,
                  'w': w,
                  'h': h,
                });
              }
            }
          }

          // Non-Maximum Suppression (NMS) uygulayarak üst üste binen çoklu kutuları ele
          newDetections = applyNMS(newDetections, nmsIouThreshold);
          newDetections.sort((a, b) => b['confidence'].compareTo(a['confidence']));
          if (newDetections.length > maxRenderedBoxes) {
            newDetections = newDetections.take(maxRenderedBoxes).toList();
          }

          if (!mounted) return;
          setState(() {
            detectedObjects = newDetections;
            // Uyarı mesajını kaldırdık, sadece referans kutuları yeşil olarak kalacak
            result = "";
          });
        }
      }

      inputOrt.release();
      runOptions.release();
      for (final output in outputs) {
        output?.release();
      }
    } catch (e) {
      print("Model çalıştırma hatası: $e");
    } finally {
      isWorking = false;
    }
  }

  @override
  void dispose() {
    super.dispose();
    isStreaming = false;
    if (cameraController != null && cameraController!.value.isInitialized) {
      if (cameraController!.value.isStreamingImages) {
        cameraController!.stopImageStream();
      }
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
                          ResolutionPreset.low,
                          imageFormatGroup: ImageFormatGroup.yuv420,
                          enableAudio: false,
                        );
                        await cameraController!.initialize();

                        if (mounted) {
                          setState(() {});
                          pendingImage = null;
                          lastProcessingTime = 0;
                          startImageStream();
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

                // Tespit KUTULARI (Bounding Boxes)
                ...detectedObjects.map((d) {
                  // Modelimiz 640x640 input alıyor. nce normalize koordinata (/640), sonra ekran boyutuna arpalım
                  var screenH = MediaQuery.of(context).size.height;
                  var screenW = MediaQuery.of(context).size.width;
                  
                  // Kutuyu abartmamak iin max limitler koyalım
                  var width = (d['w'] / 640 * screenW).clamp(0.0, screenW);
                  var height = (d['h'] / 640 * screenH).clamp(0.0, screenH);
                  var left = (d['x'] / 640 * screenW - width / 2).clamp(0.0, screenW);
                  var top = (d['y'] / 640 * screenH - height / 2).clamp(0.0, screenH);

                  return Positioned(
                    left: left,
                    top: top,
                    width: width,
                    height: height,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.greenAccent, width: 3.0),
                        borderRadius: BorderRadius.circular(4.0),
                      ),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Container(
                          color: Colors.greenAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Text(
                            "${d['class']} ${(d['confidence'] * 100).toStringAsFixed(0)}%",
                            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ],
            ),
    );
  }
}
