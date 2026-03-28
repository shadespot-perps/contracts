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
    // Boolean sentinel encoding
    //
    // The CoFHE library treats handle == 0 as "uninitialized" and substitutes
    // asEbool(true) in and/or, asEbool(false) in select, etc.  If we returned 0
    // for encrypted-false the library would silently flip the value.
    //
    // Encoding: 1 = true,  BOOL_FALSE (= 2) = false.
    // getDecryptResultSafe maps BOOL_FALSE → (0, true) so callers see 0 for false.
    // -------------------------------------------------------

    uint256 private constant BOOL_FALSE = 2;

    function _b(bool v) private pure returns (uint256) { return v ? 1 : BOOL_FALSE; }
    function _isTrue(uint256 v) private pure returns (bool) { return v == 1; }

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
        // select: condition 1 = true → b; anything else (BOOL_FALSE or 0) → c
        if (funcId == FunctionId.select)         return _isTrue(a) ? b : c;
        if (funcId == FunctionId.sub)            return a >= b ? a - b : 0;
        if (funcId == FunctionId.add)            return a + b;
        if (funcId == FunctionId.xor)            return a ^ b;
        // Boolean logic — use sentinel so downstream isInitialized() sees non-zero
        if (funcId == FunctionId.and)            return _b(_isTrue(a) && _isTrue(b));
        if (funcId == FunctionId.or)             return _b(_isTrue(a) || _isTrue(b));
        if (funcId == FunctionId.not)            return _b(!_isTrue(a));
        if (funcId == FunctionId.div)            return b > 0 ? a / b : 0;
        if (funcId == FunctionId.rem)            return b > 0 ? a % b : 0;
        if (funcId == FunctionId.mul)            return a * b;
        if (funcId == FunctionId.shl)            return a << b;
        if (funcId == FunctionId.shr)            return a >> b;
        // Comparison ops — return sentinel for false
        if (funcId == FunctionId.gte)            return _b(a >= b);
        if (funcId == FunctionId.lte)            return _b(a <= b);
        if (funcId == FunctionId.lt)             return _b(a <  b);
        if (funcId == FunctionId.gt)             return _b(a >  b);
        if (funcId == FunctionId.min)            return a <  b ? a : b;
        if (funcId == FunctionId.max)            return a >  b ? a : b;
        if (funcId == FunctionId.eq)             return _b(a == b);
        if (funcId == FunctionId.ne)             return _b(a != b);
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
    /// BOOL_FALSE sentinel maps to 0 (the canonical false / zero value).
    function getDecryptResultSafe(uint256 ctHash)
        external pure override returns (uint256, bool)
    {
        if (ctHash == BOOL_FALSE) return (0, true);
        return (ctHash, true);
    }

    function getDecryptResult(uint256 ctHash)
        external pure override returns (uint256)
    {
        if (ctHash == BOOL_FALSE) return 0;
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
