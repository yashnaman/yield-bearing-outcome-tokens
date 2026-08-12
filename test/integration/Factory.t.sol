// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {OutcomeYieldPoolFactory} from "src/OutcomeYieldPoolFactory.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {ShareIdLib} from "src/libraries/ShareIdLib.sol";

/// @notice Tests for the stateless factory: deterministic addresses, one pool per market, and the immutables each
/// pool is born with. The factory holds no storage, so "this market already has a pool" is enforced by the CREATE2
/// collision itself rather than by a registry — that is the behaviour pinned here.
contract FactoryTest is BaseTest {
    event PoolDeployed(IERC4626 indexed yieldVault, bytes32 indexed conditionId, address pool);

    bytes32 internal otherCondition;

    function setUp() public override {
        super.setUp();

        ct.prepareCondition(ORACLE, keccak256("factory-question"), 2);
        otherCondition = ct.getConditionId(ORACLE, keccak256("factory-question"), 2);
    }

    /// @dev The address is a pure function of (factory, vault, condition) and is known before deployment.
    function testGetPoolAddressPredictsTheDeployment() public {
        address predicted = factory.getPoolAddress(defaultVault, otherCondition);
        assertEq(predicted.code.length, 0, "nothing deployed yet");

        OutcomeYieldPool deployed = factory.deployPool(defaultVault, otherCondition);

        assertEq(address(deployed), predicted, "deployed at the predicted address");
        assertGt(predicted.code.length, 0, "and there is code there now");
    }

    /// @dev The prediction is stable for a market that already exists, so off-chain consumers can resolve a pool
    /// address without tracking events.
    function testGetPoolAddressMatchesAnExistingPool() public view {
        assertEq(factory.getPoolAddress(defaultVault, conditionId), address(pool), "resolves the default market");
    }

    /// @dev Deploying a market that already exists returns it instead of reverting, so a caller can bundle "create
    /// the market if needed, then deposit" without knowing which case it is in. No second event is emitted.
    function testRedeployingReturnsTheExistingPool() public {
        vm.recordLogs();
        OutcomeYieldPool again = factory.deployPool(defaultVault, conditionId);

        assertEq(address(again), address(pool), "returns the existing pool");
        assertEq(vm.getRecordedLogs().length, 0, "and emits nothing the second time");
    }

    /// @dev The early return only covers a market that already exists. A market the pool's constructor rejects has no
    /// code at its address, so it still reverts rather than silently returning an empty address.
    function testEarlyReturnDoesNotMaskAConstructorRejection() public {
        ct.prepareCondition(ORACLE, keccak256("three-slot"), 3);
        bytes32 threeSlot = ct.getConditionId(ORACLE, keccak256("three-slot"), 3);

        vm.expectRevert(IOutcomeYieldPool.NotBinaryCondition.selector);
        factory.deployPool(defaultVault, threeSlot);
    }

    /// @dev Different vaults over one condition, and different conditions over one vault, are all distinct markets.
    function testDistinctMarketsGetDistinctPools() public {
        MockERC4626 otherVault = new MockERC4626(IERC20(address(collateral)));

        address a = address(factory.deployPool(defaultVault, otherCondition));
        address b = address(factory.deployPool(IERC4626(address(otherVault)), conditionId));
        address c = address(factory.deployPool(IERC4626(address(otherVault)), otherCondition));

        assertTrue(a != address(pool) && b != address(pool) && c != address(pool), "all distinct from the default");
        assertTrue(a != b && b != c && a != c, "and from each other");
    }

    /// @dev Two factories over the same ConditionalTokens produce different addresses for the same market, since the
    /// deployer is part of the CREATE2 preimage.
    function testPoolsAreScopedToTheirFactory() public {
        OutcomeYieldPoolFactory other = new OutcomeYieldPoolFactory(ct);

        assertTrue(
            other.getPoolAddress(defaultVault, conditionId) != factory.getPoolAddress(defaultVault, conditionId),
            "a second factory addresses its own pools"
        );
        // And it can deploy the same market independently.
        assertEq(address(other.deployPool(defaultVault, conditionId)), other.getPoolAddress(defaultVault, conditionId));
    }

    /// @dev The id derivation is injective and invertible: a share id names exactly one pool and one side.
    /* GENUINENESS */

    /// @dev The documented hazard of deriving the id from `msg.sender`: an arbitrary contract can mint on the shared
    /// ledger — but only under its own two ids. It can never touch a real market's.
    function testImpostorCanOnlyMintItsOwnIds() public {
        Impostor impostor = new Impostor(factory);

        // It can mint freely in its own namespace.
        impostor.mintSelf(ALICE, true, 1e18);
        assertEq(factory.balanceOf(ALICE, ShareIdLib.idFor(address(impostor), true)), 1e18, "minted its own id");

        // Naming the real pool changes nothing: the factory ignores the argument and derives the id from msg.sender.
        impostor.tryMintForeign(address(pool), ALICE, true, 1e18);

        // The real market's supply and Alice's real balance are untouched either way.
        assertEq(factory.totalSupply(yesShareId), 0, "the real market's supply is unchanged");
        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "and Alice holds none of its shares");
        assertEq(
            factory.balanceOf(ALICE, ShareIdLib.idFor(address(impostor), true)),
            2e18,
            "both mints landed in the impostor's own namespace"
        );
    }

    /// @dev Which is exactly why an id alone is not proof of a market. `isGenuineId` is the check integrators run.
    /// @dev A pool CAN be constructed outside a factory, and it does not matter. It binds `msg.sender` as its ledger,
    /// so it mints against whoever deployed it, and it lands at an address no factory would ever predict — so no
    /// consumer resolving a market through `getPoolAddress` can reach it.
    /// @dev This used to revert, but only incidentally: the constructor called `factory.idFor(...)`, which failed
    /// against a non-factory deployer. Share ids now come from {ShareIdLib}, so there is no such call and no such
    /// revert. Nothing was protecting anything — an impostor pool holds only what its own deployer funds it with.
    function testPoolDeployedOutsideAFactoryIsUnreachable() public {
        ct.prepareCondition(ORACLE, keccak256("rogue"), 2);
        bytes32 rogueCondition = ct.getConditionId(ORACLE, keccak256("rogue"), 2);

        OutcomeYieldPool rogue = new OutcomeYieldPool(ct, defaultVault, rogueCondition);

        assertTrue(
            factory.getPoolAddress(defaultVault, rogueCondition) != address(rogue),
            "the factory never resolves this market to the rogue pool"
        );
        assertEq(factory.getPoolAddress(defaultVault, rogueCondition).code.length, 0, "the real address is still empty");
    }

    /// @dev A pool deployed by a *different* factory is a real pool with real ids, and still not this factory's — each
    /// factory addresses only the markets it deployed itself. With no `isGenuinePool` on the core, the check a consumer
    /// runs is the address comparison, which is the same test one call shorter.
    function testPoolFromAnotherFactoryIsNotThisFactorys() public {
        OutcomeYieldPoolFactory other = new OutcomeYieldPoolFactory(ct);
        OutcomeYieldPool foreign = other.deployPool(defaultVault, conditionId);

        assertEq(other.getPoolAddress(defaultVault, conditionId), address(foreign), "genuine to its own factory");
        assertTrue(factory.getPoolAddress(defaultVault, conditionId) != address(foreign), "but not to this one");
    }

    /// @dev Anyone can create a market; there is no owner or allowlist.
    function testDeploymentIsPermissionless() public {
        vm.prank(makeAddr("Stranger"));
        OutcomeYieldPool p = factory.deployPool(defaultVault, otherCondition);
        assertGt(address(p).code.length, 0, "a stranger deployed the market");
    }

    function testDeployEmitsEvent() public {
        address predicted = factory.getPoolAddress(defaultVault, otherCondition);

        vm.expectEmit(true, true, true, true, address(factory));
        emit PoolDeployed(defaultVault, otherCondition, predicted);

        factory.deployPool(defaultVault, otherCondition);
    }

    /// @dev A pool is self-describing through the only two immutables it exposes, and that pair is enough to recover
    /// everything else about it — which is why the rest were removed. Deriving the position ids from `YIELD_VAULT()`
    /// and `CONDITION_ID()` and getting the fixture's own ids back is the proof.
    function testPoolIsSelfDescribing() public view {
        assertEq(address(pool.YIELD_VAULT()), address(defaultVault), "bound to its vault");
        assertEq(pool.CONDITION_ID(), conditionId, "bound to its condition");

        assertEq(address(pool.YIELD_VAULT().asset()), address(collateral), "collateral follows from the vault");
        assertEq(_poolPositionId(pool, true), yesPositionId, "YES position id follows from the pair");
        assertEq(_poolPositionId(pool, false), noPositionId, "NO position id follows from the pair");
    }

    /// @dev Both allowances a pool ever needs are granted once, in the constructor, and never touched again.
    function testConstructorGrantsBothAllowances() public view {
        assertEq(collateral.allowance(address(pool), address(ct)), type(uint256).max, "ConditionalTokens approved");
        assertEq(collateral.allowance(address(pool), address(defaultVault)), type(uint256).max, "vault approved");
    }

    /// @dev A vault that reports itself as its own asset is rejected: its `balanceOf` would mean both "collateral
    /// held" and "vault shares held" at once, and the two accounting paths would read each other's balance.
    function testSelfReferentialVaultRejected() public {
        SelfAssetVault v = new SelfAssetVault();

        vm.expectRevert(IOutcomeYieldPool.InvalidCollateral.selector);
        factory.deployPool(IERC4626(address(v)), conditionId);
    }

    /// @dev A vault reporting the zero address as its asset is rejected too.
    function testZeroAssetVaultRejected() public {
        ZeroAssetVault v = new ZeroAssetVault();

        vm.expectRevert(IOutcomeYieldPool.InvalidCollateral.selector);
        factory.deployPool(IERC4626(address(v)), conditionId);
    }

    function testFactoryRejectsZeroConditionalTokens() public {
        vm.expectRevert(OutcomeYieldPoolFactory.ZeroAddress.selector);
        new OutcomeYieldPoolFactory(IConditionalTokens(address(0)));
    }
}

/// @notice A contract that mints on the shared ledger without being a pool, to pin what the id derivation does and
/// does not guarantee.
contract Impostor {
    OutcomeYieldPoolFactory immutable FACTORY;

    constructor(OutcomeYieldPoolFactory f) {
        FACTORY = f;
    }

    function mintSelf(address to, bool isYes, uint256 amount) external {
        FACTORY.mint(to, isYes, amount);
    }

    /// @dev Tries to mint a *different* pool's shares. The factory ignores the argument entirely and derives the id
    /// from `msg.sender`, so this can only ever credit this contract's own namespace.
    function tryMintForeign(address, address to, bool isYes, uint256 amount) external {
        FACTORY.mint(to, isYes, amount);
    }
}

contract SelfAssetVault {
    function asset() external view returns (address) {
        return address(this);
    }
}

contract ZeroAssetVault {
    function asset() external pure returns (address) {
        return address(0);
    }
}
