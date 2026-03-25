// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionId, ITaskManager, EncryptedInput} from "cofhe-contracts/ICofhe.sol";

/**
 * @title MockTaskManager
 * @notice Drop-in replacement for the CoFHE TaskManager used in Foundry tests.
 *
 * Strategy — handle = plaintext value:
 *   - trivialEncrypt(x)       → returns x as the handle.
 *   - arithmetic / comparison → computes the exact result; result IS the handle.
 *   - getDecryptResultSafe(h) → (h, true) — always immediately available.
 *
 * Etch at TASK_MANAGER_ADDRESS in setUp:
 *   vm.etch(0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9, address(new MockTaskManager()).code);
 */
contract MockTaskManager is ITaskManager {

    // -------------------------------------------------------
    // Core task execution
    // -------------------------------------------------------

    function createTask(
        uint8            /* returnType */,
        FunctionId       funcId,
        uint256[] memory encryptedInputs,
        uint256[] memory extraInputs
    ) external pure override returns (uint256) {

        uint256 a = encryptedInputs.length > 0 ? encryptedInputs[0] : 0;
        uint256 b = encryptedInputs.length > 1 ? encryptedInputs[1] : 0;
        uint256 c = encryptedInputs.length > 2 ? encryptedInputs[2] : 0;

        if (funcId == FunctionId.trivialEncrypt) return extraInputs.length > 0 ? extraInputs[0] : 0;
        if (funcId == FunctionId.cast)           return a;
        if (funcId == FunctionId.select)         return a != 0 ? b : c;
        if (funcId == FunctionId.sub)            return a >= b ? a - b : 0;
        if (funcId == FunctionId.add)            return a + b;
        if (funcId == FunctionId.xor)            return a ^ b;
        if (funcId == FunctionId.and)            return (a != 0 && b != 0) ? 1 : 0;
        if (funcId == FunctionId.or)             return (a != 0 || b != 0) ? 1 : 0;
        if (funcId == FunctionId.not)            return a == 0 ? 1 : 0;
        if (funcId == FunctionId.div)            return b > 0 ? a / b : 0;
        if (funcId == FunctionId.rem)            return b > 0 ? a % b : 0;
        if (funcId == FunctionId.mul)            return a * b;
        if (funcId == FunctionId.shl)            return a << b;
        if (funcId == FunctionId.shr)            return a >> b;
        if (funcId == FunctionId.gte)            return a >= b ? 1 : 0;
        if (funcId == FunctionId.lte)            return a <= b ? 1 : 0;
        if (funcId == FunctionId.lt)             return a <  b ? 1 : 0;
        if (funcId == FunctionId.gt)             return a >  b ? 1 : 0;
        if (funcId == FunctionId.min)            return a <  b ? a : b;
        if (funcId == FunctionId.max)            return a >  b ? a : b;
        if (funcId == FunctionId.eq)             return a == b ? 1 : 0;
        if (funcId == FunctionId.ne)             return a != b ? 1 : 0;
        if (funcId == FunctionId.square)         return a * a;
        return 0;
    }

    function createRandomTask(uint8 /* returnType */, uint256 seed, int32 /* securityZone */)
        external pure override returns (uint256)
    {
        return uint256(keccak256(abi.encode(seed)));
    }

    /// Verifies an encrypted input — in tests, just return the ctHash directly.
    function verifyInput(EncryptedInput memory input, address /* sender */)
        external pure override returns (uint256)
    {
        return input.ctHash;
    }

    // -------------------------------------------------------
    // Decrypt
    // -------------------------------------------------------

    /// Handle IS the plaintext — always immediately ready.
    function getDecryptResultSafe(uint256 ctHash)
        external pure override returns (uint256, bool)
    {
        return (ctHash, true);
    }

    function getDecryptResult(uint256 ctHash)
        external pure override returns (uint256)
    {
        return ctHash;
    }

    function createDecryptTask(uint256 /* ctHash */, address /* requestor */) external pure override {}

    function publishDecryptResult(uint256 /* ctHash */, uint256 /* result */, bytes calldata /* sig */)
        external pure override {}

    function publishDecryptResultBatch(
        uint256[] calldata /* ctHashes */,
        uint256[] calldata /* results */,
        bytes[]   calldata /* signatures */
    ) external pure override {}

    function verifyDecryptResult(uint256 /* ctHash */, uint256 /* result */, bytes calldata /* sig */)
        external pure override returns (bool) { return true; }

    function verifyDecryptResultSafe(uint256 /* ctHash */, uint256 /* result */, bytes calldata /* sig */)
        external pure override returns (bool) { return true; }

    // -------------------------------------------------------
    // Access control (no-ops in tests)
    // -------------------------------------------------------

    function allow(uint256 /* ctHash */, address /* account */) external pure override {}
    function allowGlobal(uint256 /* ctHash */) external pure override {}
    function allowTransient(uint256 /* ctHash */, address /* account */) external pure override {}

    function isAllowed(uint256 /* ctHash */, address /* account */)
        external pure override returns (bool) { return true; }

    function isPubliclyAllowed(uint256 /* ctHash */)
        external pure override returns (bool) { return true; }
}
