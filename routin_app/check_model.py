import torch
import sys

print("Model kontrol ediliyor...")
model_path = "yolov5/weights/IMSC/last_95.pt"

try:
    # Model yükle
    checkpoint = torch.load(model_path, map_location='cpu')
    
    print("\n=== Model Bilgileri ===")
    print(f"Model anahtarları: {list(checkpoint.keys())}")
    
    if 'model' in checkpoint:
        model = checkpoint['model']
        print(f"\nModel tipi: {type(model)}")
        
        # Model yapılandırması
        if hasattr(model, 'yaml'):
            print(f"\nYAML config:")
            print(model.yaml)
    
    # Epoch bilgisi
    if 'epoch' in checkpoint:
        print(f"\nEpoch: {checkpoint['epoch']}")
    
    # Input shape bilgisi
    if 'model' in checkpoint:
        try:
            print(f"\nModel summary:")
            print(model)
        except Exception as e:
            print(f"Model summary hatası: {e}")
    
    print("\n✓ Model dosyası sağlam görünüyor!")
    print("\nSorun: YOLOv5 versiyonu uyumsuzluğu olabilir.")
    print("Çözüm: ONNX formatına çevirelim")
    
except Exception as e:
    print(f"\n✗ HATA: {e}")
    import traceback
    traceback.print_exc()
