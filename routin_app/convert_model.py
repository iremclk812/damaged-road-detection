#!/usr/bin/env python3
"""
RDDC2020 YOLOv5 modelini TFLite formatına dönüştürme scripti
"""

import os
import sys
import subprocess

print("=" * 60)
print("RDDC2020 Model Dönüştürme Scripti")
print("=" * 60)

# Adım 1: RDDC2020 reposunu klonla
print("\n[1/5] RDDC2020 reposu klonlanıyor...")
if not os.path.exists("rddc2020"):
    subprocess.run(["git", "clone", "https://github.com/USC-InfoLab/rddc2020.git"], check=True)
    print("✓ RDDC2020 klonlandı")
else:
    print("✓ RDDC2020 zaten mevcut")

os.chdir("rddc2020")

# Adım 2: Gerekli paketleri yükle
print("\n[2/5] Gerekli Python paketleri yükleniyor...")
subprocess.run([sys.executable, "-m", "pip", "install", "-r", "yolov5/requirements.txt"], check=True)
subprocess.run([sys.executable, "-m", "pip", "install", "tensorflow", "gdown"], check=True)
print("✓ Paketler yüklendi")

# Adım 3: RDDC2020 eğitilmiş modelini indir
print("\n[3/5] RDDC2020 eğitilmiş model indiriliyor...")
weights_dir = "yolov5/weights/IMSC"
os.makedirs(weights_dir, exist_ok=True)

# En iyi modeli indir
model_path = os.path.join(weights_dir, "last_95.pt")

if not os.path.exists(model_path):
    print("⚠ Model otomatik indirilemedi çünkü Drive izin engeline takıldı.")
    print("Lütfen modeli manuel olarak indirip şu yola koyun:")
    print(f"  → {os.path.abspath(model_path)}")
    sys.exit(1)
else:
    print("✓ Model zaten mevcut")

# Adım 4: Model dönüştürme (.pt → .tflite)
print("\n[4/5] Model TFLite formatına dönüştürülüyor...")
print("Bu işlem birkaç dakika sürebilir...")

# export.py'nin bulunduğu ana dizindeki yolov5 klasörüne geç
os.chdir("../yolov5")

# mode_path'i yolov5'in köküne göre güncelle
actual_model_path = "weights/IMSC/last_95.pt"

export_cmd = [
    sys.executable,
    "export.py",
    "--weights", actual_model_path,
    "--include", "tflite",
    "--img", "416",  # Mobil için optimize boyut
    "--batch", "1"
]

try:
    subprocess.run(export_cmd, check=True)
    print("✓ Model başarıyla dönüştürüldü")
except Exception as e:
    print(f"✗ Dönüştürme hatası: {e}")
    sys.exit(1)

# Adım 5: TFLite modelini Flutter assets klasörüne kopyala
print("\n[5/5] Model Flutter projesine kopyalanıyor...")
tflite_model = actual_model_path.replace(".pt", "-fp16.tflite")
if not os.path.exists(tflite_model):
    tflite_model = actual_model_path.replace(".pt", "-int8.tflite")
if not os.path.exists(tflite_model):
    tflite_model = actual_model_path.replace(".pt", ".tflite")

assets_dir = "../routin_app/assets"
os.makedirs(assets_dir, exist_ok=True)
target_path = os.path.join(assets_dir, "model.tflite")

if os.path.exists(tflite_model):
    import shutil
    shutil.copy(tflite_model, target_path)
    print(f"✓ Model kopyalandı: {target_path}")
    
    print("\n" + "=" * 60)
    print("BAŞARILI! Model hazır.")
    print("=" * 60)
    print(f"\nModel konumu: {os.path.abspath(target_path)}")
    print(f"Model boyutu: {os.path.getsize(target_path) / (1024*1024):.2f} MB")
    print("\nŞimdi Flutter uygulamanızı çalıştırabilirsiniz:")
    print("  → flutter run")
else:
    print("✗ TFLite model dosyası bulunamadı")
    print(f"Aranan: {tflite_model}")
    sys.exit(1)
