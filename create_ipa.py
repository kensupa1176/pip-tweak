#!/usr/bin/env python3
import zipfile
import os
import sys

# プロジェクトルートから実行された場合、MyAppディレクトリに移動
script_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(script_dir)
os.chdir(project_root)

with zipfile.ZipFile('MyApp_pip.ipa', 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk('MyApp/Payload'):
        for file in files:
            filepath = os.path.join(root, file)
            arcname = filepath.replace('MyApp/', '')
            zf.write(filepath, arcname)
            
print('IPA created successfully')
