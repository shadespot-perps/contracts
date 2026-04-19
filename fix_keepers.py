import re

# ------------- fix close.ts -------------
with open('keepers/src/keepers/close.ts', 'r') as f:
    text = f.read()

text = re.sub(
    r'const sizeHandle = BigInt\(position\.size as string\);\n\n\s*const \[finalAmountRes, sizeRes\] = await Promise\.all\(\[\n\s*decryptHandle\(onChainHandle, "finalAmount"\),\n\s*decryptHandle\(sizeHandle, "size"\),\n\s*\]\);',
    r'const sizeHandle = BigInt(position.size as string);\n  const isLongHandle = BigInt(position.isLong as string);\n\n  const [finalAmountRes, sizeRes, isLongRes] = await Promise.all([\n    decryptHandle(onChainHandle, "finalAmount"),\n    decryptHandle(sizeHandle, "size"),\n    decryptHandle(isLongHandle, "isLong"),\n  ]);',
    text
)

text = re.sub(
    r'const tx = await positionManager\.finalizeClosePosition\(\n\s*trader,\n\s*token,\n\s*isLong,\n\s*finalAmountRes\.value,\n\s*finalAmountRes\.sig,\n\s*sizeRes\.value,\n\s*sizeRes\.sig\n\s*\);',
    r'const tx = await positionManager.finalizeClosePosition(\n    positionKey,\n    finalAmountRes.value,\n    finalAmountRes.sig,\n    sizeRes.value,\n    sizeRes.sig,\n    isLongRes.value === 1n\n  );',
    text
)
with open('keepers/src/keepers/close.ts', 'w') as f:
    f.write(text)


# ------------- fix liq-final.ts -------------
with open('keepers/src/keepers/liq-final.ts', 'r') as f:
    text = f.read()

# Adding isLongHandle to PendingLiquidation interface
text = text.replace(
    'sizeHandle: bigint;\n}',
    'sizeHandle: bigint;\n  isLongHandle: bigint;\n}'
)

# building PendingLiquidation
text = re.sub(
    r'sizeHandle: BigInt\(position\.size as string\),\n\s*\}\;',
    r'sizeHandle: BigInt(position.size as string),\n    isLongHandle: BigInt(position.isLong as string),\n  };',
    text
)

# decrypting
text = re.sub(
    r'const \{ trader, token, isLong, positionKey, canLiquidateHandle, collateralHandle, sizeHandle \} = pending;\n\n\s*logger\.info\(\{ trader, isLong, positionKey, handle: canLiquidateHandle\.toString\(16\) \}, "Finalizing liquidation"\);\n\n\s*const \[canLiquidateRes, collateralRes, sizeRes\] = await Promise\.all\(\[\n\s*decryptHandle\(canLiquidateHandle, "canLiquidate"\),\n\s*decryptHandle\(collateralHandle, "collateral"\),\n\s*decryptHandle\(sizeHandle, "size"\),\n\s*\]\);',
    r'const { trader, token, isLong, positionKey, canLiquidateHandle, collateralHandle, sizeHandle, isLongHandle } = pending;\n\n  logger.info({ trader, isLong, positionKey, handle: canLiquidateHandle.toString(16) }, "Finalizing liquidation");\n\n  const [canLiquidateRes, collateralRes, sizeRes, isLongRes] = await Promise.all([\n    decryptHandle(canLiquidateHandle, "canLiquidate"),\n    decryptHandle(collateralHandle, "collateral"),\n    decryptHandle(sizeHandle, "size"),\n    decryptHandle(isLongHandle, "isLong"),\n  ]);',
    text
)

# finalize liquidation call
text = re.sub(
    r'const tx = await liquidationManager\.finalizeLiquidation\(\n\s*trader,\n\s*token,\n\s*isLong,\n\s*canLiquidatePlain,\n\s*canLiquidateRes\.sig,\n\s*collateralRes\.value,\n\s*collateralRes\.sig,\n\s*sizeRes\.value,\n\s*sizeRes\.sig\n\s*\);',
    r'const tx = await liquidationManager.finalizeLiquidation(\n          positionKey,\n          canLiquidatePlain,\n          canLiquidateRes.sig,\n          collateralRes.value,\n          collateralRes.sig,\n          sizeRes.value,\n          sizeRes.sig,\n          isLongRes.value === 1n\n        );',
    text
)

with open('keepers/src/keepers/liq-final.ts', 'w') as f:
    f.write(text)

print("done")
