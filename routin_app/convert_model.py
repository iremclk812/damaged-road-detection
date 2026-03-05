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

# Adım 1: YOLOv5 reposunu klonla
print("\n[1/5] YOLOv5 reposu klonlanıyor...")
if not os.path.exists("yolov5"):
    subprocess.run(["git", "clone", "https://github.com/ultralytics/yolov5.git"], check=True)
    print("✓ YOLOv5 klonlandı")
else:
    print("✓ YOLOv5 zaten mevcut")

os.chdir("yolov5")

# Adım 2: Gerekli paketleri yükle
print("\n[2/5] Gerekli Python paketleri yükleniyor...")
subprocess.run([sys.executable, "-m", "pip", "install", "-r", "requirements.txt"], check=True)
subprocess.run([sys.executable, "-m", "pip", "install", "tensorflow"], check=True)
print("✓ Paketler yüklendi")

# Adım 3: RDDC2020 eğitilmiş modelini indir
print("\n[3/5] RDDC2020 eğitilmiş model indiriliyor...")
weights_dir = "weights/IMSC"
os.makedirs(weights_dir, exist_ok=True)

# En iyi modeli indir (Google Drive'dan veya alternatif kaynak)
model_url = "https://github.com/USC-InfoLab/rddc2020/releases/download/v1.0/last_95.pt"
model_path = os.path.join(weights_dir, "last_95.pt")

if not os.path.exists(model_path):
    print("Model dosyası internetten indiriliyor...")
    print("NOT: Eğer model linki çalışmazsa, manuel olarak indirip bu klasöre koyun:")
    print(f"  → {os.path.abspath(model_path)}")
    
    try:
        subprocess.run(["curl", "-L", "-o", model_path, model_url], check=True)
        print("✓ Model indirildi")
    except:
        print("⚠ Model otomatik indirilemedi.")
        print("Lütfen manuel olarak şu adımları izleyin:")
        print("1. https://github.com/USC-InfoLab/rddc2020 adresine gidin")
        print("2. 'yolov5/scripts/download_IMSC_grddc2020_weights.sh' scriptini çalıştırın")
        print("3. İndirilen 'last_95.pt' dosyasını şuraya kopyalayın:")
        print(f"   → {os.path.abspath(model_path)}")
        sys.exit(1)
else:
    print("✓ Model zaten mevcut")

# Adım 4: Model dönüştürme (.pt → .tflite)
print("\n[4/5] Model TFLite formatına dönüştürülüyor...")
print("Bu işlem birkaç dakika sürebilir...")

export_cmd = [
    sys.executable,
    "export.py",
    "--weights", model_path,
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
tflite_model = model_path.replace(".pt", "-fp16.tflite")
if not os.path.exists(tflite_model):
    tflite_model = model_path.replace(".pt", ".tflite")

assets_dir = "../assets"
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
