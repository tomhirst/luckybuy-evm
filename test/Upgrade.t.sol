// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LuckyBuyInitializable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../src/common/MEAccessControlUpgradeable.sol";
import "../src/common/interfaces/IPRNG.sol";

// Struct to maintain compatibility with original contract
struct CommitData {
    uint256 id;
    address receiver;
    address cosigner;
    uint256 seed;
    uint256 counter;
    bytes32 orderHash;
    uint256 amount;
    uint256 reward;
}

contract LuckyBuyV2 is UUPSUpgradeable, MEAccessControlUpgradeable {
    // Maintain storage layout compatibility with LuckyBuyInitializable
    IPRNG public PRNG;
    address payable public feeReceiver;
    address public openEditionToken;
    uint256 public openEditionTokenId;
    uint32 public openEditionTokenAmount;

    CommitData[] public luckyBuys;
    mapping(bytes32 commitDigest => uint256 commitId) public commitIdByDigest;

    uint256 public treasuryBalance;
    uint256 public commitBalance;
    uint256 public protocolBalance;
    uint256 public maxReward;
    uint256 public protocolFee;
    uint256 public minReward;
    uint256 public flatFee;

    uint256 public commitExpireTime;
    mapping(uint256 commitId => uint256 expiresAt) public commitExpiresAt;

    uint256 public constant MIN_COMMIT_EXPIRE_TIME = 1 minutes;
    uint256 public constant ONE_PERCENT = 100;
    uint256 public constant BASE_POINTS = 10000;

    mapping(address cosigner => bool active) public isCosigner;
    mapping(address receiver => uint256 counter) public luckyBuyCount;
    mapping(uint256 commitId => bool fulfilled) public isFulfilled;
    mapping(uint256 commitId => bool expired) public isExpired;
    mapping(uint256 commitId => uint256 fee) public feesPaid;

    // New state variable for V2
    uint256 public newVariable;

    // Storage gap for future upgrades
    uint256[50] private __gap;

    // Add a new function to test functionality
    function newFunction() public pure returns (string memory) {
        return "V2";
    }

    // Override an existing function to test function overriding
    function setMaxReward(uint256 maxReward_) external onlyRole(OPS_ROLE) {
        require(maxReward_ > 100 ether, "New max reward must be greater than 100 ETH");
        maxReward = maxReward_;
    }

    // Required for UUPS
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

contract LuckyBuyV2NonUUPS is MEAccessControlUpgradeable {
    // This contract will not be UUPS compatible
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("invalid UUID");
    }
}

contract UpgradeTest is Test {
    LuckyBuyInitializable public implementation;
    LuckyBuyInitializable public proxy;
    LuckyBuyV2 public implementationV2;
    LuckyBuyV2NonUUPS public implementationV2NonUUPS;
    
    address public admin;
    address public user;
    address public feeReceiver;
    address public prng;
    address public feeReceiverManager;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        feeReceiver = makeAddr("feeReceiver");
        prng = makeAddr("prng");
        feeReceiverManager = makeAddr("feeReceiverManager");

        // Deploy implementation
        implementation = new LuckyBuyInitializable();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            LuckyBuyInitializable.initialize.selector,
            admin,
            500, // 5% protocol fee
            0.01 ether, // 0.01 ETH flat fee
            feeReceiver,
            prng,
            feeReceiverManager
        );
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = LuckyBuyInitializable(payable(address(proxyContract)));

        // Deploy V2 implementations
        implementationV2 = new LuckyBuyV2();
        implementationV2NonUUPS = new LuckyBuyV2NonUUPS();
    }

    function test_UpgradeToV2() public {
        vm.startPrank(admin);
        
        // Upgrade to V2
        proxy.upgradeToAndCall(address(implementationV2), "");
        
        // Cast proxy to V2
        LuckyBuyV2 proxyV2 = LuckyBuyV2(payable(address(proxy)));
        
        // Test new functionality
        assertEq(proxyV2.newFunction(), "V2");
        
        // Test state is preserved
        assertEq(proxyV2.feeReceiver(), feeReceiver);
        assertEq(proxyV2.protocolFee(), 500);
        assertEq(proxyV2.flatFee(), 0.01 ether);
        
        vm.stopPrank();
    }

    function test_UpgradeToV2WithCall() public {
        vm.startPrank(admin);
        
        // Upgrade to V2 with initialization
        bytes memory initData = abi.encodeWithSelector(LuckyBuyV2.newFunction.selector);
        proxy.upgradeToAndCall(address(implementationV2), initData);
        
        // Cast proxy to V2
        LuckyBuyV2 proxyV2 = LuckyBuyV2(payable(address(proxy)));
        
        // Test new functionality
        assertEq(proxyV2.newFunction(), "V2");
        
        vm.stopPrank();
    }

    function test_UpgradeToV2WithNewMaxReward() public {
        vm.startPrank(admin);
        
        // Upgrade to V2
        proxy.upgradeToAndCall(address(implementationV2), "");
        
        // Cast proxy to V2
        LuckyBuyV2 proxyV2 = LuckyBuyV2(payable(address(proxy)));
        
        // Test overridden function
        proxyV2.setMaxReward(150 ether);
        assertEq(proxyV2.maxReward(), 150 ether);
        
        // Test that old limit is enforced
        vm.expectRevert("New max reward must be greater than 100 ETH");
        proxyV2.setMaxReward(50 ether);
        
        vm.stopPrank();
    }

    function test_UpgradeToV2NonUUPS() public {
        vm.startPrank(admin);
        
        // Attempt to upgrade to non-UUPS implementation
        vm.expectRevert();
        proxy.upgradeToAndCall(address(implementationV2NonUUPS), "");
        
        vm.stopPrank();
    }

    function test_UpgradeFromNonAdmin() public {
        vm.startPrank(user);
        
        // Attempt to upgrade from non-admin
       vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                user,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        proxy.upgradeToAndCall(address(implementationV2), "");
        
        vm.stopPrank();
    }

    function test_UpgradeToZeroAddress() public {
        vm.startPrank(admin);
        
        // Attempt to upgrade to zero address
        vm.expectRevert(LuckyBuyInitializable.NewImplementationCannotBeZero.selector);
        proxy.upgradeToAndCall(address(0), "");
        
        vm.stopPrank();
    }

    function test_UpgradeToProxy() public {
        vm.startPrank(admin);
        
        // Deploy another proxy
        bytes memory initData = abi.encodeWithSelector(
            LuckyBuyInitializable.initialize.selector,
            admin,
            500,
            0.01 ether,
            feeReceiver,
            prng,
            feeReceiverManager
        );
        ERC1967Proxy proxyContract2 = new ERC1967Proxy(address(implementation), initData);
        
        // Attempt to upgrade to proxy address
        vm.expectRevert();
        proxy.upgradeToAndCall(address(proxyContract2), "");
        
        vm.stopPrank();
    }
}