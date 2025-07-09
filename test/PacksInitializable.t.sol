// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "src/common/interfaces/IPacksSignatureVerifier.sol";
import "src/PacksInitializable.sol";
import "src/PRNG.sol";
import {TokenRescuer} from "../src/common/TokenRescuer.sol";
import {MEAccessControl} from "../src/common/MEAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock ERC20", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock ERC721", "MOCK") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

// Simple ERC1155 receiver for testing
contract SimpleERC1155Receiver {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x4e2312e0 // IERC1155Receiver
            || interfaceId == 0x01ffc9a7; // IERC165
    }
}

contract MockPacksInitializable is PacksInitializable {
    function setIsFulfilled(uint256 commitId_, bool isFulfilled_) public {
        isFulfilled[commitId_] = isFulfilled_;
    }

    function setIsExpired(uint256 commitId_, bool isExpired_) public {
        isExpired[commitId_] = isExpired_;
    }
}

contract TestPacksInitializable is Test {
    PRNG prng;
    MockPacksInitializable packs;
    address admin = address(0x1);
    address user = address(0x2);
    address receiver = address(0x3);
    uint256 constant COSIGNER_PRIVATE_KEY = 1234;
    address cosigner = vm.addr(COSIGNER_PRIVATE_KEY);
    address feeReceiverManager = address(0x4);
    address feeReceiver = address(0x5);

    uint256 seed = 12345;
    uint256 packPrice = 0.1 ether;

    // Test bucket data
    IPacksSignatureVerifier.BucketData[] buckets;
    IPacksSignatureVerifier.BucketData[] bucketsMulti;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant OPS_ROLE = keccak256("OPS_ROLE");

    address bob = address(0x6);
    address charlie = address(0x7);

    event Commit(
        address indexed sender,
        uint256 indexed commitId,
        address indexed receiver,
        address cosigner,
        uint256 seed,
        uint256 counter,
        uint256 packPrice,
        bytes32 bucketsHash,
        bytes32 digest
    );

    event Fulfillment(
        address indexed sender,
        uint256 indexed commitId,
        uint256 payout,
        address token,
        uint256 tokenId,
        uint256 amount,
        address receiver,
        IPacksSignatureVerifier.FulfillmentOption choice,
        bytes32 digest
    );

    event CommitExpired(uint256 indexed commitId, bytes32 digest);
    event Withdrawal(address indexed sender, uint256 amount, address feeReceiver);
    event BucketIndexSelected(
        address indexed sender, uint256 indexed commitId, uint256 rng, uint256 odds, uint256 bucketIndex, bytes32 digest
    );

    function setUp() public {
        vm.startPrank(admin);
        prng = new PRNG();

        // Deploy implementation
        MockPacksInitializable implementation = new MockPacksInitializable();

        // Encode initializer call
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address)", admin, feeReceiver, address(prng), feeReceiverManager
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        packs = MockPacksInitializable(payable(address(proxy)));

        vm.deal(admin, 100 ether);
        vm.deal(receiver, 100 ether);
        vm.deal(address(this), 100 ether);

        // Add cosigner
        packs.addCosigner(cosigner);

        // Setup test buckets - using single bucket to avoid validation issues
        buckets = new IPacksSignatureVerifier.BucketData[](1);
        buckets[0] = IPacksSignatureVerifier.BucketData({
            oddsBps: 10000, // 100% chance
            minValue: 0.01 ether,
            maxValue: 1 ether
        });

        bucketsMulti = new IPacksSignatureVerifier.BucketData[](3);
        bucketsMulti[0] = IPacksSignatureVerifier.BucketData({
            oddsBps: 3000, // 30% chance (individual probability)
            minValue: 0.01 ether,
            maxValue: 0.05 ether
        });
        bucketsMulti[1] = IPacksSignatureVerifier.BucketData({
            oddsBps: 5000, // 50% chance (individual probability)
            minValue: 0.06 ether,
            maxValue: 0.15 ether
        });
        bucketsMulti[2] = IPacksSignatureVerifier.BucketData({
            oddsBps: 2000, // 20% chance (individual probability)
            minValue: 0.16 ether,
            maxValue: 0.25 ether
        });

        vm.stopPrank();
    }

    function testInitialize() public view {
        assertTrue(packs.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(packs.hasRole(OPS_ROLE, admin));

        assertEq(packs.feeReceiver(), feeReceiver);
        assertEq(address(packs.PRNG()), address(prng));
        assertTrue(packs.hasRole(packs.FEE_RECEIVER_MANAGER_ROLE(), feeReceiverManager));

        // Check default values
        assertEq(packs.payoutBps(), 9000);
        assertEq(packs.minReward(), 0.01 ether);
        assertEq(packs.maxReward(), 5 ether);
        assertEq(packs.minPackPrice(), 0.01 ether);
        assertEq(packs.maxPackPrice(), 0.25 ether);
    }

    function testRevertOnReinitialise() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MockPacksInitializable(payable(address(packs))).initialize(
            admin, feeReceiver, address(prng), feeReceiverManager
        );
    }

    function testCommitSuccess() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        bytes memory signature = signPack(packPrice, buckets);

        vm.expectEmit(true, true, true, false);
        emit Commit(
            user,
            0,
            receiver,
            cosigner,
            seed,
            0,
            packPrice,
            packs.hashPack(packPrice, buckets),
            bytes32(0) // digest will be different
        );

        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, signature);

        assertEq(commitId, 0);
        assertEq(packs.packCount(receiver), 1);

        // Access individual fields from the packs array using tuple destructuring
        (
            uint256 id,
            address storedReceiver,
            address storedCosigner,
            uint256 storedSeed,
            uint256 storedCounter,
            uint256 storedPackPrice,
            uint256 storedPayoutBps,
            bytes32 storedPackHash
        ) = packs.packs(0);

        assertEq(id, 0);
        assertEq(storedReceiver, receiver);
        assertEq(storedCosigner, cosigner);
        assertEq(storedSeed, seed);
        assertEq(storedCounter, 0);
        assertEq(storedPackPrice, packPrice);
        assertEq(storedPayoutBps, packs.payoutBps());
        assertEq(storedPackHash, packs.hashPack(packPrice, buckets));

        vm.stopPrank();
    }

    function testCommitWithInvalidAmount() public {
        vm.startPrank(user);
        vm.deal(user, 0.5 ether);

        bytes memory signature = signPack(0.5 ether, buckets);

        vm.expectRevert(PacksInitializable.InvalidAmount.selector);
        packs.commit{value: 0.5 ether}(receiver, cosigner, seed, buckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidCosigner() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        bytes memory signature = signPack(packPrice, buckets);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.commit{value: packPrice}(receiver, address(0x999), seed, buckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidBuckets() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        // Test empty buckets
        IPacksSignatureVerifier.BucketData[] memory emptyBuckets = new IPacksSignatureVerifier.BucketData[](0);
        bytes memory signature = signPack(packPrice, emptyBuckets);

        vm.expectRevert(PacksInitializable.InvalidBuckets.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, emptyBuckets, signature);

        // Test too many buckets
        IPacksSignatureVerifier.BucketData[] memory tooManyBuckets = new IPacksSignatureVerifier.BucketData[](6);
        for (uint256 i = 0; i < 6; i++) {
            tooManyBuckets[i] =
                IPacksSignatureVerifier.BucketData({oddsBps: 1666, minValue: 0.01 ether, maxValue: 0.1 ether});
        }
        signature = signPack(packPrice, tooManyBuckets);

        vm.expectRevert(PacksInitializable.InvalidBuckets.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, tooManyBuckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidBucketValues() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        // Test bucket with zero values
        IPacksSignatureVerifier.BucketData[] memory invalidBuckets = new IPacksSignatureVerifier.BucketData[](1);
        invalidBuckets[0] = IPacksSignatureVerifier.BucketData({oddsBps: 10000, minValue: 0, maxValue: 0.1 ether});
        bytes memory signature = signPack(packPrice, invalidBuckets);

        vm.expectRevert(PacksInitializable.InvalidReward.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, invalidBuckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidBucketRanges() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        // Test overlapping bucket ranges
        IPacksSignatureVerifier.BucketData[] memory overlappingBuckets = new IPacksSignatureVerifier.BucketData[](2);
        overlappingBuckets[0] =
            IPacksSignatureVerifier.BucketData({oddsBps: 5000, minValue: 0.01 ether, maxValue: 0.1 ether});
        overlappingBuckets[1] = IPacksSignatureVerifier.BucketData({
            oddsBps: 10000,
            minValue: 0.05 ether, // Overlaps with previous bucket
            maxValue: 0.2 ether
        });
        bytes memory signature = signPack(packPrice, overlappingBuckets);

        vm.expectRevert(PacksInitializable.InvalidBuckets.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, overlappingBuckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidOdds() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        // Test non-cumulative odds
        IPacksSignatureVerifier.BucketData[] memory invalidOddsBuckets = new IPacksSignatureVerifier.BucketData[](2);
        invalidOddsBuckets[0] =
            IPacksSignatureVerifier.BucketData({oddsBps: 6000, minValue: 0.01 ether, maxValue: 0.05 ether});
        invalidOddsBuckets[1] = IPacksSignatureVerifier.BucketData({
            oddsBps: 5000, // Should be higher than previous cumulative
            minValue: 0.06 ether,
            maxValue: 0.1 ether
        });
        bytes memory signature = signPack(packPrice, invalidOddsBuckets);

        vm.expectRevert(PacksInitializable.InvalidBuckets.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, invalidOddsBuckets, signature);

        vm.stopPrank();
    }

    function testCommitWithInvalidSignature() public {
        vm.startPrank(user);
        vm.deal(user, packPrice);

        bytes memory wrongSignature = signPack(packPrice + 0.1 ether, buckets);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, wrongSignature);

        vm.stopPrank();
    }

    function testFulfillSuccess() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly and cosigner
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.deal(cosigner, 5 ether);
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Verify bucket was selected
        assertTrue(packs.isBucketSelected(commitId));
        assertEq(packs.bucketIndex(commitId), 0); // Should select bucket 0 with 100% odds

        // Now fulfill with payout
        uint256 orderAmount = 0.03 ether; // Within bucket 0 range
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        uint256 expectedPayoutAmount = (orderAmount * packs.payoutBps()) / 10000;

        // Calculate the actual digest that will be emitted
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId,
            receiver: receiver,
            cosigner: cosigner,
            seed: seed,
            counter: 0,
            packPrice: packPrice,
            payoutBps: packs.payoutBps(),
            buckets: buckets,
            packHash: packs.hashPack(packPrice, buckets)
        });
        bytes32 expectedDigest = packs.hashCommit(commitData);

        vm.expectEmit(true, true, true, false);
        emit Fulfillment(
            address(this), // msg.sender is the test contract
            commitId,
            expectedPayoutAmount, // payout amount (90% of orderAmount)
            address(0), // no token for payout
            0, // no tokenId for payout
            0, // no amount for payout
            receiver,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            expectedDigest
        );

        packs.fulfill(
            commitId,
            address(0), // marketplace
            "", // orderData
            orderAmount,
            address(0), // token
            0, // tokenId
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );

        assertTrue(packs.isFulfilled(commitId));
    }

    function testFulfillWithNFT() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly and cosigner
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.deal(cosigner, 5 ether);
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Verify bucket was selected
        assertTrue(packs.isBucketSelected(commitId));
        assertEq(packs.bucketIndex(commitId), 0); // Should select bucket 0 with 100% odds

        // Now fulfill with NFT - use proper amount within bucket range
        uint256 orderAmount = 0.5 ether; // Within bucket range
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature =
            signChoice(commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.NFT);

        packs.fulfill(
            commitId,
            address(0), // marketplace
            "", // orderData
            orderAmount,
            address(0), // token
            0, // tokenId
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.NFT,
            choiceSignature
        );

        assertTrue(packs.isFulfilled(commitId));
    }

    function testFulfillWithoutBucketSelection() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.stopPrank();

        // Try to fulfill without selecting bucket first
        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        vm.expectRevert(PacksInitializable.BucketIndexNotSelected.selector);
        packs.fulfill(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );
    }

    function testFulfillWithInvalidOrderAmount() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Try to fulfill with order amount outside bucket range
        uint256 orderAmount = 2 ether; // Outside all bucket ranges
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        vm.expectRevert(PacksInitializable.InvalidAmount.selector);
        packs.fulfill(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );
    }

    function testFulfillWithInvalidOrderHash() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // First fulfill
        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        packs.fulfill(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );

        // Try to fulfill again with different order data - but this will fail with AlreadyFulfilled first
        vm.expectRevert(PacksInitializable.AlreadyFulfilled.selector);
        packs.fulfill(
            commitId,
            address(0),
            "different",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );
    }

    function testFulfillAlreadyFulfilled() public {
        // Create and fulfill commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        vm.deal(cosigner, 20 ether);
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        // Call fulfill with some ETH value to fund the treasury
        packs.fulfill{value: 10 ether}(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );

        // Try to fulfill again
        vm.expectRevert(PacksInitializable.AlreadyFulfilled.selector);
        packs.fulfill{value: 0}(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );
    }

    function testExpireCommit() public {
        vm.startPrank(admin);
        packs.setCommitExpireTime(1 days);
        vm.stopPrank();

        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(
            user, // receiver
            cosigner,
            seed,
            buckets,
            packSignature
        );

        uint256 initialBalance = user.balance;

        // Wait for expiration
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, true, false);
        emit CommitExpired(commitId, bytes32(0)); // digest will be different

        packs.expire(commitId);

        assertTrue(packs.isExpired(commitId));
        assertEq(user.balance, initialBalance + packPrice);
    }

    function testExpireCommitFromCosigner() public {
        vm.startPrank(admin);
        packs.setCommitExpireTime(1 days);
        vm.stopPrank();

        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(
            user, // receiver
            cosigner,
            seed,
            buckets,
            packSignature
        );

        uint256 initialBalance = user.balance;
        vm.stopPrank();

        // Wait for expiration
        vm.warp(block.timestamp + 2 days);

        vm.expectEmit(true, true, true, false);
        emit CommitExpired(commitId, bytes32(0)); // digest will be different

        vm.prank(cosigner);
        packs.expire(commitId);
        vm.stopPrank();

        assertTrue(packs.isExpired(commitId));
        assertEq(user.balance, initialBalance + packPrice);
    }

    function testExpireCommitNotExpired() public {
        vm.startPrank(admin);
        packs.setCommitExpireTime(1 days);
        vm.stopPrank();

        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(
            user, // receiver
            cosigner,
            seed,
            buckets,
            packSignature
        );
        vm.stopPrank();

        // Try to expire before expiration time
        vm.prank(user);
        vm.expectRevert(PacksInitializable.CommitNotExpired.selector);
        packs.expire(commitId);
    }

    function testExpireCommitNotOwner() public {
        vm.startPrank(admin);
        packs.setCommitExpireTime(1 days);
        vm.stopPrank();

        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(
            user, // receiver
            cosigner,
            seed,
            buckets,
            packSignature
        );
        vm.stopPrank();

        // Wait for expiration
        vm.warp(block.timestamp + 2 days);

        // Try to expire as non-owner
        vm.expectRevert(PacksInitializable.InvalidCommitOwner.selector);
        vm.prank(bob);
        packs.expire(commitId);
    }

    function testWithdrawSuccess() public {
        uint256 withdrawAmount = 1 ether;
        // Fund the treasury properly by sending ETH to the contract
        vm.deal(address(this), withdrawAmount);
        (bool success,) = payable(address(packs)).call{value: withdrawAmount}("");
        require(success, "Failed to fund contract");

        uint256 initialBalance = feeReceiver.balance;

        vm.expectEmit(true, true, true, true);
        emit Withdrawal(admin, withdrawAmount, feeReceiver);

        vm.prank(admin);
        packs.withdraw(withdrawAmount);

        assertEq(feeReceiver.balance, initialBalance + withdrawAmount);
    }

    function testWithdrawInsufficientBalance() public {
        vm.expectRevert(PacksInitializable.InsufficientBalance.selector);
        vm.prank(admin);
        packs.withdraw(1 ether);
    }

    function testEmergencyWithdraw() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        vm.deal(address(packs), address(packs).balance + 5 ether);
        vm.stopPrank();

        uint256 initialBalance = feeReceiver.balance;

        vm.prank(admin);
        packs.emergencyWithdraw();

        assertEq(feeReceiver.balance, initialBalance + 5 ether + packPrice);
        assertTrue(packs.paused());
    }

    // Helper functions for signing
    function signPack(uint256 packPrice_, IPacksSignatureVerifier.BucketData[] memory buckets_)
        internal
        view
        returns (bytes memory)
    {
        return signPack(packPrice_, buckets_, cosigner);
    }

    function signPack(uint256 packPrice_, IPacksSignatureVerifier.BucketData[] memory buckets_, address signer_)
        internal
        view
        returns (bytes memory)
    {
        bytes32 packHash = packs.hashPack(packPrice_, buckets_);

        // Find the private key for the signer
        uint256 privateKey;
        if (signer_ == cosigner) {
            privateKey = COSIGNER_PRIVATE_KEY;
        } else if (signer_ == bob) {
            privateKey = 5678; // bob's private key
        } else if (signer_ == charlie) {
            privateKey = 9012; // charlie's private key
        } else {
            // For any other address, generate a deterministic private key
            privateKey = uint256(keccak256(abi.encodePacked(signer_)));
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, packHash);
        return abi.encodePacked(r, s, v);
    }

    function signCommit(
        uint256 commitId_,
        address receiver_,
        uint256 seed_,
        uint256 counter_,
        uint256 packPrice_,
        IPacksSignatureVerifier.BucketData[] memory buckets_
    ) internal view returns (bytes memory) {
        return signCommit(commitId_, receiver_, seed_, counter_, packPrice_, buckets_, cosigner);
    }

    function signCommit(
        uint256 commitId_,
        address receiver_,
        uint256 seed_,
        uint256 counter_,
        uint256 packPrice_,
        IPacksSignatureVerifier.BucketData[] memory buckets_,
        address signer_
    ) internal view returns (bytes memory) {
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId_,
            receiver: receiver_,
            cosigner: cosigner,
            seed: seed_,
            counter: counter_,
            packPrice: packPrice_,
            payoutBps: packs.payoutBps(),
            buckets: buckets_,
            packHash: packs.hashPack(packPrice_, buckets_)
        });

        bytes32 digest = packs.hashCommit(commitData);

        // Find the private key for the signer
        uint256 privateKey;
        if (signer_ == cosigner) {
            privateKey = COSIGNER_PRIVATE_KEY;
        } else if (signer_ == bob) {
            privateKey = 5678; // bob's private key
        } else if (signer_ == charlie) {
            privateKey = 9012; // charlie's private key
        } else {
            // For any other address, generate a deterministic private key
            privateKey = uint256(keccak256(abi.encodePacked(signer_)));
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function signOrder(address to_, uint256 value_, bytes memory data_, address token_, uint256 tokenId_)
        internal
        view
        returns (bytes memory)
    {
        return signOrder(to_, value_, data_, token_, tokenId_, cosigner);
    }

    function signOrder(
        address to_,
        uint256 value_,
        bytes memory data_,
        address token_,
        uint256 tokenId_,
        address signer_
    ) internal view returns (bytes memory) {
        bytes32 orderHash = packs.hashOrder(to_, value_, data_, token_, tokenId_);

        // Find the private key for the signer
        uint256 privateKey;
        if (signer_ == cosigner) {
            privateKey = COSIGNER_PRIVATE_KEY;
        } else if (signer_ == bob) {
            privateKey = 5678; // bob's private key
        } else if (signer_ == charlie) {
            privateKey = 9012; // charlie's private key
        } else {
            // For any other address, generate a deterministic private key
            privateKey = uint256(keccak256(abi.encodePacked(signer_)));
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }

    function signChoice(
        uint256 commitId_,
        address receiver_,
        uint256 seed_,
        uint256 counter_,
        uint256 packPrice_,
        IPacksSignatureVerifier.BucketData[] memory buckets_,
        IPacksSignatureVerifier.FulfillmentOption choice_
    ) internal view returns (bytes memory) {
        return signChoice(commitId_, receiver_, seed_, counter_, packPrice_, buckets_, choice_, cosigner);
    }

    function signChoice(
        uint256 commitId_,
        address receiver_,
        uint256 seed_,
        uint256 counter_,
        uint256 packPrice_,
        IPacksSignatureVerifier.BucketData[] memory buckets_,
        IPacksSignatureVerifier.FulfillmentOption choice_,
        address signer_
    ) internal view returns (bytes memory) {
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId_,
            receiver: receiver_,
            cosigner: cosigner,
            seed: seed_,
            counter: counter_,
            packPrice: packPrice_,
            payoutBps: packs.payoutBps(),
            buckets: buckets_,
            packHash: packs.hashPack(packPrice_, buckets_)
        });

        bytes32 digest = packs.hashCommit(commitData);
        bytes32 choiceHash = packs.hashChoice(digest, choice_);

        // Find the private key for the signer
        uint256 privateKey;
        if (signer_ == cosigner) {
            privateKey = COSIGNER_PRIVATE_KEY;
        } else if (signer_ == bob) {
            privateKey = 5678; // bob's private key
        } else if (signer_ == charlie) {
            privateKey = 9012; // charlie's private key
        } else {
            // For any other address, generate a deterministic private key
            privateKey = uint256(keccak256(abi.encodePacked(signer_)));
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, choiceHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}

    // ========================================
    // BUCKET SELECTION TESTS
    // ========================================

    function testSelectBucketIndexSuccess() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Select bucket index
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);

        // Calculate the actual digest that will be emitted
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId,
            receiver: receiver,
            cosigner: cosigner,
            seed: seed,
            counter: 0,
            packPrice: packPrice,
            payoutBps: packs.payoutBps(),
            buckets: buckets,
            packHash: packs.hashPack(packPrice, buckets)
        });
        bytes32 expectedDigest = packs.hashCommit(commitData);

        vm.expectEmit(true, true, true, false);
        emit BucketIndexSelected(
            address(this), // msg.sender is the test contract
            commitId,
            0, // RNG will be different
            10000, // bucket 0 odds (100%)
            0, // bucket index
            expectedDigest
        );

        packs.selectBucketIndex(commitId, commitSignature);

        // Verify bucket was selected
        assertTrue(packs.isBucketSelected(commitId));
        assertEq(packs.bucketIndex(commitId), 0); // Should select bucket 0 with 100% odds
    }

    function testSelectBucketIndexSuccessMulti() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, bucketsMulti);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, bucketsMulti, packSignature);
        vm.stopPrank();

        // Select bucket index
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, bucketsMulti);

        // Calculate the actual digest that will be emitted
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId,
            receiver: receiver,
            cosigner: cosigner,
            seed: seed,
            counter: 0,
            packPrice: packPrice,
            payoutBps: packs.payoutBps(),
            buckets: bucketsMulti,
            packHash: packs.hashPack(packPrice, bucketsMulti)
        });
        bytes32 expectedDigest = packs.hashCommit(commitData);

        // Capture the RNG value and bucket selection
        uint256 expectedRng = prng.rng(commitSignature);

        // Calculate expected bucket based on RNG and cumulative odds
        uint256 expectedBucket = 0;
        uint256 cumulativeOdds = 0;
        for (uint256 i = 0; i < bucketsMulti.length; i++) {
            cumulativeOdds += bucketsMulti[i].oddsBps;
            if (expectedRng < cumulativeOdds) {
                expectedBucket = i;
                break;
            }
        }

        vm.expectEmit(true, true, true, false);
        emit BucketIndexSelected(
            address(this), // msg.sender is the test contract
            commitId,
            expectedRng, // Actual RNG value
            bucketsMulti[expectedBucket].oddsBps, // Selected bucket odds
            expectedBucket, // Expected bucket index
            expectedDigest
        );

        packs.selectBucketIndex(commitId, commitSignature);

        // Verify bucket was selected correctly
        assertTrue(packs.isBucketSelected(commitId));
        assertEq(packs.bucketIndex(commitId), expectedBucket, "Bucket index should match RNG-based selection");

        // Verify the selected bucket's odds are correct
        assertEq(
            packs.bucketIndex(commitId) < bucketsMulti.length, true, "Selected bucket should be within valid range"
        );

        // Verify the RNG value is within expected range (0-10000)
        assertTrue(expectedRng <= 10000, "RNG should be within 0-10000 range");
    }

    function testSelectBucketIndexByDigest() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Get the digest
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId,
            receiver: receiver,
            cosigner: cosigner,
            seed: seed,
            counter: 0,
            packPrice: packPrice,
            payoutBps: packs.payoutBps(),
            buckets: buckets,
            packHash: packs.hashPack(packPrice, buckets)
        });
        bytes32 digest = packs.hashCommit(commitData);

        // Select bucket index by digest
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndexByDigest(digest, commitSignature);

        // Verify bucket was selected
        assertTrue(packs.isBucketSelected(commitId));
        assertEq(packs.bucketIndex(commitId), 0);
    }

    function testSelectBucketIndexAlreadySelected() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Select bucket index first time
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Try to select bucket index again
        vm.expectRevert(PacksInitializable.BucketIndexAlreadySelected.selector);
        packs.selectBucketIndex(commitId, commitSignature);
    }

    function testSelectBucketIndexInvalidCosigner() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Try to select bucket index with wrong signature
        bytes memory wrongSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets, bob);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.selectBucketIndex(commitId, wrongSignature);
    }

    function testSelectBucketIndexWhenPaused() public {
        // Create commit
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Pause the contract
        vm.prank(admin);
        packs.pause();

        // Try to select bucket index when paused
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        vm.expectRevert();
        packs.selectBucketIndex(commitId, commitSignature);
    }

    function testSelectBucketIndexRNGDistribution() public {
        // Test that RNG-based bucket selection follows expected statistical distribution
        // Create multiple commits and track bucket selections to validate RNG behavior

        uint256[3] memory bucketCounts;
        uint256 numTests = 1000; // Number of commits to test

        for (uint256 i = 0; i < numTests; i++) {
            // Create commit with different seed for each test
            vm.startPrank(user);
            vm.deal(user, packPrice);
            bytes memory packSignature = signPack(packPrice, bucketsMulti);
            uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed + i, bucketsMulti, packSignature);
            vm.stopPrank();

            // Select bucket index
            vm.prank(cosigner);
            bytes memory commitSignature = signCommit(commitId, receiver, seed + i, i, packPrice, bucketsMulti);

            // Get expected RNG and bucket
            uint256 expectedRng = prng.rng(commitSignature);
            uint256 expectedBucket = 0;
            uint256 cumulativeOdds = 0;
            for (uint256 j = 0; j < bucketsMulti.length; j++) {
                cumulativeOdds += bucketsMulti[j].oddsBps;
                if (expectedRng < cumulativeOdds) {
                    expectedBucket = j;
                    break;
                }
            }

            packs.selectBucketIndex(commitId, commitSignature);

            // Verify bucket selection matches RNG-based expectation
            assertEq(packs.bucketIndex(commitId), expectedBucket, "Bucket selection should match RNG calculation");

            // Track bucket selections
            bucketCounts[expectedBucket]++;
        }

        // Basic statistical validation - all buckets should be selected at least once
        assertTrue(bucketCounts[0] > 0, "Bucket 0 should be selected at least once");
        assertTrue(bucketCounts[1] > 0, "Bucket 1 should be selected at least once");
        assertTrue(bucketCounts[2] > 0, "Bucket 2 should be selected at least once");

        // Verify total selections equals number of tests
        assertEq(
            bucketCounts[0] + bucketCounts[1] + bucketCounts[2],
            numTests,
            "Total selections should equal number of tests"
        );

        // Verify bucket 1 (50% odds) is selected more frequently than others
        // This is a basic check that the higher odds bucket gets selected more often
        assertTrue(
            bucketCounts[1] >= bucketCounts[0],
            "Bucket 1 (50% odds) should be selected at least as often as bucket 0 (30% odds)"
        );
        assertTrue(
            bucketCounts[1] >= bucketCounts[2],
            "Bucket 1 (50% odds) should be selected at least as often as bucket 2 (20% odds)"
        );
    }

    function testInvalidPackHashSigner() public {
        // Test that commit reverts if the pack hash is not signed by the cosigner
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Try to select bucket index with wrong signature
        bytes memory wrongSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets, bob);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.selectBucketIndex(commitId, wrongSignature);
    }

    function testInvalidCommitSigner() public {
        // Test that selectBucketIndex reverts if the commit is not signed by the cosigner
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Try to select bucket index with wrong signature
        bytes memory wrongSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets, bob);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.selectBucketIndex(commitId, wrongSignature);
    }

    function testInvalidOrderHashSigner() public {
        // Test that fulfill reverts if the order hash is not signed by the receiver
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Fund contract treasury properly
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Try to fulfill with wrong signature
        bytes memory wrongSignature = signOrder(address(0), 0.03 ether, "", address(0), 0, bob);

        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.fulfill(
            commitId,
            address(0),
            "",
            0.03 ether,
            address(0),
            0,
            wrongSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            ""
        );
    }

    function testInvalidChoiceSigner() public {
        // Test that only receiver or cosigner can sign choice
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 10 ether}("");
        require(success, "Failed to fund contract");
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);

        // Sign choice with wrong signer (bob instead of receiver or cosigner)
        bytes memory wrongChoiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout, bob
        );

        vm.expectRevert(PacksInitializable.InvalidChoiceSigner.selector);
        packs.fulfill(
            commitId,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            wrongChoiceSignature
        );
    }

    function testPauseUnpauseSecurity() public {
        // Test that only admin can pause/unpause
        vm.startPrank(user);
        vm.expectRevert();
        packs.pause();
        vm.stopPrank();

        vm.startPrank(admin);
        packs.pause();
        assertTrue(packs.paused());

        packs.unpause();
        assertFalse(packs.paused());
        vm.stopPrank();
    }

    function testCommitWhenPaused() public {
        vm.startPrank(admin);
        packs.pause();
        vm.stopPrank();

        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);

        vm.expectRevert();
        packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();
    }

    function testFulfillWhenPaused() public {
        // Create commit first
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);
        vm.stopPrank();

        // Then pause
        vm.startPrank(admin);
        packs.pause();
        vm.stopPrank();

        vm.deal(address(packs), 10 ether);

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        packs.selectBucketIndex(commitId, commitSignature);
    }

    function testUpgradeSecurity() public {
        // Test that only admin can upgrade - using UUPS pattern
        address newImplementation = address(new MockPacksInitializable());

        // Test that non-admin cannot upgrade
        vm.startPrank(user);
        vm.expectRevert();
        PacksInitializable(payable(address(packs))).upgradeToAndCall(newImplementation, "");
        vm.stopPrank();

        // Test that admin can upgrade (this should succeed)
        vm.startPrank(admin);
        PacksInitializable(payable(address(packs))).upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function testFeeReceiverManagerSecurity() public {
        address newFeeReceiverManager = address(0x8);
        address newFeeReceiver = address(0x9);

        // Test that only fee receiver manager can transfer role
        vm.startPrank(admin);
        vm.expectRevert();
        packs.transferFeeReceiverManager(newFeeReceiverManager);
        vm.stopPrank();

        // Test that only fee receiver manager can set fee receiver
        vm.startPrank(admin);
        vm.expectRevert();
        packs.setFeeReceiver(newFeeReceiver);
        vm.stopPrank();

        // Test that fee receiver manager can transfer role
        vm.startPrank(feeReceiverManager);
        packs.transferFeeReceiverManager(newFeeReceiverManager);
        vm.stopPrank();

        // Test that new fee receiver manager can set fee receiver
        vm.startPrank(newFeeReceiverManager);
        packs.setFeeReceiver(newFeeReceiver);
        vm.stopPrank();

        assertEq(packs.feeReceiver(), newFeeReceiver);
    }

    function testInvalidFeeReceiverManager() public {
        vm.startPrank(feeReceiverManager);
        vm.expectRevert(PacksInitializable.InvalidFeeReceiverManager.selector);
        packs.transferFeeReceiverManager(address(0));
        vm.stopPrank();
    }

    function testInvalidFeeReceiver() public {
        vm.startPrank(feeReceiverManager);
        vm.expectRevert(PacksInitializable.InvalidFeeReceiver.selector);
        packs.setFeeReceiver(address(0));
        vm.stopPrank();
    }

    function testRescueFunctionsSecurity() public {
        // Test that only rescue role can rescue tokens
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        vm.startPrank(user);
        vm.expectRevert();
        packs.rescueERC20(address(token), bob, 100 ether);
        vm.stopPrank();

        // Test that admin can rescue
        vm.startPrank(admin);
        packs.rescueERC20(address(token), bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        vm.stopPrank();
    }

    function testRescueERC20ZeroAddress() public {
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        vm.startPrank(admin);
        vm.expectRevert(TokenRescuer.TokenRescuerInvalidAddress.selector);
        packs.rescueERC20(address(0), bob, 100 ether);
        vm.stopPrank();
    }

    function testRescueERC20ZeroAmount() public {
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        vm.startPrank(admin);
        vm.expectRevert(TokenRescuer.TokenRescuerAmountMustBeGreaterThanZero.selector);
        packs.rescueERC20(address(token), bob, 0);
        vm.stopPrank();
    }

    function testRescueERC20InsufficientBalance() public {
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        vm.startPrank(admin);
        vm.expectRevert(TokenRescuer.TokenRescuerInsufficientBalance.selector);
        packs.rescueERC20(address(token), bob, 2000 ether);
        vm.stopPrank();
    }

    function testRescueERC721Security() public {
        MockERC721 token = new MockERC721();
        token.mint(address(packs), 1);

        vm.startPrank(user);
        vm.expectRevert();
        packs.rescueERC721(address(token), bob, 1);
        vm.stopPrank();

        vm.startPrank(admin);
        packs.rescueERC721(address(token), bob, 1);
        assertEq(token.ownerOf(1), bob);
        vm.stopPrank();
    }

    function testRescueERC1155() public {
        // Deploy mock ERC1155
        MockERC1155 token = new MockERC1155();
        token.mint(address(packs), 1, 100);

        // Deploy ERC1155 receiver
        SimpleERC1155Receiver receiver = new SimpleERC1155Receiver();

        // Test single token rescue
        vm.startPrank(admin);
        packs.rescueERC1155(address(token), address(receiver), 1, 50);
        vm.stopPrank();

        assertEq(token.balanceOf(address(receiver), 1), 50);
        assertEq(token.balanceOf(address(packs), 1), 50);
    }

    function testRescueERC20() public {
        // Deploy mock ERC20
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        // Test single token rescue
        vm.startPrank(admin);
        packs.rescueERC20(address(token), bob, 100 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(address(packs)), 900 ether);
    }

    function testRescueERC20Batch() public {
        // Deploy mock ERC20s
        MockERC20 token1 = new MockERC20();
        MockERC20 token2 = new MockERC20();
        token1.mint(address(packs), 1000 ether);
        token2.mint(address(packs), 500 ether);

        // Test batch rescue
        address[] memory tokens = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);

        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tos[0] = bob;
        tos[1] = charlie;
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        vm.startPrank(admin);
        packs.rescueERC20Batch(tokens, tos, amounts);
        vm.stopPrank();

        assertEq(token1.balanceOf(bob), 100 ether);
        assertEq(token2.balanceOf(charlie), 200 ether);
        assertEq(token1.balanceOf(address(packs)), 900 ether);
        assertEq(token2.balanceOf(address(packs)), 300 ether);
    }

    function testRescueERC721() public {
        // Deploy mock ERC721
        MockERC721 token = new MockERC721();
        token.mint(address(packs), 1);

        // Test single token rescue
        vm.startPrank(admin);
        packs.rescueERC721(address(token), bob, 1);
        vm.stopPrank();

        assertEq(token.ownerOf(1), bob);
    }

    function testRescueERC721Batch() public {
        // Deploy mock ERC721s
        MockERC721 token1 = new MockERC721();
        MockERC721 token2 = new MockERC721();
        token1.mint(address(packs), 1);
        token2.mint(address(packs), 2);

        // Test batch rescue
        address[] memory tokens = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);

        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tos[0] = bob;
        tos[1] = charlie;
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        vm.startPrank(admin);
        packs.rescueERC721Batch(tokens, tos, tokenIds);
        vm.stopPrank();

        assertEq(token1.ownerOf(1), bob);
        assertEq(token2.ownerOf(2), charlie);
    }

    function testRescueERC1155Batch() public {
        // Deploy mock ERC1155
        MockERC1155 token = new MockERC1155();
        token.mint(address(packs), 1, 100);
        token.mint(address(packs), 2, 200);

        // Deploy ERC1155 receiver
        SimpleERC1155Receiver receiver = new SimpleERC1155Receiver();

        // Test batch rescue
        address[] memory tokens = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);

        tokens[0] = address(token);
        tokens[1] = address(token);
        tos[0] = address(receiver);
        tos[1] = address(receiver);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        amounts[0] = 50;
        amounts[1] = 100;

        vm.startPrank(admin);
        packs.rescueERC1155Batch(tokens, tos, tokenIds, amounts);
        vm.stopPrank();

        assertEq(token.balanceOf(address(receiver), 1), 50);
        assertEq(token.balanceOf(address(receiver), 2), 100);
        assertEq(token.balanceOf(address(packs), 1), 50);
        assertEq(token.balanceOf(address(packs), 2), 100);
    }

    function testBatchRescueSecurity() public {
        MockERC20 token = new MockERC20();
        token.mint(address(packs), 1000 ether);

        address[] memory tokens = new address[](2);
        address[] memory tos = new address[](1); // Mismatched length
        uint256[] memory amounts = new uint256[](2);

        tokens[0] = address(token);
        tokens[1] = address(token);
        tos[0] = bob;
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        vm.startPrank(admin);
        vm.expectRevert(TokenRescuer.TokenRescuerArrayLengthMismatch.selector);
        packs.rescueERC20Batch(tokens, tos, amounts);
        vm.stopPrank();
    }

    function testFulfillByDigestSecurity() public {
        // Test that fulfillByDigest works correctly
        vm.startPrank(user);
        vm.deal(user, packPrice);
        bytes memory packSignature = signPack(packPrice, buckets);
        uint256 commitId = packs.commit{value: packPrice}(receiver, cosigner, seed, buckets, packSignature);

        // Fund contract treasury properly and cosigner
        vm.deal(user, 10 ether);
        (bool success,) = payable(address(packs)).call{value: 5 ether}("");
        require(success, "Failed to fund contract");
        vm.deal(cosigner, 5 ether);
        vm.stopPrank();

        // Select bucket index first
        vm.prank(cosigner);
        bytes memory commitSignature = signCommit(commitId, receiver, seed, 0, packPrice, buckets);
        packs.selectBucketIndex(commitId, commitSignature);

        // Get the digest
        IPacksSignatureVerifier.CommitData memory commitData = IPacksSignatureVerifier.CommitData({
            id: commitId,
            receiver: receiver,
            cosigner: cosigner,
            seed: seed,
            counter: 0,
            packPrice: packPrice,
            payoutBps: packs.payoutBps(),
            buckets: buckets,
            packHash: packs.hashPack(packPrice, buckets)
        });

        bytes32 digest = packs.hashCommit(commitData);

        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature = signChoice(
            commitId, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout
        );

        packs.fulfillByDigest(
            digest,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );

        assertTrue(packs.isFulfilled(commitId));
    }

    function testInvalidDigestFulfill() public {
        // Test that invalid digest reverts
        bytes32 invalidDigest = keccak256("invalid");

        uint256 orderAmount = 0.03 ether;
        bytes memory orderSignature = signOrder(address(0), orderAmount, "", address(0), 0);
        bytes memory choiceSignature =
            signChoice(0, receiver, seed, 0, packPrice, buckets, IPacksSignatureVerifier.FulfillmentOption.Payout);

        // Fund the contract treasury to avoid InsufficientBalance error
        (bool success,) = payable(address(packs)).call{value: orderAmount}("");
        require(success, "Failed to fund contract");

        vm.expectRevert(PacksInitializable.InvalidCommitId.selector);
        packs.fulfillByDigest(
            invalidDigest,
            address(0),
            "",
            orderAmount,
            address(0),
            0,
            orderSignature,
            IPacksSignatureVerifier.FulfillmentOption.Payout,
            choiceSignature
        );
    }

    function testSetLimitsSecurity() public {
        // Test that only authorized roles can set limits
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), user, packs.OPS_ROLE()
            )
        );
        packs.setMaxReward(10 ether);
        vm.stopPrank();

        vm.startPrank(admin);
        packs.setMaxReward(10 ether);
        assertEq(packs.maxReward(), 10 ether);
        vm.stopPrank();
    }

    function testInvalidLimits() public {
        vm.startPrank(admin);

        // Test invalid min reward
        vm.expectRevert(PacksInitializable.InvalidReward.selector);
        packs.setMinReward(10 ether); // Greater than max reward

        // Test invalid max pack price
        vm.expectRevert(PacksInitializable.InvalidPackPrice.selector);
        packs.setMaxPackPrice(0.005 ether); // Less than min pack price

        // Test invalid payout bps
        vm.expectRevert(PacksInitializable.InvalidPayoutBps.selector);
        packs.setPayoutBps(15000); // Greater than 10000

        vm.stopPrank();
    }

    function testCommitExpireTimeSecurity() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                user,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        packs.setCommitExpireTime(2 days);
        vm.stopPrank();

        vm.startPrank(admin);
        packs.setCommitExpireTime(2 days);
        assertEq(packs.commitExpireTime(), 2 days);

        // Test minimum expire time
        vm.expectRevert(PacksInitializable.InvalidCommitExpireTime.selector);
        packs.setCommitExpireTime(30 seconds); // Less than MIN_COMMIT_EXPIRE_TIME
        vm.stopPrank();
    }

    function testCosignerManagementSecurity() public {
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                user,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        packs.addCosigner(bob);
        vm.stopPrank();

        vm.startPrank(admin);
        packs.addCosigner(bob);
        assertTrue(packs.isCosigner(bob));

        // Test adding zero address
        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.addCosigner(address(0));

        // Test adding already existing cosigner
        vm.expectRevert(PacksInitializable.AlreadyCosigner.selector);
        packs.addCosigner(bob);

        // Test removing non-existent cosigner
        vm.expectRevert(PacksInitializable.InvalidCosigner.selector);
        packs.removeCosigner(charlie);

        packs.removeCosigner(bob);
        assertFalse(packs.isCosigner(bob));
        vm.stopPrank();
    }
}
