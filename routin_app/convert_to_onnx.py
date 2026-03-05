"""
RDDC2020 PyTorch modelini ONNX formatına çevir
Versiyon uyuşmazlığı sorunlarını çözer
"""

import torch
import torch.onnx
import sys
import os

# YOLOv5 klasörüne ekle
sys.path.insert(0, './yolov5')

# YOLOv5 modüllerini import et
import models
from models.experimental import attempt_load

model_path = "weights/IMSC/last_95.pt"
output_path = "../assets/road_damage.onnx"

print("=" * 60)
print("RDDC2020 Model ONNX Dönüştürme")
print("=" * 60)

try:
    # Model yükle
    print(f"\n1. Model yükleniyor: {model_path}")
    checkpoint = torch.load(model_path, map_location='cpu', weights_only=False)
    
    if 'model' not in checkpoint:
        print("✗ Model anahtarı bulunamadı!")
        sys.exit(1)
    
    model = checkpoint['model']
    
    # Float modda çalıştır
    if hasattr(model, 'float'):
        model = model.float()
    
    # Eval moduna al
    if hasattr(model, 'eval'):
        model.eval()
    
    print("✓ Model yüklendi")
    
    # Fusing'i devre dışı bırak (hata kaynağı)
    print("\n2. Model yapılandırması...")
    for m in model.modules():
        if hasattr(m, 'fused'):
            m.fused = False
    
    # Input boyutunu tespit et
    img_size = 640
    batch_size = 1
    
    # Dummy input oluştur
    print(f"\n3. Dummy input oluşturuluyor: [{batch_size}, 3, {img_size}, {img_size}]")
    dummy_input = torch.randn(batch_size, 3, img_size, img_size, requires_grad=True)
    
    # ONNX export
    print(f"\n4. ONNX'e dönüştürülüyor...")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    torch.onnx.export(
        model,
        dummy_input,
        output_path,
        export_params=True,
        opset_version=12,  # Daha düşük versiyon - uyumluluk için
        do_constant_folding=True,
        input_names=['images'],
        output_names=['output'],
        dynamic_axes={
            'images': {0: 'batch', 2: 'height', 3: 'width'},
            'output': {0: 'batch'}
        }
    )
    
    print(f"\n{'=' * 60}")
    print(f"✓ BAŞARILI!")
    print(f"ONNX model hazır: {output_path}")
    
    # Dosya boyutunu göster
    file_size = os.path.getsize(output_path) / (1024 * 1024)
    print(f"Dosya boyutu: {file_size:.2f} MB")
    print(f"{'=' * 60}")
    
    print("\nFlutter'da kullanım için:")
    print("1. pubspec.yaml'a ekle: onnxruntime: ^1.14.0")
    print("2. assets/road_damage.onnx dosyasını kullan")
    
except Exception as e:
    print(f"\n✗ HATA: {e}")
    import traceback
    traceback.print_exc()
    
    print("\n" + "=" * 60)
    print("Alternatif Çözüm:")
    print("=" * 60)
    print("Google Colab kullanarak:")
    print("1. https://colab.research.google.com/ aç")
    print("2. Model dosyasını yükle")
    print("3. Eski PyTorch/YOLOv5 versiyonu ile dönüştür")
