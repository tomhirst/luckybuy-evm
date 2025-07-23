// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPacksSignatureVerifier {
    struct BucketData {
        uint256 oddsBps;
        uint256 minValue;
        uint256 maxValue;
    }

    enum PackType {
        NFT,
        RWA
    }

    function hashPack(PackType packType, uint256 packPrice, BucketData[] memory buckets) external pure returns (bytes32);

    struct CommitData {
        uint256 id;
        address receiver;
        address cosigner;
        uint256 seed;
        uint256 counter;
        uint256 packPrice;
        uint256 payoutBps;
        BucketData[] buckets;
        bytes32 packHash;
    }

    enum FulfillmentOption {
        Payout,
        NFT
    }

    function hashFulfillment(
        bytes32 digest,
        address marketplace,
        uint256 orderAmount,
        bytes memory orderData,
        address token,
        uint256 tokenId,
        FulfillmentOption choice
    ) external pure returns (bytes32);

    function verifyCommit(CommitData memory commit, bytes memory signature) external view returns (address);

    function verifyHash(bytes32 hash, bytes memory signature) external pure returns (address);
}
