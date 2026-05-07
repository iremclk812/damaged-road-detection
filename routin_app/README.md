# Road Damage Detection Mobile App

A Flutter-based mobile application for detecting road surface damage using a YOLOv5 ONNX model, live camera input, GPS data, and mobile sensor information.

This project focuses on identifying road damage types such as cracks and potholes in real time, making it useful for smart transportation, road maintenance, and mobile infrastructure monitoring.

---

## Features

- Live camera-based road damage detection
- YOLOv5 ONNX model integration
- Real-time object detection on mobile
- Road damage class prediction
- GPS location support
- Sensor-based road condition analysis
- Local data handling with SQLite
- Flutter cross-platform mobile structure

---

## Road Damage Classes

The model is trained to detect the following road damage categories:

| Class | Description |
|---|---|
| D00 | Longitudinal Crack |
| D10 | Transverse Crack |
| D20 | Alligator Crack |
| D40 | Pothole |

---

## Tech Stack

- Flutter
- Dart
- ONNX Runtime
- YOLOv5
- Camera Plugin
- Geolocator
- Sensors Plus
- SQLite / Sqflite
- Image Processing

---

## Model Information

The application uses a road damage detection model converted from PyTorch to ONNX format.

- Original model: YOLOv5x
- Dataset/model source: RDDC2020 road damage detection model
- ONNX model file: `assets/road_damage.onnx`
- Input size: `640 x 640`
- Input format: RGB image in CHW format
- Output format: YOLOv5 detection tensor
- Detection classes: D00, D10, D20, D40

---

## Project Structure

```txt
routin_app/
├── assets/
│   └── road_damage.onnx
├── lib/
│   ├── main.dart
│   ├── open_cam_onnx.dart
│   ├── history_screen.dart
│   ├── admin.dart
│   ├── conditions.dart
│   ├── splash_screen.dart
│   └── startpaage.dart
├── android/
├── ios/
├── pubspec.yaml
└── ONNX_README.md
