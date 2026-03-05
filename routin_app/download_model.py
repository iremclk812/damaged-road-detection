import urllib.request
import os

print("Road Damage Detection modeli indiriliyor...")

# Roboflow'dan hazır bir Road Damage .tflite modeli
# veya başka bir kaynak kullanabiliriz

# Şimdilik basit bir YOLOv5s modelini TFLite formatında indirelim
# Gerçek Road Damage modeli için Roboflow API kullanabilirsiniz

model_url = "https://github.com/zldrobit/tfjs/releases/download/v0.0.1/yolov5s_web_model.zip"
output_path = "assets/model_temp.zip"

print(f"İndirme başlıyor: {model_url}")
print("Not: Bu genel bir YOLO modeli. Road Damage için özel model gerekiyor.")
print("\nAlternatif: Roboflow Universe'den Road Damage Detection modeli indirin:")
print("https://universe.roboflow.com/road-damage-detection")
print("\nVeya PyTorch modelini TFLite'a dönüştürmek için:")
print("1. Google Colab açın")
print("2. YOLOv5 reposunu klonlayın")
print("3. export.py --weights last_95.pt --include tflite çalıştırın")

# urllib.request.urlretrieve(model_url, output_path)
# print(f"Model indirildi: {output_path}")
