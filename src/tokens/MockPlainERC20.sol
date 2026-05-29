// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockPlainERC20
 * @notice Dev plain ERC-20 underlying for composability (wrap / plain-open / plain LP).
 *         Public mint for testnet faucets — no access control.
 */
contract MockPlainERC20 is ERC20 {
    constructor() ERC20("Plain USDC", "pUSDC") {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
