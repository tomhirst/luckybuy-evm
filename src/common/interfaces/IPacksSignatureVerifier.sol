// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPacksSignatureVerifier {
    struct BucketData {
        uint256 oddsBps;
        uint256 minValue; // In ether
        uint256 maxValue; // In ether
    }

    struct CommitData {
        uint256 id;
        address receiver;
        address cosigner;
        uint256 seed;
        uint256 counter;
        uint256 packPrice; // In ether
        uint256 payoutBps; // We should track this at moment in time from contract state in case we change it
        BucketData[] buckets;
        bytes32 packHash;
    }

    function hash(IPacksSignatureVerifier.CommitData memory commit) external view returns (bytes32);

    function verify(IPacksSignatureVerifier.CommitData memory commit, bytes memory signature)
        external
        view
        returns (address);
}
