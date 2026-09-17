// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";

/// @notice Deploy-script guards on the bug-bounty recipient. It is the one factory input with no
///         setter and no governance path — a wrong value is corrected only by redeploying the
///         factory and re-listing every pair — so the script must never pick it implicitly on a
///         chain where the fees are real.
///
///         The anvil fallback is not covered here: the environment cannot be unset from inside a
///         test, so a case asserting it would pass or fail on the ambient value rather than on the
///         code. It is exercised by `make deploy-anvil`.
contract DeployBazaarScriptTest is Test {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant ANVIL = 31337;

    DeployBazaar internal dep;

    function setUp() public {
        dep = new DeployBazaar();
    }

    /// @dev Written rather than read: the ambient value differs between a developer's shell and
    ///      CI, and every case here has to pin it either way.
    function _setRecipientEnv(address recipient) internal {
        vm.setEnv("BUG_BOUNTY_ADDRESS", vm.toString(recipient));
    }

    /// @notice A live chain with no configured recipient aborts, and aborts in the resolver —
    ///         before HelperConfig is constructed and before the first broadcast.
    function test_run_liveChain_requiresConfiguredRecipient() public {
        _setRecipientEnv(address(0));
        vm.chainId(ARBITRUM_ONE);

        vm.expectRevert(
            bytes(
                "BUG_BOUNTY_ADDRESS is unset. It is immutable in the factory and copied into every pair,"
                " so set it explicitly before deploying to a live chain."
            )
        );
        dep.run();
    }

    /// @notice The configured recipient reaches the factory, which is what makes setting the
    ///         variable a real control rather than a checked-and-discarded one.
    function test_run_usesConfiguredRecipient() public {
        address recipient = makeAddr("bugBountyTreasury");
        _setRecipientEnv(recipient);
        vm.chainId(ANVIL);

        (BazaarFactory factory,) = dep.run();

        assertEq(factory.bugBountyAddress(), recipient, "configured recipient reached the factory");
    }

    /// @notice The zero address is refused by the script, not left to the factory: the factory's
    ///         own Factory__ZeroAddress fires only after the oracle, the pair implementation, the
    ///         lens and the terminator have already been broadcast.
    function test_deploy_refusesZeroRecipient() public {
        vm.expectRevert(bytes("bugBountyAddress is the zero address"));
        dep.deploy(address(0));
    }
}
