// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice Exposes BazaarTypes.absorbLossIntoInsurance over a real Vault storage struct.
contract AbsorbHarness {
    BazaarTypes.Vault internal v;

    function set(uint256 insurance_, uint256 deficit_) external {
        v.insuranceFundBalance = insurance_;
        v.deficit = deficit_;
    }

    function absorb(uint256 loss) external {
        BazaarTypes.absorbLossIntoInsurance(v, loss);
    }

    function insurance() external view returns (uint256) {
        return v.insuranceFundBalance;
    }

    function deficit() external view returns (uint256) {
        return v.deficit;
    }
}

/// @notice Unit tests for the insurance loss-absorption primitive: losses draw the fund down and,
///         once it hits zero, the overrun accrues to `deficit` (realized bad debt).
contract InsuranceAbsorbTest is Test {
    AbsorbHarness internal h;

    function setUp() public {
        h = new AbsorbHarness();
    }

    function test_lossBelowInsurance_drawsFundOnly() public {
        h.set(100, 0);
        h.absorb(30);
        assertEq(h.insurance(), 70, "fund reduced by loss");
        assertEq(h.deficit(), 0, "no deficit");
    }

    function test_lossEqualsInsurance_zeroesFundNoDeficit() public {
        h.set(100, 0);
        h.absorb(100);
        assertEq(h.insurance(), 0);
        assertEq(h.deficit(), 0, "exact drain records no deficit");
    }

    function test_lossExceedsInsurance_zeroesFundRecordsOverrun() public {
        h.set(100, 0);
        h.absorb(150);
        assertEq(h.insurance(), 0, "fund floored at zero");
        assertEq(h.deficit(), 50, "overrun becomes deficit");
    }

    function test_zeroLoss_noChange() public {
        h.set(100, 5);
        h.absorb(0);
        assertEq(h.insurance(), 100);
        assertEq(h.deficit(), 5, "pre-existing deficit untouched");
    }

    function test_fromEmptyFund_wholeLossIsDeficit() public {
        h.set(0, 0);
        h.absorb(25);
        assertEq(h.insurance(), 0);
        assertEq(h.deficit(), 25);
    }

    function test_deficitAccumulatesAcrossCalls() public {
        h.set(50, 10); // start with a pre-existing 10 deficit
        h.absorb(80); // 80 > 50 -> fund 0, deficit += 30 => 40
        assertEq(h.insurance(), 0);
        assertEq(h.deficit(), 40);
        h.absorb(20); // fund already 0 -> whole 20 is deficit => 60
        assertEq(h.insurance(), 0);
        assertEq(h.deficit(), 60);
    }
}
