import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'open_cam_onnx.dart';
import 'startpaage.dart';
import 'conditions.dart';
import 'splash_screen.dart';
import 'history_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Database silme iptal edildi (kullanıcı talebi: DB'de session silinmemesi)
  /*
  await _clearOldSessionsOnStartup();
  */

  try {
    cameras = await availableCameras();
  } catch (e) {
    print("Cam error: $e");
  }
  runApp(
    MaterialApp(
      title: 'RoadGuard',
      debugShowCheckedModeBanner: false,
      home: Startpaage(),
      routes: {
        '/conditions': (context) => const ConditionsPage(),
        '/splash_screen': (context) => const SplashScreen(),
        '/open_camera': (context) => const OpenCam(),
        '/history': (context) => const HistoryScreen(),
      },
    ),
  );
}
