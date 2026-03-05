import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'open_cam_onnx.dart';
import 'startpaage.dart';
import 'conditions.dart';
import 'splash_screen.dart';

List<CameraDescription> cameras = [];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    print("Cam error: $e");
  }
  runApp(
    MaterialApp(
      home: Startpaage(),
      routes: {
        '/conditions': (context) => const ConditionsPage(),
        '/splash_screen': (context) => const SplashScreen(),
        '/open_camera': (context) => OpenCam(),
      },
    ),
  );
}
