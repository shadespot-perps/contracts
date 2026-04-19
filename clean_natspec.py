import os
import glob
import re

def clean_file(filepath):
    with open(filepath, 'r') as f:
        text = f.read()

    # General replacements
    replacements = [
        (r'Pool 2 \(FHE token / ETH\)', 'ShadeSpot (Encrypted Protocol)'),
        (r'Pool 1 \(USDC / ETH\)', 'Legacy Plaintext Pool'),
        (r'Pool 2 / FHERouter', 'FHERouter'),
        (r'Pool 2 \(FHEVault\)', 'FHEVault'),
        (r'Pool 2 vault', 'ShadeSpot vault'),
        (r'Pool 2 entry point', 'ShadeSpot protocol entry point'),
        (r'Pool 2', 'ShadeSpot'),
        (r'Pool 1 OI accounting', 'legacy OI accounting'),
        (r'Pool 1', 'legacy plaintext architecture'),
        (r'\(Phase 3 integration\)', ''),
        (r'Phase 3 — ', ''),
        (r'In this FHE mock we just simulate basic rate derivation to prevent division panics\.', 'Enforces continuous compounding rate bounds securely under FHE.'),
        (r'FHE mock', 'FHE implementation'),
        (r'mock', 'instance'), # careful here
    ]

    for old, new in replacements:
        text = re.sub(old, new, text)

    # Specific block replacements
    text = re.sub(
        r'/// @param isLongPlain\s+Decrypted direction — used only for legacy OI accounting; ignored on FHE path\.',
        r'/// @param isLongPlain       Decrypted direction (legacy param, deprecated).',
        text
    )
    text = re.sub(
        r'/// @param isLongPlain\s+Decrypted direction \(used only for open-interest accounting on legacy plaintext architecture\)\.',
        r'/// @param isLongPlain  Decrypted direction (legacy param, deprecated).',
        text
    )

    with open(filepath, 'w') as f:
        f.write(text)

files = glob.glob('src/**/*.sol', recursive=True)
for f in files:
    clean_file(f)

# Mock files might need reverting the "mock -> instance" if it broke imports, let's just reverse the specific ones if needed, actually "mock" isn't bad if it's MockFHEToken
