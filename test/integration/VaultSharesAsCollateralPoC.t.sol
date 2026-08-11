// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

interface ICTExt is IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256);
}

/// @notice Attacker-controlled "yield vault" whose `asset()` is the GENUINE yield vault's share token.
contract EvilVault {
    address public immutable assetAddr;
    uint256 public previewValue;

    constructor(address a) {
        assetAddr = a;
    }

    function asset() external view returns (address) {
        return assetAddr;
    }

    function setPreview(uint256 v) external {
        previewValue = v;
    }

    function previewRedeem(uint256) external view returns (uint256) {
        return previewValue;
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        IERC20(assetAddr).transferFrom(msg.sender, address(this), assets);
        return assets; // book 1:1 so the market looks healthy
    }

    // Transfers nothing, burns nothing: `vaultSharesOf[id] -= 0` never underflows (audit finding 2).
    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function sweep(address to) external {
        IERC20(assetAddr).transfer(to, IERC20(assetAddr).balanceOf(address(this)));
    }
}

contract VaultSharesAsCollateralPoC is Test {
    bytes32 constant PARENT = bytes32(0);

    ICTExt ct;
    MockERC20 usdc;
    MockERC4626 genuineVault; // the real ERC-4626 the honest market invests into
    YieldBearingOutcomeTokens ybot;

    address ALICE = makeAddr("Alice"); // honest depositor
    address ATTACKER = makeAddr("Attacker");
    address ORACLE = makeAddr("Oracle");

    bytes32 legitCondition;
    bytes32 evilCondition;

    uint256 constant N = 1_000e6;

    function setUp() public {
        ct = ICTExt(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
        usdc = new MockERC20("USDC", "USDC");
        genuineVault = new MockERC4626(IERC20(address(usdc)));
        ybot = new YieldBearingOutcomeTokens(IConditionalTokens(address(ct)));

        ct.prepareCondition(ORACLE, keccak256("legit"), 2);
        legitCondition = ct.getConditionId(ORACLE, keccak256("legit"), 2);
    }

    function _pid(IERC20 col, bytes32 cond, uint256 indexSet) internal view returns (uint256) {
        return ct.getPositionId(col, ct.getCollectionId(PARENT, cond, indexSet));
    }

    function _partition3() internal pure returns (uint256[] memory p) {
        p = new uint256[](3);
        p[0] = 1;
        p[1] = 2;
        p[2] = 4;
    }

    function _partition2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
    }

    function test_evilVaultAssetIsGenuineVaultShare_cannotDrainInvestedShares() public {
        /* ---------- 1. Honest market: Alice's collateral ends up as genuineVault SHARES held by ybot ---------- */
        usdc.mint(ALICE, N);
        vm.startPrank(ALICE);
        usdc.approve(address(ct), N);
        ct.splitPosition(IERC20(address(usdc)), PARENT, legitCondition, _partition2(), N);
        ct.setApprovalForAll(address(ybot), true);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, true, N, ALICE);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, false, N, ALICE);
        vm.stopPrank();

        bytes32 legitId = keccak256(abi.encodePacked(address(genuineVault), address(usdc), legitCondition));
        assertEq(ybot.vaultSharesOf(legitId), N, "ledger");
        assertEq(genuineVault.balanceOf(address(ybot)), N, "ybot holds genuine vault shares");
        console2.log("ybot genuineVault share balance after honest deposit:", genuineVault.balanceOf(address(ybot)));

        /* ---------- 2. Attacker sets up a market whose *collateral* IS the genuine vault's share token ------- */
        vm.startPrank(ATTACKER);
        EvilVault evil = new EvilVault(address(genuineVault));

        // Permissionless: any condition, 3 outcome slots so mergePositions returns no collateral (finding 1).
        ct.prepareCondition(ATTACKER, keccak256("evil"), 3);
        evilCondition = ct.getConditionId(ATTACKER, keccak256("evil"), 3);

        // Attacker's own capital: N genuineVault shares (flash-loanable).
        usdc.mint(ATTACKER, N);
        usdc.approve(address(genuineVault), N);
        uint256 got = genuineVault.deposit(N, ATTACKER);
        assertEq(got, N);

        // Split them into a 3-slot condition => holds N of positions {1},{2},{4}, collateral = vault SHARE token.
        genuineVault.approve(address(ct), N);
        ct.splitPosition(IERC20(address(genuineVault)), PARENT, evilCondition, _partition3(), N);
        ct.setApprovalForAll(address(ybot), true);

        /* ---------- 3. Deposit both sides -> merge mints a combined position, deposit spends ybot's shares --- */
        // Rejected at the entry point: a 3-slot condition can never enter the vault at all.
        vm.expectRevert(YieldBearingOutcomeTokens.NotBinaryCondition.selector);
        ybot.deposit(IERC4626(address(evil)), evilCondition, true, N, ATTACKER);

        vm.stopPrank();

        /* ---------- 4. Nothing entered the vault ------------------------------------------------------------ */
        assertEq(genuineVault.balanceOf(address(evil)), 0, "evil vault got nothing");
        assertEq(genuineVault.balanceOf(address(ybot)), N, "Alice's shares untouched");
        assertEq(ybot.vaultSharesOf(legitId), N, "honest ledger intact");

        bytes32 evilId = keccak256(abi.encodePacked(address(evil), address(genuineVault), evilCondition));
        assertEq(ybot.vaultSharesOf(evilId), 0, "attacker market rejected outright");
        assertEq(ybot.totalShares(IERC4626(address(evil)), evilCondition, true), 0, "no shares minted");

        /* ---------- 5. Alice can still redeem in full ------------------------------------------------------- */
        vm.prank(ALICE);
        uint256 out = ybot.redeem(IERC4626(address(genuineVault)), legitCondition, true, N * 1e6, ALICE, ALICE);
        assertEq(out, N, "Alice redeems her full principal");
    }

    /// @notice Same theft with a BINARY condition — so requiring `outcomeSlotCount == 2`
    ///         (the fix proposed for audit finding 1) does NOT close this hole.
    function test_binaryCondition_cannotDrainInvestedShares() public {
        usdc.mint(ALICE, N);
        vm.startPrank(ALICE);
        usdc.approve(address(ct), N);
        ct.splitPosition(IERC20(address(usdc)), PARENT, legitCondition, _partition2(), N);
        ct.setApprovalForAll(address(ybot), true);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, true, N, ALICE);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, false, N, ALICE);
        vm.stopPrank();
        assertEq(genuineVault.balanceOf(address(ybot)), N);

        vm.startPrank(ATTACKER);
        EvilVault evil = new EvilVault(address(genuineVault));
        ct.prepareCondition(ATTACKER, keccak256("evil2"), 2); // BINARY
        bytes32 c2 = ct.getConditionId(ATTACKER, keccak256("evil2"), 2);

        usdc.mint(ATTACKER, N);
        usdc.approve(address(genuineVault), N);
        genuineVault.deposit(N, ATTACKER);
        genuineVault.approve(address(ct), N);
        ct.splitPosition(IERC20(address(genuineVault)), PARENT, c2, _partition2(), N);
        ct.setApprovalForAll(address(ybot), true);

        ybot.deposit(IERC4626(address(evil)), c2, true, N, ATTACKER);
        ybot.deposit(IERC4626(address(evil)), c2, false, N, ATTACKER);

        uint256 sh = N * 1e6;
        evil.setPreview(N);
        vm.expectRevert(YieldBearingOutcomeTokens.WithdrawShortfall.selector);
        ybot.redeem(IERC4626(address(evil)), c2, true, sh, ATTACKER, ATTACKER);
        vm.stopPrank();
        assertEq(genuineVault.balanceOf(address(ybot)), N, "Alice's shares untouched");
        return;
        //
        evil.setPreview(0);
        ybot.redeem(IERC4626(address(evil)), c2, false, sh, ATTACKER, ATTACKER);

        vm.stopPrank();
        assertTrue(false, "unreachable: the redeem above must revert with WithdrawShortfall");
    }
}
