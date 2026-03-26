// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Test / dev collateral token for Pool 1 (USDC / ETH).
 *
 * Matches real USDC conventions:
 *   - 6 decimals  (1 USDC = 1e6 units)
 *   - symbol "USDC"
 *
 * No access control on mint / burn — for local testing only.
 */
contract MockUSDC is ERC20 {

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
