// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {InvariantBaseTest} from "test/invariant/InvariantBase.t.sol";

/// @notice Honest-vault invariants. Only the bounded handlers are targeted, and `fail_on_revert = true` means this
/// suite also proves liveness: no well-formed deposit/redeem ever reverts.
contract InvariantTest is InvariantBaseTest {
    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = this.depositHandler.selector;
        selectors[1] = this.redeemHandler.selector;
        selectors[2] = this.accrueYieldHandler.selector;
        selectors[3] = this.donateHandler.selector;
        selectors[4] = this.transferHandler.selector;
        selectors[5] = this.mergeHandler.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /// @dev Tracked actors always hold exactly each side's total share supply.
    function invariant_shareConservation() public view {
        assertShareConservation();
    }

    /// @dev Each pool holds ERC-4626 shares of its own vault only.
    function invariant_vaultShareIsolation() public view {
        assertVaultShareIsolation();
    }

    /// @dev Merging and splitting both preserve `dangling + invested` on each side, so a side's backing always covers
    /// everything that flowed into it minus what flowed out.
    function invariant_sideBackingCoversFlows() public view {
        assertSideBackingCoversFlows();
    }

    /// @dev Exact, rounding-free token conservation: no outcome token ever crosses between pools.
    function invariant_yesNoDifferenceConservation() public view {
        assertYesNoDifferenceConservation();
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
