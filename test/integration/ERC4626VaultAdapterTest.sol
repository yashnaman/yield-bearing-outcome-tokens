// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {ConfigurableERC20} from "test/mocks/ConfigurableERC20.sol";
import {ERC4626VaultAdapter} from "src/adapters/ERC4626VaultAdapter.sol";

/// @notice Direct tests of ERC4626VaultAdapter's own invariants: it must only obey its YieldBearingOutcomeTokens
/// instance, only handle its single collateral, and account invested shares per market in isolation. These are
/// exercised here without routing through the vault, by pranking as the authorized YieldBearingOutcomeTokens.
contract ERC4626VaultAdapterTest is BaseTest {
    // A second market that shares this adapter and collateral but uses a different condition, so it maps to a distinct
    // adapter id and must be accounted independently.
    bytes32 internal conditionId2;
    IYieldBearingOutcomeTokens.MarketParams internal market2;

    function setUp() public override {
        super.setUp();

        bytes32 questionId2 = keccak256("adapter-question-2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);

        market2 = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId2,
            vaultAdapter: IVaultAdapter(address(adapter))
        });
    }

    /// @dev Sends `amount` of collateral to the adapter and invests it for `m` as the authorized vault would.
    function _investAs(IYieldBearingOutcomeTokens.MarketParams memory m, uint256 amount) internal {
        collateral.mint(address(adapter), amount);
        vm.prank(address(vault));
        adapter.invest(m, amount);
    }

    function testConstructorRevertsOnZeroVault() public {
        vm.expectRevert(ERC4626VaultAdapter.ZeroAddress.selector);
        new ERC4626VaultAdapter(IERC4626(address(0)), address(vault));
    }

    function testConstructorRevertsOnZeroYieldBearingOutcomeTokens() public {
        vm.expectRevert(ERC4626VaultAdapter.ZeroAddress.selector);
        new ERC4626VaultAdapter(IERC4626(address(erc4626)), address(0));
    }

    function testImmutablesAreWired() public view {
        assertEq(address(adapter.VAULT()), address(erc4626), "VAULT");
        assertEq(address(adapter.COLLATERAL_TOKEN()), erc4626.asset(), "COLLATERAL_TOKEN == vault asset");
        assertEq(adapter.YIELD_BEARING_OUTCOME_TOKENS(), address(vault), "YIELD_BEARING_OUTCOME_TOKENS");
    }

    function testInvestOnlyCallableByVault() public {
        collateral.mint(address(adapter), 1000);
        vm.prank(ALICE);
        vm.expectRevert(ERC4626VaultAdapter.Unauthorized.selector);
        adapter.invest(marketParams, 1000);
    }

    function testDivestOnlyCallableByVault() public {
        _investAs(marketParams, 1000);
        vm.prank(ALICE);
        vm.expectRevert(ERC4626VaultAdapter.Unauthorized.selector);
        adapter.divest(marketParams, 1000);
    }

    function testRejectsUnsupportedCollateral() public {
        IYieldBearingOutcomeTokens.MarketParams memory foreign = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(0xBEEF)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(adapter))
        });

        vm.expectRevert(ERC4626VaultAdapter.UnsupportedCollateral.selector);
        adapter.investedBalance(foreign);

        vm.prank(address(vault));
        vm.expectRevert(ERC4626VaultAdapter.UnsupportedCollateral.selector);
        adapter.invest(foreign, 1000);

        vm.prank(address(vault));
        vm.expectRevert(ERC4626VaultAdapter.UnsupportedCollateral.selector);
        adapter.divest(foreign, 1000);
    }

    function testInvestDivestRoundTripReturnsCollateralToCaller() public {
        uint256 amount = 1000;
        _investAs(marketParams, amount);

        assertEq(adapter.investedBalance(marketParams), amount, "invested balance reflects the deposit");

        uint256 vaultBalanceBefore = collateral.balanceOf(address(vault));
        vm.prank(address(vault));
        adapter.divest(marketParams, amount);

        assertEq(collateral.balanceOf(address(vault)) - vaultBalanceBefore, amount, "divest pays the caller");
        assertEq(adapter.investedBalance(marketParams), 0, "invested balance drained");
    }

    function testInvestRevertsWhenCollateralApproveReturnsFalse() public {
        // A vault whose underlying asset returns false on `approve` only for the adapter's own call, so the raw-bool
        // check in `invest` trips `ApproveFailed`.
        ConfigurableERC20 badCollateral = new ConfigurableERC20("Bad", "BAD");
        MockERC4626 badVault = new MockERC4626(IERC20(address(badCollateral)));
        ERC4626VaultAdapter badAdapter = new ERC4626VaultAdapter(IERC4626(address(badVault)), address(vault));
        badCollateral.setApproveRevertsFor(address(badAdapter));

        IYieldBearingOutcomeTokens.MarketParams memory badMarket = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(badCollateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(badAdapter))
        });

        badCollateral.mint(address(badAdapter), 1000);
        vm.prank(address(vault));
        vm.expectRevert(ERC4626VaultAdapter.ApproveFailed.selector);
        badAdapter.invest(badMarket, 1000);
    }

    function testPerMarketAccountingIsIsolated() public {
        _investAs(marketParams, 1000);
        _investAs(market2, 4000);

        assertEq(adapter.investedBalance(marketParams), 1000, "market 1 unaffected by market 2");
        assertEq(adapter.investedBalance(market2), 4000, "market 2 tracked independently");

        // Market 1 cannot divest more than it invested, even though market 2's funds sit in the same vault.
        vm.prank(address(vault));
        vm.expectRevert(); // sharesOf underflow
        adapter.divest(marketParams, 2000);

        // Draining market 1 entirely leaves market 2 intact.
        vm.prank(address(vault));
        adapter.divest(marketParams, 1000);
        assertEq(adapter.investedBalance(marketParams), 0, "market 1 drained");
        assertEq(adapter.investedBalance(market2), 4000, "market 2 still fully funded");
    }
}
