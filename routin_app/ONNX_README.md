# RDDC2020 ONNX Model Hazırlama - BAŞARILI! ✓

## Yapılanlar

### 1. Model İndirme
- Google Drive'dan RDDC2020 YOLOv5x modeli indirildi
- Dosya: `last_95.pt` (178 MB)
- Model eğitilmiş road damage sınıfları: D00, D10, D20, D40

### 2. ONNX Dönüştürme ✓
```bash
cd yolov5
python convert_onnx.py
```
- **Başarılı!** Model ONNX formatına çevrildi
- Output: `assets/road_damage.onnx` (337 MB)
- Input shape: [1, 3, 640, 640] (CHW formatı)
- Output: YOLOv5 detection tensors

### 3. Flutter Entegrasyonu
- `pubspec.yaml` güncellendi
- `onnxruntime: ^1.4.1` eklendi
- `open_cam_onnx.dart` oluşturuldu

## Dosya Konumları
```
routin_app/
├── assets/
│   ├── road_damage.onnx  ✓ (337 MB - HAZIR!)
│   └── labelmap.txt       ✓ (D00, D10, D20, D40)
├── yolov5/
│   └── weights/IMSC/
│       └── last_95.pt     ✓ (178 MB)
└── lib/
    └── open_cam_onnx.dart ✓ (ONNX implementasyonu)
```

## Kullanım

### Option 1: ONNX kullan (ÖNERİLEN)
```dart
// main.dart'ta import değiştir:
import 'lib/open_cam_onnx.dart';  // Yeni ONNX versiyonu
```

### Option 2: Eski TFLite (çalışmıyor - model hatası)
- Şu an için TFLite versiyonu çalışmıyor
- ONNX versiyonu kullanılmalı

## Model Özellikleri
- **Format:** ONNX
- **Input:** 640x640 RGB görüntü (CHW formatı)
- **Output:** YOLOv5 detection [1, 25200, 85]
  - 4 bbox koordinatları (x, y, w, h)
  - 1 confidence score
  - 80 class scores (RDDC2020: D00, D10, D20, D40)
- **Threshold:** 0.5 confidence

## Road Damage Sınıfları
- **D00:** Longitudinal Crack (Boyuna çatlak)
- **D10:** Transverse Crack (Enine çatlak)  
- **D20:** Alligator Crack (Timsah çatlağı)
- **D40:** Pothole (Çukur)

## Test
```bash
flutter run
```

Kamera açıldığında:
1. Model otomatik yüklenecek
2. Her 10 frame'de tespit çalışacak
3. Tespit edilen hasarlar kırmızı uyarı ile gösterilecek

## Performans
- Model boyutu: 337 MB (büyük ama doğru)
- Frame atlama: Her 10 frame (buffer overflow önleme)
- Input resize: 640x640 (modelin beklediği boyut)
- YUV420 -> RGB dönüşümü

## Sonraki Adımlar
1. ✓ Model hazır
2. ✓ ONNX entegrasyonu tamamlandı
3. ⏳ GPS koordinat entegrasyonu
4. ⏳ Hız ve mesafe hesaplama
5. ⏳ Kamera açısı kalibrasyonu

## Not
- ONNX modeli TFLite'dan daha iyi uyumluluk gösteriyor
- Flutter onnxruntime paketi stable
- Model Google Drive'dan başarıyla indirildi
