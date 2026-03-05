"""
RDDC2020 Model İndirme ve Dönüştürme
Google Drive'dan model indir ve .tflite'a çevir
"""

import os
import sys

# gdown yüklü değilse yükle
try:
    import gdown
except ImportError:
    print("gdown yükleniyor...")
    os.system('pip install gdown')
    import gdown

# Model indirme URL'leri
MODELS = {
    'last_95.pt': 'https://drive.google.com/uc?id=1Xu2KDBkD09E7ItOkKrodM_XzOQu-6Mhl',
    'last_95_640_16.pt': 'https://drive.google.com/uc?id=1Fw6_ku3Z8aTdy4vwjZatHTkaNyeT7ZoZ',
    'last_95_448_32_aug2.pt': 'https://drive.google.com/uc?id=1F_0MHIBuO1wgVwePk6UAuFudKmCf_7Fs',
    'last_100_100_640_16.pt': 'https://drive.google.com/uc?id=1ky9aZ1ygiy2qXlY_zcpj_4QI1ccfQTcE',
    'last_120_640_32_aug2.pt': 'https://drive.google.com/uc?id=1Wd1KA8j-q6qRQzy6ytLEav89xsmiqLFB'
}

def download_model(model_name='last_95.pt'):
    """Google Drive'dan model indir"""
    weights_dir = 'yolov5/weights/IMSC'
    os.makedirs(weights_dir, exist_ok=True)
    
    output_path = os.path.join(weights_dir, model_name)
    url = MODELS[model_name]
    
    print(f"İndiriliyor: {model_name}")
    print(f"URL: {url}")
    print(f"Hedef: {output_path}")
    
    gdown.download(url, output_path, quiet=False)
    
    if os.path.exists(output_path):
        print(f"✓ İndirme başarılı: {output_path}")
        return output_path
    else:
        print(f"✗ İndirme başarısız!")
        return None

def convert_to_tflite(pt_file):
    """PyTorch modelini TFLite'a çevir"""
    print(f"\n.tflite'a dönüştürülüyor: {pt_file}")
    
    # export.py yolunu belirle
    export_script = 'yolov5/export.py'
    
    # Dönüştürme komutu
    cmd = f'python {export_script} --weights {pt_file} --include tflite --img 416'
    print(f"Komut: {cmd}")
    
    result = os.system(cmd)
    
    if result == 0:
        tflite_file = pt_file.replace('.pt', '.tflite')
        print(f"✓ Dönüştürme başarılı: {tflite_file}")
        return tflite_file
    else:
        print("✗ Dönüştürme başarısız!")
        return None

if __name__ == '__main__':
    print("=" * 60)
    print("RDDC2020 Model İndirme ve Dönüştürme")
    print("=" * 60)
    
    # Kullanılabilir modeller
    print("\nKullanılabilir modeller:")
    for i, model in enumerate(MODELS.keys(), 1):
        print(f"{i}. {model}")
    
    # Varsayılan olarak last_95.pt indir
    model_name = 'last_95.pt'
    print(f"\nVarsayılan model indiriliyor: {model_name}")
    
    # İndir
    pt_file = download_model(model_name)
    
    if pt_file:
        # .tflite'a çevir
        tflite_file = convert_to_tflite(pt_file)
        
        if tflite_file:
            # assets/ klasörüne kopyala
            assets_dir = 'assets'
            os.makedirs(assets_dir, exist_ok=True)
            
            import shutil
            dest = os.path.join(assets_dir, 'model.tflite')
            shutil.copy(tflite_file, dest)
            
            print(f"\n{'=' * 60}")
            print(f"✓ BAŞARILI!")
            print(f"Model hazır: {dest}")
            print(f"{'=' * 60}")
        else:
            print("\n✗ Dönüştürme başarısız oldu!")
            print("\nManuel dönüştürme için:")
            print(f"python yolov5/export.py --weights {pt_file} --include tflite --img 416")
    else:
        print("\n✗ İndirme başarısız oldu!")
        print("\nManuel indirme için tarayıcıda aç:")
        print(MODELS[model_name])
