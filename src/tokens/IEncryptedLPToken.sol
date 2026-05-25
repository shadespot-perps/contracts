// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { euint64 } from "cofhe-contracts/FHE.sol";

interface IEncryptedLPToken {
    function mint(address to,   euint64 eAmount) external;
    function burn(address from, euint64 eAmount) external;
}
