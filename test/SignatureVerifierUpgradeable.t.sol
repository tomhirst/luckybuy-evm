// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "src/common/SignatureVerifierUpgradeable.sol";
import "src/common/interfaces/ISignatureVerifier.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Minimal concrete implementation exposing an external initializer so we
///      can exercise `__SignatureVerifier_init`.
contract MockSignatureVerifierUpgradeable is SignatureVerifierUpgradeable {
    function initialize(string memory name, string memory version)
        public
        initializer
    {
        __SignatureVerifier_init(name, version);
    }
}

contract SignatureVerifierUpgradeableTest is Test {
    // Proxy-addressed instance we interact with
    SignatureVerifierUpgradeable public verifier;

    // Test actors
    address public user;

    function setUp() public {
        user = makeAddr("user");

        // Deploy implementation & proxy
        MockSignatureVerifierUpgradeable impl =
            new MockSignatureVerifierUpgradeable();

        bytes memory initData =
            abi.encodeWithSignature("initialize(string,string)", "MagicSigner", "1");

        verifier = SignatureVerifierUpgradeable(
            address(new ERC1967Proxy(address(impl), initData))
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALISER
    //////////////////////////////////////////////////////////////*/

    function test_RevertOnReinitialise() public {
        vm.prank(user);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MockSignatureVerifierUpgradeable(address(verifier))
            .initialize("MagicSigner", "1");
    }
}
