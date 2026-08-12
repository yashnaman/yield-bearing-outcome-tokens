// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";

import {BaseTest} from "test/Base.t.sol";
import {PassiveVault, ReenteringVault, SelfReenteringVault, SweepingVault} from "test/mocks/HostileERC4626.sol";

/// @notice One market's pool cannot reach another market's funds.
/// @dev Every attack here needed the same thing: a single contract holding every market's ERC-20 balance and granting
/// every market's allowances. The classic setup was a fake vault whose `asset()` is a *genuine* vault's share token,
/// which turned the singleton's permanent share balance into reachable ERC-20 collateral. With one pool per market the
/// setups still build — `prepareCondition` is still permissionless, an ERC-4626 share is still valid ConditionalTokens
/// collateral, and `deployPool` still serves any vault — but there is nothing on the other side of them. The
/// attacker's pools are different contracts holding their own funds, so isolation is physical rather than checked.
///
/// @dev The honest market is the default fixture: `pool` over `erc4626` (the genuine vault) with `collateral` as the
/// underlying. The attacker's markets are built on top of it.
contract MarketIsolationTest is BaseTest {
    address internal ATTACKER;

    /// @dev A second prepared condition, so an attacker's market is a different market rather than the same one.
    bytes32 internal attackCondition;

    uint256 internal constant N = 1_000e6;

    function setUp() public override {
        super.setUp();

        ATTACKER = makeAddr("Attacker");

        ct.prepareCondition(ORACLE, keccak256("attack"), 2);
        attackCondition = ct.getConditionId(ORACLE, keccak256("attack"), 2);
    }

    /// @dev Position id over the genuine vault's SHARE token, on the attacker's condition.
    function _sharePid(bool isYes) internal view returns (uint256) {
        return _positionId(IERC20(address(erc4626)), attackCondition, isYes);
    }

    /// @dev Position id over the real collateral, on the honest market's condition.
    function _honestPid(bool isYes) internal view returns (uint256) {
        return _positionId(IERC20(address(collateral)), conditionId, isYes);
    }

    /// @dev Establishes the honest position: Alice's collateral becomes genuine vault SHARES held by the honest pool.
    function _seedHonestMarket() internal {
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, N, address(pool));

        vm.startPrank(ALICE);
        pool.deposit(true, N, ALICE);
        pool.deposit(false, N, ALICE);
        vm.stopPrank();

        assertEq(erc4626.balanceOf(address(pool)), N, "honest pool holds the genuine vault shares");
        assertEq(_invested(pool), N, "and reports them as its invested balance");
    }

    /// @dev Gives the attacker `amount` of both outcome tokens denominated in the genuine vault's share token, on the
    /// attacker's condition, and approves `operator` to pull them.
    /// @return fronted The attacker's own share balance after converting its collateral, measured before the split
    /// spends it. Tests assert against this to show the attacker only ever risked its own capital.
    function _mintShareBackedOutcomeTokens(uint256 amount, address operator) internal returns (uint256 fronted) {
        collateral.mint(ATTACKER, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(ATTACKER);
        collateral.approve(address(erc4626), amount);
        erc4626.deposit(amount, ATTACKER);
        fronted = erc4626.balanceOf(ATTACKER);
        erc4626.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(erc4626)), PARENT_COLLECTION_ID, attackCondition, partition, amount);
        ct.setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    /* ---- The non-binary variant: the market cannot even be deployed ---- */

    /// @dev A three-slot condition makes `mergePositions` return no collateral, which was the original sweep. It never
    /// gets off the ground now: the pool's constructor rejects it, so no market exists to deposit into.
    function testNonBinaryMarketCannotEvenBeDeployed() public {
        _seedHonestMarket();

        vm.startPrank(ATTACKER);
        SweepingVault evil = new SweepingVault(address(erc4626));

        // Permissionless: any condition, 3 outcome slots.
        ct.prepareCondition(ATTACKER, keccak256("evil"), 3);
        bytes32 evilCondition = ct.getConditionId(ATTACKER, keccak256("evil"), 3);

        vm.expectRevert(IOutcomeYieldPool.NotBinaryCondition.selector);
        factory.deployPool(IERC4626(address(evil)), evilCondition);
        vm.stopPrank();

        assertEq(
            factory.getPoolAddress(IERC4626(address(evil)), evilCondition).code.length, 0, "no pool at the address"
        );
        assertEq(erc4626.balanceOf(address(pool)), N, "Alice's shares untouched");
    }

    /* ---- The binary variant: the market deploys, and still reaches nothing ---- */

    /// @dev The variant an `outcomeSlotCount == 2` check alone does not close. The attacker's market deploys and funds
    /// normally — with the attacker's OWN shares — and its exit still delivers nothing. The exit simply fails for want
    /// of the attacker's own collateral; it has no access to the honest pool's.
    function testBinaryMarketCannotReachTheHonestPoolsShares() public {
        _seedHonestMarket();

        vm.startPrank(ATTACKER);
        SweepingVault evil = new SweepingVault(address(erc4626));
        ct.prepareCondition(ATTACKER, keccak256("evil2"), 2); // BINARY
        bytes32 c2 = ct.getConditionId(ATTACKER, keccak256("evil2"), 2);
        vm.stopPrank();

        OutcomeYieldPool evilPool = factory.deployPool(IERC4626(address(evil)), c2);

        collateral.mint(ATTACKER, N);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(ATTACKER);
        collateral.approve(address(erc4626), N);
        erc4626.deposit(N, ATTACKER);
        erc4626.approve(address(ct), N);
        ct.splitPosition(IERC20(address(erc4626)), PARENT_COLLECTION_ID, c2, partition, N);
        ct.setApprovalForAll(address(evilPool), true);

        evilPool.deposit(true, N, ATTACKER);
        evilPool.deposit(false, N, ATTACKER);

        // The attacker's own N shares moved into the attacker's own fake vault. Alice's are elsewhere entirely.
        assertEq(erc4626.balanceOf(address(evil)), N, "the fake vault holds only the attacker's shares");
        assertEq(erc4626.balanceOf(address(pool)), N, "Alice's shares untouched by the deposit");

        evil.setPreview(N);
        vm.expectRevert();
        evilPool.redeem(true, N * 1e6, ATTACKER, ATTACKER);
        vm.stopPrank();

        /* Isolation, stated three ways. */
        assertEq(erc4626.balanceOf(address(pool)), N, "Alice's shares untouched by the redeem");
        assertEq(_invested(pool), N, "honest invested balance intact");
        assertEq(erc4626.allowance(address(pool), address(evil)), 0, "the fake vault has no claim on the honest pool");

        /* Alice can still redeem in full. */
        uint256 aliceShares = factory.balanceOf(ALICE, _shareId(pool, true));
        vm.prank(ALICE);
        uint256 out = pool.redeem(true, aliceShares, ALICE, ALICE);
        assertEq(out, N, "Alice redeems her full principal");
    }

    /* ---- The reentrant delta-inflation chain ---- */

    /// @dev Vault A reenters a second pool's `deposit` from inside its own exit. Under the singleton the nested merge
    /// delivered collateral into the one shared balance and satisfied the *outer* market's delta check.
    function testReentrantDepositCannotReachTheHonestPoolAcrossMarkets() public {
        _seedHonestMarket();

        vm.startPrank(ATTACKER);
        ReenteringVault vaultA = new ReenteringVault(address(erc4626), ct);
        PassiveVault vaultB = new PassiveVault(address(erc4626));

        OutcomeYieldPool poolA = factory.deployPool(IERC4626(address(vaultA)), attackCondition);
        OutcomeYieldPool poolB = factory.deployPool(IERC4626(address(vaultB)), attackCondition);
        vm.stopPrank();

        uint256 attackerStart = _mintShareBackedOutcomeTokens(2 * N, address(poolA));

        vm.startPrank(ATTACKER);
        ct.setApprovalForAll(address(poolB), true);

        // Market A funded honestly (vaultA really pulls the N).
        poolA.deposit(true, N, ATTACKER);
        poolA.deposit(false, N, ATTACKER);
        assertEq(erc4626.balanceOf(address(pool)), N, "honest pool untouched by market A");

        // Market B: YES side only, so its merge fires later from inside the callback.
        poolB.deposit(true, N, ATTACKER);

        // Hand vaultA the NO tokens it will deposit into B during the reentrancy.
        ct.safeTransferFrom(ATTACKER, address(vaultA), _sharePid(false), N, "");
        vaultA.arm(poolB, N, ATTACKER);

        /* The attack: redeem A; A's exit delivers nothing and reenters B's merge. */
        vaultA.setPreview(N);
        // The reentrant nested merge no longer manufactures anything for the outer frame: poolA's own split has no
        // collateral to work with, so it simply cannot deliver the tokens the redeem owes.
        vm.expectRevert();
        poolA.redeem(true, N * 1e6, ATTACKER, ATTACKER);
        vm.stopPrank();

        /* Nothing of Alice's was ever reachable. */
        assertEq(erc4626.balanceOf(address(pool)), N, "Alice's principal intact");
        assertEq(erc4626.allowance(address(pool), address(vaultA)), 0, "vault A has no claim on the honest pool");
        assertEq(erc4626.allowance(address(pool), address(vaultB)), 0, "vault B has no claim on the honest pool");
        assertEq(attackerStart, 2 * N, "attacker only ever fronted its own capital");

        // And Alice can still exit in full.
        uint256 aliceShares = factory.balanceOf(ALICE, _shareId(pool, true));
        vm.prank(ALICE);
        pool.redeem(true, aliceShares, ALICE, ALICE);
        assertEq(ct.balanceOf(ALICE, _honestPid(true)), N, "Alice recovers her YES tokens");
    }

    /// @dev The unbounded allowance a pool grants its vault in the constructor is real, but scoped: `vaultB` can drain
    /// `poolB`, and `poolB` holds nothing but the attacker's own collateral. A claim on every market's funds is
    /// reduced to a claim on the funds of the market that chose the vault.
    function testConstructorAllowanceIsScopedToItsOwnPool() public {
        PassiveVault vaultB = new PassiveVault(address(erc4626));
        OutcomeYieldPool poolB = factory.deployPool(IERC4626(address(vaultB)), attackCondition);

        assertEq(
            erc4626.allowance(address(poolB), address(vaultB)),
            type(uint256).max,
            "vault B may spend its own pool's collateral"
        );
        assertEq(erc4626.allowance(address(pool), address(vaultB)), 0, "and nothing of the honest pool's");

        // Draining its own pool takes nothing, because its own pool holds nothing of anyone else's.
        vaultB.drain(address(poolB), 0, ATTACKER);
        assertEq(erc4626.balanceOf(address(poolB)), 0, "the hostile pool never held any genuine shares");
    }

    /* ---- The phantom-dangling window ---- */

    /// @dev The singleton credited the counterparty side's dangling balance ~30 lines before `splitPosition` actually
    /// minted those tokens, so during a vault callback a nested merge could be charged against tokens that did not
    /// exist yet — burning a *different* market's tokens out of the one shared ERC-1155 balance.
    ///
    /// That write has no counterpart now. Dangling balances are not bookkept at all: they are the pool's own
    /// ConditionalTokens balance, credited by `splitPosition` at the instant it mints. And the victim's market is a
    /// different contract, so a merge inside the attacker's pool can only ever burn the attacker's own tokens. There
    /// is deliberately no reentrancy guard for this — the reentrancy happens, and reaches nothing.
    function testReentrantMergeCannotBurnAnotherMarketsTokens() public {
        /* Victim market: NO side only, so the victim's pool PHYSICALLY holds N NO tokens that dangle. */
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, N, address(pool));
        vm.prank(ALICE);
        pool.deposit(false, N, ALICE);
        assertEq(ct.balanceOf(address(pool), _honestPid(false)), N, "victim's NO tokens sit in the victim's pool");

        /* Attacker market: same collateral + same conditionId => the SAME ERC-1155 position ids, different account. */
        vm.startPrank(ATTACKER);
        SelfReenteringVault evil = new SelfReenteringVault(address(collateral), ct);
        vm.stopPrank();

        OutcomeYieldPool evilPool = factory.deployPool(IERC4626(address(evil)), conditionId);
        evil.setPool(evilPool);
        assertTrue(
            _poolPositionId(evilPool, false) == _poolPositionId(pool, false), "both markets share the position id"
        );
        assertTrue(address(evilPool) != address(pool), "but not the account that holds it");

        _mintOutcomeTokens(ATTACKER, IERC20(address(collateral)), conditionId, 2 * N, address(evilPool));
        uint256 attackerStart = collateral.balanceOf(ATTACKER);

        vm.startPrank(ATTACKER);
        // Fund the attacker market so it has a real invested position to redeem against.
        evilPool.deposit(true, N, ATTACKER);
        evilPool.deposit(false, N, ATTACKER);

        // Hand the vault the YES leg it will re-deposit during the callback, and let it act for the attacker.
        ct.safeTransferFrom(ATTACKER, address(evil), _honestPid(true), N, "");
        factory.setOperator(address(evil), true);
        evil.arm(N, ATTACKER);

        evil.setPreview(N);
        // The exit delivers nothing and reenters, and the nested merge runs. Whether the attacker's own redeem
        // succeeds or reverts is beside the point and deliberately not asserted: every token it can touch is one the
        // attacker put into their own pool. What matters is what it cannot touch.
        try evilPool.redeem(true, N * 1e6, ATTACKER, ATTACKER) {} catch {}
        vm.stopPrank();

        /* The victim's tokens were never reachable — not restored after the fact, never burned. */
        assertEq(ct.balanceOf(address(pool), _honestPid(false)), N, "victim's NO tokens untouched");
        assertEq(_dangling(pool, false), N, "victim's dangling balance intact");
        assertEq(collateral.balanceOf(ATTACKER), attackerStart, "attacker extracted no collateral");

        /* And the victim can still exit in full. */
        uint256 victimShares = factory.balanceOf(ALICE, _shareId(pool, false));
        vm.prank(ALICE);
        uint256 out = pool.redeem(false, victimShares, ALICE, ALICE);
        assertEq(out, N, "victim redeems their full principal");
    }
}
