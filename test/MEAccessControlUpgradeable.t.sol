// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "../src/common/MEAccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Minimal concrete implementation exposing an external initializer so we
///      can exercise `__MEAccessControl_init`.
contract MockMEAccessControlUpgradeable is MEAccessControlUpgradeable {
    function initialize(address initialOwner_) public initializer {
        __MEAccessControl_init(initialOwner_);
    }

    // Helpers used by tests
    function adminOnly() public onlyRole(DEFAULT_ADMIN_ROLE) {}
    function opsOnly() public onlyRole(OPS_ROLE) {}
}

contract MEAccessControlUpgradeableTest is Test {
    // Proxy-addressed instance we interact with
    MEAccessControlUpgradeable public accessControl;

    // Test actors
    address public admin;
    address public user;
    address public ops;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant OPS_ROLE = keccak256("OPS_ROLE");

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        ops  = makeAddr("ops");

        // Deploy implementation
        MockMEAccessControlUpgradeable implementation =
            new MockMEAccessControlUpgradeable();

        // Encode initializer call with initialOwner
        bytes memory initData =
            abi.encodeWithSignature("initialize(address)", admin);

        // Deploy proxy and cast the address for convenience
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        accessControl = MEAccessControlUpgradeable(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALISER
    //////////////////////////////////////////////////////////////*/

    function test_InitializerSetsRoles() public view {
        assertTrue(accessControl.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(accessControl.hasRole(OPS_ROLE, admin));
    }

    function test_RevertOnReinitialise() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MockMEAccessControlUpgradeable(address(accessControl))
            .initialize(admin);
    }

    /*//////////////////////////////////////////////////////////////
                               ROLE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function test_AddAndRemoveOpsUser() public {
        vm.prank(admin);
        accessControl.addOpsUser(ops);
        assertTrue(accessControl.hasRole(OPS_ROLE, ops));

        vm.prank(admin);
        accessControl.removeOpsUser(ops);
        assertFalse(accessControl.hasRole(OPS_ROLE, ops));
    }

    function test_RevertWhen_NonAdminAddsOpsUser() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                DEFAULT_ADMIN_ROLE
            )
        );
        accessControl.addOpsUser(ops);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_TransferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        accessControl.transferAdmin(newAdmin);

        assertTrue(accessControl.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));
        assertTrue(accessControl.hasRole(OPS_ROLE, newAdmin));

        assertFalse(accessControl.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertFalse(accessControl.hasRole(OPS_ROLE, admin));
    }

    function test_RevertWhen_NonAdminTransfersAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                DEFAULT_ADMIN_ROLE
            )
        );
        accessControl.transferAdmin(newAdmin);
    }

    function test_RevertWhen_TransferAdminToZero() public {
        vm.prank(admin);
        vm.expectRevert(MEAccessControlUpgradeable.InvalidOwner.selector);
        accessControl.transferAdmin(address(0));
    }
}
