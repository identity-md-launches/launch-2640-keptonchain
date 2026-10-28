// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library PledgeSignatures {
    /// @dev Independent EIP-712 oracle: do not ask the implementation for the digest to sign.
    function digest(
        address vault,
        uint256 chain,
        uint256 id,
        uint256 milestone,
        uint8 attempt,
        bool kept,
        uint256 expiry
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KEPT Pledge Vault"),
                keccak256("1"),
                chain,
                vault
            )
        );
        bytes32 verdict = keccak256(
            abi.encode(
                keccak256("Verdict(uint256 pledgeId,uint256 milestone,uint8 attempt,bool kept,uint256 expiry)"),
                id,
                milestone,
                attempt,
                kept,
                expiry
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, verdict));
    }
}
