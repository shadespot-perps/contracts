import os
import glob
import re

def clean_file(filepath):
    with open(filepath, 'r') as f:
        text = f.read()

    # Drop entire "Key differences" block in FHERouter and FHEOrderManager
    text = re.sub(r'\s*\*\s*Key differences from Router \(legacy plaintext architecture\):.*?(?=\s*\*\s*Open-position flow)', '\n *', text, flags=re.DOTALL)
    text = re.sub(r'\s*\*\s*Privacy improvements in this version:.*?(?=\s*\*\s*Open-position flow)', '\n *', text, flags=re.DOTALL)
    text = re.sub(r'\s*\*\s*Key differences from legacy.*?:.*?(?=\s*\*)', '\n *', text, flags=re.DOTALL)

    # IEncryptedERC20
    text = re.sub(r'Key differences from a standard ERC-20:', 'Encrypted ERC-20 operational model:', text)
    text = re.sub(r'Instead of approve, callers grant operators', 'Callers grant operators', text)

    # General phrases
    text = re.sub(r' — no plaintext exposed\.', '.', text)
    text = re.sub(r' — the plaintext never appears in calldata or storage\.', '.', text)
    text = re.sub(r' — the plaintext never appears in mempool calldata\.', '.', text)
    text = re.sub(r' — replaces plaintext amount', '', text)
    text = re.sub(r'instead of plaintext amounts', 'securely', text)
    text = re.sub(r'instead of transferFrom', 'securely', text)
    text = re.sub(r'instead of approve/allowance', 'securely', text)
    text = re.sub(r'instead of standard', 'securely', text)
    text = re.sub(r'plaintext collateral is unavailable', 'collateral remains strictly encrypted', text)
    text = re.sub(r'No plaintext amount is passed — ', '', text)
    text = re.sub(r'plaintext values never appear in mempool calldata\.', 'values remain strictly encrypted.', text)
    text = re.sub(r'no plaintext ever\.', 'fully encrypted.', text)
    text = re.sub(r'The plaintext _triggerPriceForExec mapping has been removed entirely\.', '', text)
    text = re.sub(r'\(plaintext — oracle prices are always public\)', '(oracle prices are natively public)', text)
    text = re.sub(r'amount is a verified plaintext', 'amount is a finalized verified value', text)
    text = re.sub(r'amounts are already verified plaintexts', 'amounts are finalized verified values', text)
    text = re.sub(r'Both values are verified plaintexts', 'Both values are finalized verified values', text)
    text = re.sub(r' — never plaintext', ' (remains fully encrypted)', text)
    text = re.sub(r'no amount is ever passed as a calldata plaintext', 'all volumes remain shielded on-chain', text)
    text = re.sub(r'\s*\*\s*Privacy note \(ShadeSpot\):.*?(?=\s*\*)', '\n *', text, flags=re.DOTALL)

    with open(filepath, 'w') as f:
        f.write(text)

files = glob.glob('src/**/*.sol', recursive=True)
for f in files:
    clean_file(f)

