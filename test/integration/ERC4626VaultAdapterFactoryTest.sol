// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {ERC4626VaultAdapter} from "src/adapters/ERC4626VaultAdapter.sol";
import {ERC4626VaultAdapterFactory} from "src/adapters/ERC4626VaultAdapterFactory.sol";
import {IERC4626VaultAdapterFactory} from "src/interface/IERC4626VaultAdapterFactory.sol";

/// @notice Tests the CREATE2 factory: deterministic addresses (prediction matches deployment), correct wiring of the
/// deployed adapter, and the one-adapter-per-vault uniqueness that the vault-address salt enforces.
contract ERC4626VaultAdapterFactoryTest is BaseTest {
    // A fresh vault that BaseTest's `factory` has not deployed an adapter for yet.
    MockERC4626 internal freshVault;

    function setUp() public override {
        super.setUp();
        freshVault = new MockERC4626(IERC20(address(collateral)));
    }

    function testConstructorRevertsOnZeroYieldBearingOutcomeTokens() public {
        vm.expectRevert(ERC4626VaultAdapterFactory.ZeroAddress.selector);
        new ERC4626VaultAdapterFactory(address(0));
    }

    function testPredictedAddressMatchesDeployment() public {
        address predicted = factory.getAdapterAddress(IERC4626(address(freshVault)));

        vm.expectEmit(true, false, false, true, address(factory));
        emit IERC4626VaultAdapterFactory.AdapterDeployed(IERC4626(address(freshVault)), predicted);
        ERC4626VaultAdapter deployed = factory.deployAdapter(IERC4626(address(freshVault)));

        assertEq(address(deployed), predicted, "prediction matches CREATE2 deployment");
        assertGt(predicted.code.length, 0, "adapter has code");
    }

    function testDeployedAdapterIsWiredAndUsable() public {
        ERC4626VaultAdapter deployed = factory.deployAdapter(IERC4626(address(freshVault)));

        assertEq(address(deployed.VAULT()), address(freshVault), "VAULT");
        assertEq(address(deployed.COLLATERAL_TOKEN()), freshVault.asset(), "COLLATERAL_TOKEN");
        assertEq(deployed.YIELD_BEARING_OUTCOME_TOKENS(), address(vault), "bound to the factory's YBOT");

        // End-to-end: a market using the factory-deployed adapter merges and invests on a balanced deposit.
        IYieldBearingOutcomeTokens.MarketParams memory m = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(deployed))
        });

        _mintOutcomeTokens(ALICE, 1000);
        vm.prank(ALICE);
        vault.deposit(m, true, 1000, ALICE);
        _mintOutcomeTokens(BOB, 1000);
        vm.prank(BOB);
        vault.deposit(m, false, 1000, BOB); // matches ALICE's side -> merges 1000 and invests

        assertEq(deployed.investedBalance(m), 1000, "balanced deposit was invested through the adapter");
    }

    function testRedeployingSameVaultReverts() public {
        factory.deployAdapter(IERC4626(address(freshVault)));
        vm.expectRevert(); // CREATE2 to an existing address fails
        factory.deployAdapter(IERC4626(address(freshVault)));
    }

    function testSecondFactoryDeploysSameVaultAtDifferentAddress() public {
        address fromFactoryA = factory.getAdapterAddress(IERC4626(address(freshVault)));

        ERC4626VaultAdapterFactory factoryB = new ERC4626VaultAdapterFactory(address(vault));
        address fromFactoryB = factoryB.getAdapterAddress(IERC4626(address(freshVault)));

        assertTrue(fromFactoryA != fromFactoryB, "distinct deployers yield distinct addresses for the same vault");

        // Both can actually deploy, proving there is no global collision on the salt.
        assertEq(address(factory.deployAdapter(IERC4626(address(freshVault)))), fromFactoryA, "factory A");
        assertEq(address(factoryB.deployAdapter(IERC4626(address(freshVault)))), fromFactoryB, "factory B");
    }
}
