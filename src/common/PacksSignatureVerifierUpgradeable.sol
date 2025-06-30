// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./interfaces/IPacksSignatureVerifier.sol";

contract PacksSignatureVerifierUpgradeable is IPacksSignatureVerifier, EIP712Upgradeable {
    using ECDSA for bytes32;

    function __PacksSignatureVerifier_init(
        string memory name,
        string memory version
    ) internal onlyInitializing {
        __EIP712_init(name, version);
    }

    /// @notice Hashes a pack commit
    /// @param packPrice Pack price in ether
    /// @param buckets Buckets used in the pack
    /// @return Hash of the pack
    function hashPack(
        uint256 packPrice,
        BucketData[] memory buckets
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(packPrice, buckets));
    }

    /// @notice Hashes an order
    /// @param to Receiver of the order
    /// @param value Amount of ether to send
    /// @param data Data to send
    /// @param tokenAddress Token address
    /// @param tokenId Token id
    /// @return Hash of the order
    function hashOrder(
        address to,
        uint256 value,
        bytes memory data,
        address tokenAddress,
        uint256 tokenId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(to, value, data, tokenAddress, tokenId));
    }

    /// @notice Hashes a commit
    /// @param commit Commit to hash
    /// @return Hash of the commit
    function hash(CommitData memory commit) public view returns (bytes32) {
        return _hash(commit);
    }

    /// @dev Internal function to hash a commit
    /// @param commit Commit to hash
    /// @return Hash of the commit
    function _hash(CommitData memory commit) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "CommitData(uint256 id,address receiver,address cosigner,uint256 seed,uint256 counter,uint256 packPrice,BucketData[] buckets)"
                        ),
                        commit.id,
                        commit.receiver,
                        commit.cosigner,
                        commit.seed,
                        commit.counter,
                        commit.packPrice,
                        commit.buckets
                    )
                )
            );
    }

    /// @notice Verifies the signature for a given Commit, returning the address of the signer.
    /// @dev Will revert if the signature is invalid. Does not verify that the signer is authorized to mint NFTs.
    /// @param commit A commit.
    /// @param signature An EIP712 signature of the given commit.
    function verify(
        CommitData memory commit,
        bytes memory signature
    ) public view returns (address) {
        return _verify(commit, signature);
    }

    /// @dev Internal function to verify a commit
    /// @param commit Commit to verify
    /// @param signature Signature to verify
    /// @return Address of the signer
    function _verify(
        CommitData memory commit,
        bytes memory signature
    ) internal view returns (address) {
        bytes32 digest = _hash(commit);
        return _verifyDigest(digest, signature);
    }

    /// @dev Internal function to verify a commit. Expects _hash(commit) elsewhere.
    /// @param signature Signature to verify
    /// @return Address of the signer
    function _verifyDigest(
        bytes32 digest,
        bytes memory signature
    ) internal view returns (address) {
        return ECDSA.recover(digest, signature);
    }

    /// @dev Internal function to verify a pack hash
    /// @param packHash Pack hash to verify
    /// @param signature Signature to verify
    /// @return Address of the signer
    function _verifyPackHash(
        bytes32 packHash,
        bytes memory signature
    ) internal view returns (address) {
        return ECDSA.recover(packHash, signature);
    }

    /// @dev Internal function to verify an order hash
    /// @param orderHash Order hash to verify
    /// @param signature Signature to verify
    /// @return Address of the signer
    function _verifyOrderHash(
        bytes32 orderHash,
        bytes memory signature
    ) internal view returns (address) {
        return ECDSA.recover(orderHash, signature);
    }
}
