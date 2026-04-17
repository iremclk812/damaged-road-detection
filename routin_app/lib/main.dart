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

Future<void> _clearOldSessionsOnStartup() async {
  try {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'roadguard_database.db');

    // Sadece tabloyu silmek istiyorsak open database yapıp DELETE de diyebiliriz
    // ama en temizi, başlarken tüm DB dosyasını silip taze başlamaktır.
    await deleteDatabase(path);
    debugPrint("Old session database deleted on startup.");
  } catch (e) {
    debugPrint("DB delete error: $e");
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Uygulama her sıfırdan başladığında eski verilerin tutulduğu veritabanını yok et
  await _clearOldSessionsOnStartup();

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
        '/open_camera': (context) => const OpenCam(),
        '/history': (context) => const HistoryScreen(),
      },
    ),
  );
}
