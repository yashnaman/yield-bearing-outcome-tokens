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
    function prepareCondition(address o, bytes32 q, uint256 n) external;
    function getConditionId(address o, bytes32 q, uint256 n) external pure returns (bytes32);
    function getCollectionId(bytes32 p, bytes32 c, uint256 i) external view returns (bytes32);
    function getPositionId(IERC20 col, bytes32 cid) external pure returns (uint256);
    function setApprovalForAll(address op, bool ok) external;
}

/// @notice Reenters `deposit` on ITS OWN market from inside `withdraw`, so the nested merge is charged to the
/// phantom `danglingBalance` the outer `redeem` credited before minting (audit finding 11) while it physically
/// burns the VICTIM market's outcome tokens out of the shared ERC-1155 pool.
contract PhantomVault {
    address public immutable assetAddr;
    YieldBearingOutcomeTokens public immutable YBOT;
    ICTExt public immutable CT;

    bytes32 public cond;
    uint256 public amt;
    address public beneficiary;
    uint256 public previewValue;
    bool public armed;

    constructor(address a, YieldBearingOutcomeTokens y, ICTExt c) {
        assetAddr = a;
        YBOT = y;
        CT = c;
    }

    function arm(bytes32 co, uint256 m, address b) external {
        cond = co;
        amt = m;
        beneficiary = b;
        armed = true;
        passive = true;
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
    bool public passive; // once armed, stop pulling so the nested merge's collateral stays in ybot

    function deposit(uint256 assets, address) external returns (uint256) {
        if (passive) return assets;
        IERC20(assetAddr).transferFrom(msg.sender, address(this), assets);
        return assets;
    }

    function withdraw(uint256, address, address) external returns (uint256) {
        if (armed) {
            armed = false;
            // Deposit the YES leg into THIS SAME market. The NO leg's dangling is the phantom the outer redeem
            // just credited, so completeSets == amt and mergePositions burns the victim's physical NO tokens.
            YBOT.deposit(IERC4626(address(this)), cond, true, amt, beneficiary);
        }
        return 0; // delivers nothing
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

contract PhantomDanglingPoC is Test {
    bytes32 constant PARENT = bytes32(0);

    ICTExt ct;
    MockERC20 token; // plain ERC20 collateral, shared by victim + attacker markets
    MockERC4626 victimVault;
    YieldBearingOutcomeTokens ybot;

    address VICTIM = makeAddr("Victim");
    address ATTACKER = makeAddr("Attacker");
    address ORACLE = makeAddr("Oracle");
    bytes32 cond;

    uint256 constant N = 1_000e6;

    function _p2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
    }

    function _pid(uint256 i) internal view returns (uint256) {
        return ct.getPositionId(IERC20(address(token)), ct.getCollectionId(PARENT, cond, i));
    }

    function setUp() public {
        ct = ICTExt(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
        token = new MockERC20("TKN", "TKN");
        victimVault = new MockERC4626(IERC20(address(token)));
        ybot = new YieldBearingOutcomeTokens(IConditionalTokens(address(ct)));
        ct.prepareCondition(ORACLE, keccak256("c"), 2);
        cond = ct.getConditionId(ORACLE, keccak256("c"), 2);
    }

    function _mint(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(token)), PARENT, cond, _p2(), amount);
        ct.setApprovalForAll(address(ybot), true);
        vm.stopPrank();
    }

    function test_phantomDanglingMergeIsBlockedByGuard() public {
        /* Victim market: NO side only, so ybot PHYSICALLY holds N NO tokens that dangle. */
        _mint(VICTIM, N);
        vm.prank(VICTIM);
        ybot.deposit(IERC4626(address(victimVault)), cond, false, N, VICTIM);
        assertEq(ct.balanceOf(address(ybot), _pid(2)), N, "victim's NO tokens sit in ybot");

        /* Attacker market: same collateral + same conditionId => SHARED ERC-1155 pool. */
        vm.startPrank(ATTACKER);
        PhantomVault evil = new PhantomVault(address(token), ybot, ct);
        vm.stopPrank();

        _mint(ATTACKER, 2 * N);
        uint256 attackerStart = token.balanceOf(ATTACKER);

        vm.startPrank(ATTACKER);
        // Fund the attacker market so it has a real invested position to redeem against.
        ybot.deposit(IERC4626(address(evil)), cond, true, N, ATTACKER);
        ybot.deposit(IERC4626(address(evil)), cond, false, N, ATTACKER);

        // Hand the vault the YES leg it will re-deposit during the callback.
        ct.safeTransferFrom(ATTACKER, address(evil), _pid(1), N, "");
        evil.arm(cond, N, ATTACKER);

        evil.setPreview(N);
        vm.expectRevert(YieldBearingOutcomeTokens.ReentrantCall.selector);
        ybot.redeem(IERC4626(address(evil)), cond, true, N * 1e6, ATTACKER, ATTACKER);
        vm.stopPrank();

        console2.log("victim NO tokens physically in ybot:", ct.balanceOf(address(ybot), _pid(2)));
        console2.log(
            "victim ledger dangling NO:          ", ybot.danglingBalance(IERC4626(address(victimVault)), cond, false)
        );
        console2.log("attacker token balance start:", attackerStart);
        console2.log("attacker token balance now:  ", token.balanceOf(ATTACKER));
        console2.log("attacker YES held:", ct.balanceOf(ATTACKER, _pid(1)));
        console2.log("attacker NO  held:", ct.balanceOf(ATTACKER, _pid(2)));
        console2.log("evil vault token balance:", token.balanceOf(address(evil)));
        console2.log("ybot token balance:      ", token.balanceOf(address(ybot)));

        // The victim's tokens are never burned in the first place now -- no longer a restoration accident.
        assertEq(ct.balanceOf(address(ybot), _pid(2)), N, "victim's NO tokens untouched");
        assertEq(ybot.danglingBalance(IERC4626(address(victimVault)), cond, false), N, "victim ledger intact");
    }
}
