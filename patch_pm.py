import re

with open('src/core/PositionManager.sol', 'r') as f:
    text = f.read()

# Delete lines 409-412
text = re.sub(
    r'    // OI accounting — only relevant for Pool 1.*?}\n',
    '', text, flags=re.DOTALL
)

# Replace calculateFundingFee
new_funding_logic = """    function calculateFundingFee(
        Position memory position
    ) public returns (euint128) {
        euint128 eCurrentBiased = fundingManagerFHE.getFundingRateBiased(position.indexToken);

        // |currentBiased - entryBiased| entirely in FHE — no plaintext diff leaked.
        FHE.allowTransient(position.entryFundingRateBiased, address(this));
        ebool currentGteEntry = FHE.gte(eCurrentBiased, position.entryFundingRateBiased);
        euint128 diffMagnitude = FHE.select(
            currentGteEntry,
            FHE.sub(eCurrentBiased, position.entryFundingRateBiased),
            FHE.sub(position.entryFundingRateBiased, eCurrentBiased)
        );

        return FHE.div(
            FHE.mul(position.size, diffMagnitude),
            FHE.asEuint128(FUNDING_PRECISION)
        );
    }"""
text = re.sub(
    r'    function calculateFundingFee\(\n.*?returns \(euint128\) \{.*?\n    \}',
    new_funding_logic, text, flags=re.DOTALL
)

# Delete lines 620-622 (else block)
text = re.sub(
    r'        } else \{\n\s*fundingManager\.decreaseOpenInterest.*?\}',
    '        }', text, flags=re.DOTALL
)

with open('src/core/PositionManager.sol', 'w') as f:
    f.write(text)

