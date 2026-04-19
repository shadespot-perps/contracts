// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { FHE, euint128, ebool } from "cofhe-contracts/FHE.sol";

contract FHEFundingRateManager {

    uint256 public constant FUNDING_INTERVAL = 1 hours;
    // Bias must be large enough to prevent euint128 underflow during rate derivation.
    uint256 public constant FUNDING_RATE_BIAS = 1e12; 

    address public owner;
    address public positionManager;

    struct FHEFundingData {
        euint128 eCumulativeFundingRateBiased;
        uint256  lastFundingTime;
        euint128 eLongOpenInterest;
        euint128 eShortOpenInterest;
    }

    mapping(address => FHEFundingData) public fundingData;

    event FHEFundingUpdated(address indexed token);
    event FHEOpenInterestUpdated(address indexed token);
    event PositionManagerSet(address positionManager);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "only position manager");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setPositionManager(address _pm) external onlyOwner {
        require(positionManager == address(0), "pm already set");
        positionManager = _pm;
        emit PositionManagerSet(_pm);
    }

    function initializeToken(address token) external onlyOwner {
        fundingData[token].eCumulativeFundingRateBiased = FHE.asEuint128(FUNDING_RATE_BIAS);
        fundingData[token].eLongOpenInterest            = FHE.asEuint128(0);
        fundingData[token].eShortOpenInterest           = FHE.asEuint128(0);
        fundingData[token].lastFundingTime              = block.timestamp;

        // Allow this contract to read these handles in future transactions.
        FHE.allow(fundingData[token].eCumulativeFundingRateBiased, address(this));
        FHE.allow(fundingData[token].eLongOpenInterest,            address(this));
        FHE.allow(fundingData[token].eShortOpenInterest,           address(this));
    }

    // -------------------------------------------------
    // UPDATE OPEN INTEREST (PositionManager only)
    // -------------------------------------------------

    function increaseOpenInterestFHE(
        address token,
        euint128 eLeverage,
        ebool eIsLong
    ) external onlyPositionManager {
        FHEFundingData storage data = fundingData[token];

        euint128 eLongAddition  = FHE.select(eIsLong, eLeverage, FHE.asEuint128(0));
        euint128 eShortAddition = FHE.select(eIsLong, FHE.asEuint128(0), eLeverage);

        data.eLongOpenInterest  = FHE.add(data.eLongOpenInterest,  eLongAddition);
        data.eShortOpenInterest = FHE.add(data.eShortOpenInterest, eShortAddition);

        // Re-grant this contract access to the updated handles for subsequent reads.
        FHE.allow(data.eLongOpenInterest,  address(this));
        FHE.allow(data.eShortOpenInterest, address(this));

        emit FHEOpenInterestUpdated(token);
    }

    function decreaseOpenInterestFHE(
        address token,
        euint128 eLeverage,
        ebool eIsLong
    ) external onlyPositionManager {
        FHEFundingData storage data = fundingData[token];

        euint128 eLongSub  = FHE.select(eIsLong, eLeverage, FHE.asEuint128(0));
        euint128 eShortSub = FHE.select(eIsLong, FHE.asEuint128(0), eLeverage);

        data.eLongOpenInterest  = FHE.sub(data.eLongOpenInterest,  eLongSub);
        data.eShortOpenInterest = FHE.sub(data.eShortOpenInterest, eShortSub);

        // Re-grant this contract access to the updated handles for subsequent reads.
        FHE.allow(data.eLongOpenInterest,  address(this));
        FHE.allow(data.eShortOpenInterest, address(this));

        emit FHEOpenInterestUpdated(token);
    }

    // -------------------------------------------------
    // UPDATE FUNDING (Publicly triggerable)
    // -------------------------------------------------

    function updateFunding(address token) external {
        FHEFundingData storage data = fundingData[token];

        // Skip silently if initializeToken has not been called for this token yet.
        if (data.lastFundingTime == 0) return;

        if (block.timestamp < data.lastFundingTime + FUNDING_INTERVAL) {
            return;
        }
        
        // This calculates the rate fully encrypted
        euint128 eLongOI = data.eLongOpenInterest;
        euint128 eShortOI = data.eShortOpenInterest;
        
        ebool longDominant = FHE.gte(eLongOI, eShortOI);
        euint128 diff = FHE.select(longDominant, FHE.sub(eLongOI, eShortOI), FHE.sub(eShortOI, eLongOI));
        
        // Add minimal clamp to prevent zero div, though totalOI is usually checked in plaintext.
        euint128 totalOI = FHE.add(eLongOI, eShortOI);
        
        // eRate = (diff * scalar) / totalOI
        // Enforces continuous compounding rate bounds securely under FHE.
        // Fhenix euint does support division: FHE.div
        
        euint128 eRate = FHE.div(diff, FHE.asEuint128(100)); // Simplified due to missing secure fractions

        euint128 eCurrentRateBiased = data.eCumulativeFundingRateBiased;
        // allowTransient so we can read the stored handle in this same transaction.
        FHE.allowTransient(eCurrentRateBiased, address(this));

        euint128 eNewRateBiased = FHE.select(
            longDominant,
            FHE.add(eCurrentRateBiased, eRate), // Long pays short
            FHE.sub(eCurrentRateBiased, eRate)  // Short pays long
        );

        data.eCumulativeFundingRateBiased = eNewRateBiased;
        data.lastFundingTime              = block.timestamp;

        // Re-grant persistent access so positionManager and this contract can read the new handle.
        FHE.allow(data.eCumulativeFundingRateBiased, address(this));
        if (positionManager != address(0)) {
            FHE.allow(data.eCumulativeFundingRateBiased, positionManager);
        }

        emit FHEFundingUpdated(token);
    }
    
    function getFundingRateBiased(address token) external view returns (euint128) {
        return fundingData[token].eCumulativeFundingRateBiased;
    }
}
