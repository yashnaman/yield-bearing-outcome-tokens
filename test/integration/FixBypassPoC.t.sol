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
    function prepareCondition(address oracle, bytes32 q, uint256 n) external;
    function getConditionId(address oracle, bytes32 q, uint256 n) external pure returns (bytes32);
    function getCollectionId(bytes32 p, bytes32 c, uint256 i) external view returns (bytes32);
    function getPositionId(IERC20 col, bytes32 cid) external pure returns (uint256);
    function setApprovalForAll(address op, bool ok) external;
}

/// @notice Vault B: books shares but never pulls the collateral, keeping the `approve` allowance alive.
contract PassiveVault {
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

    function deposit(uint256 assets, address) external pure returns (uint256) {
        return assets; // pulls NOTHING
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    /// @notice Exercise the never-revoked allowance from audit finding 7.
    function drain(address ybot, uint256 amt, address to) external {
        IERC20(assetAddr).transferFrom(ybot, to, amt);
    }
}

/// @notice Vault A: reenters `deposit` from inside `withdraw` so vault B's merge inflates A's balance delta.
contract ReenteringVault {
    address public immutable assetAddr;
    YieldBearingOutcomeTokens public immutable YBOT;
    ICTExt public immutable CT;

    address public passive;
    bytes32 public cond;
    uint256 public amt;
    address public beneficiary;
    uint256 public previewValue;
    bool armed;

    constructor(address a, YieldBearingOutcomeTokens y, ICTExt c) {
        assetAddr = a;
        YBOT = y;
        CT = c;
    }

    function arm(address p, bytes32 co, uint256 m, address b) external {
        passive = p;
        cond = co;
        amt = m;
        beneficiary = b;
        armed = true;
        CT.setApprovalForAll(address(YBOT), true);
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
        IERC20(assetAddr).transferFrom(msg.sender, address(this), assets); // pulls honestly
        return assets;
    }

    function withdraw(uint256, address, address) external returns (uint256) {
        if (armed) {
            armed = false;
            // Nested merge on market B delivers `amt` collateral into ybot -> satisfies the OUTER delta check,
            // while B's `approve(passive, amt)` allowance is left entirely unspent.
            YBOT.deposit(IERC4626(passive), cond, false, amt, beneficiary);
        }
        return 0; // delivers nothing itself
    }

    function sweep(address to) external {
        IERC20(assetAddr).transfer(to, IERC20(assetAddr).balanceOf(address(this)));
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}

contract FixBypassPoC is Test {
    bytes32 constant PARENT = bytes32(0);

    ICTExt ct;
    MockERC20 usdc;
    MockERC4626 genuineVault;
    YieldBearingOutcomeTokens ybot;

    address ALICE = makeAddr("Alice");
    address ATTACKER = makeAddr("Attacker");
    address ORACLE = makeAddr("Oracle");

    bytes32 legitCondition;
    bytes32 attackCondition;

    uint256 constant N = 1_000e6;

    function _p2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
    }

    function setUp() public {
        ct = ICTExt(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
        usdc = new MockERC20("USDC", "USDC");
        genuineVault = new MockERC4626(IERC20(address(usdc)));
        ybot = new YieldBearingOutcomeTokens(IConditionalTokens(address(ct)));

        ct.prepareCondition(ORACLE, keccak256("legit"), 2);
        legitCondition = ct.getConditionId(ORACLE, keccak256("legit"), 2);
        ct.prepareCondition(ORACLE, keccak256("attack"), 2);
        attackCondition = ct.getConditionId(ORACLE, keccak256("attack"), 2);
    }

    function test_reentrantDeltaInflationIsBlockedByGuard() public {
        /* ---- Alice: honest market, ybot ends up holding N genuineVault SHARES ---- */
        usdc.mint(ALICE, N);
        vm.startPrank(ALICE);
        usdc.approve(address(ct), N);
        ct.splitPosition(IERC20(address(usdc)), PARENT, legitCondition, _p2(), N);
        ct.setApprovalForAll(address(ybot), true);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, true, N, ALICE);
        ybot.deposit(IERC4626(address(genuineVault)), legitCondition, false, N, ALICE);
        vm.stopPrank();
        assertEq(genuineVault.balanceOf(address(ybot)), N, "ybot holds Alice's shares");

        /* ---- Attacker setup: two fake vaults whose asset() is the genuine SHARE token ---- */
        vm.startPrank(ATTACKER);
        ReenteringVault vaultA = new ReenteringVault(address(genuineVault), ybot, ct);
        PassiveVault vaultB = new PassiveVault(address(genuineVault));

        usdc.mint(ATTACKER, 2 * N);
        usdc.approve(address(genuineVault), 2 * N);
        genuineVault.deposit(2 * N, ATTACKER);
        uint256 attackerStart = genuineVault.balanceOf(ATTACKER);

        genuineVault.approve(address(ct), 2 * N);
        ct.splitPosition(IERC20(address(genuineVault)), PARENT, attackCondition, _p2(), 2 * N);
        ct.setApprovalForAll(address(ybot), true);

        // Market A funded honestly (vaultA really pulls the N).
        ybot.deposit(IERC4626(address(vaultA)), attackCondition, true, N, ATTACKER);
        ybot.deposit(IERC4626(address(vaultA)), attackCondition, false, N, ATTACKER);
        assertEq(genuineVault.balanceOf(address(ybot)), N, "back to just Alice's shares");

        // Market B: YES side only, so its merge fires later from inside the callback.
        ybot.deposit(IERC4626(address(vaultB)), attackCondition, true, N, ATTACKER);

        // Hand vaultA the NO tokens it will deposit into B during the reentrancy.
        ct.safeTransferFrom(ATTACKER, address(vaultA), _pid(2), N, "");
        vaultA.arm(address(vaultB), attackCondition, N, ATTACKER);

        /* ---- The attack: redeem A; A's withdraw delivers nothing, B's nested merge covers the delta ---- */
        vaultA.setPreview(N);
        vm.expectRevert(YieldBearingOutcomeTokens.ReentrantCall.selector);
        ybot.redeem(IERC4626(address(vaultA)), attackCondition, true, N * 1e6, ATTACKER, ATTACKER);
        vm.stopPrank();

        // Nothing moved: the nested deposit can no longer manufacture the outer balance delta.
        assertEq(genuineVault.allowance(address(ybot), address(vaultB)), 0, "no standing allowance");
        assertEq(genuineVault.balanceOf(address(ybot)), N, "Alice's principal intact");
        assertEq(genuineVault.balanceOf(address(vaultB)), 0, "passive vault got nothing");
        assertEq(attackerStart, 2 * N, "attacker only ever fronted its own capital");
    }

    function _pid(uint256 indexSet) internal view returns (uint256) {
        return ct.getPositionId(IERC20(address(genuineVault)), ct.getCollectionId(PARENT, attackCondition, indexSet));
    }
}
