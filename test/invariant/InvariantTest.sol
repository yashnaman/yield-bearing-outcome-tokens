// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {InvariantBaseTest} from "test/invariant/InvariantBaseTest.sol";

/// @notice Honest-vault invariants. Only the bounded handlers are targeted, and `fail_on_revert = true` means this
/// suite also proves liveness: no well-formed deposit/redeem ever reverts.
contract InvariantTest is InvariantBaseTest {
    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.depositHandler.selector;
        selectors[1] = this.redeemHandler.selector;
        selectors[2] = this.accrueYieldHandler.selector;
        selectors[3] = this.donateHandler.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /// @dev Tracked actors always hold exactly each side's total shares.
    function invariant_shareConservation() public view {
        assertShareConservation();
    }

    /// @dev The pooled ERC1155 balance is always exactly the sum of the markets' internal dangling balances — markets
    /// sharing a position id never bleed into one another.
    function invariant_poolConservation() public view {
        assertPoolConservation();
    }

    /// @dev Markets never claim more collateral than their underlying ERC4626 vault holds.
    function invariant_vaultSolvency() public view {
        assertVaultSolvency();
    }

    /// @dev Every holder can always exit: redeeming all shares across every market and side succeeds simultaneously.
    function invariant_allHoldersCanRedeem() public {
        assertAllHoldersCanRedeem();
    }
}
