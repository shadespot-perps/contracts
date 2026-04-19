import os
import glob
import re

def clean_file(filepath):
    if not os.path.exists(filepath):
        return

    with open(filepath, 'r') as f:
        text = f.read()

    text = re.sub(r'no plaintext amount crosses the PositionManager', 'no unencrypted amount crosses the PositionManager', text)
    text = re.sub(r'`amount` is a verified plaintext from', '`amount` is a verified decrypted value from', text)
    text = re.sub(r'no longer accepts a plaintext amount — each vault reads', 'securely consumes locally stored encrypted', text)
    text = re.sub(r'the plaintext never$', 'raw values remain hidden.', text, flags=re.MULTILINE)
    text = re.sub(r'Plaintext share amount to redeem', 'Standard share amount to redeem', text)

    with open(filepath, 'w') as f:
        f.write(text)

files = glob.glob('src/**/*.sol', recursive=True)
for f in files:
    clean_file(f)
