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

/// @dev Minimal standalone vault base (the repo mocks are not `virtual`, so they cannot be specialised).
contract BaseVault {
    IERC20 public immutable asset_;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 a) {
        asset_ = a;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function totalAssets() public view returns (uint256) {
        return asset_.balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        uint256 supply = totalSupply;
        shares = supply == 0 ? assets : assets * supply / totalAssets();
        require(asset_.transferFrom(msg.sender, address(this), assets), "pull failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256 shares) {
        uint256 supply = totalSupply;
        shares = supply == 0 ? assets : assets * supply / totalAssets();
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}

/// @notice EIP-4626-correct vault with an EXIT fee: previewRedeem rounds DOWN, previewWithdraw rounds UP.
/// No mock in the repo does this - MockERC4626.withdraw rounds shares down, the opposite of what the EIP
/// mandates, which is exactly why finding 4 is invisible to the existing suite.
contract ExitFeeVault is BaseVault {
    uint256 public constant FEE_BIPS = 1000; // 10%
    constructor(IERC20 a) BaseVault(a) {}

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return super.previewRedeem(shares) * (10_000 - FEE_BIPS) / 10_000; // down
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 gross = (assets * 10_000 + (10_000 - FEE_BIPS) - 1) / (10_000 - FEE_BIPS); // up
        uint256 supply = totalSupply;
        return supply == 0 ? gross : (gross * supply + totalAssets() - 1) / totalAssets(); // up
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}

/// @notice EIP-correct ceil-rounding withdraw at a HIGH assets-per-share. No fee, fully compliant.
contract CeilWithdrawVault is BaseVault {
    constructor(IERC20 a) BaseVault(a) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        uint256 supply = totalSupply;
        shares = supply == 0 ? assets : (assets * supply + totalAssets() - 1) / totalAssets(); // UP, per EIP
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}

/// @notice Silently mints ZERO shares instead of reverting (finding 6). The repo only has a *reverting* one.
contract ZeroShareVault is BaseVault {
    constructor(IERC20 a) BaseVault(a) {}

    function deposit(uint256 assets, address) public override returns (uint256) {
        require(asset_.transferFrom(msg.sender, address(this), assets), "pull failed");
        return 0; // takes the collateral, books nothing
    }
}

/// @notice A vault that becomes uncallable after the fact (finding 8).
contract BreakableVault is BaseVault {
    bool public broken;
    constructor(IERC20 a) BaseVault(a) {}

    function breakIt() external {
        broken = true;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        require(!broken, "vault dead");
        return super.previewRedeem(shares);
    }
}

contract RemainingFindingsTest is Test {
    bytes32 constant PARENT = bytes32(0);

    ICTExt ct;
    MockERC20 token;
    YieldBearingOutcomeTokens ybot;
    address ALICE = makeAddr("Alice");
    address ORACLE = makeAddr("Oracle");
    bytes32 cond;

    function _p2() internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
    }

    function setUp() public {
        ct = ICTExt(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
        token = new MockERC20("TKN", "TKN");
        ybot = new YieldBearingOutcomeTokens(IConditionalTokens(address(ct)));
        ct.prepareCondition(ORACLE, keccak256("c"), 2);
        cond = ct.getConditionId(ORACLE, keccak256("c"), 2);
    }

    function _mintAndApprove(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(token)), PARENT, cond, _p2(), amount);
        ct.setApprovalForAll(address(ybot), true);
        vm.stopPrank();
    }

    /* ---- FINDING 4: previewRedeem(down) prices it, previewWithdraw(up) liquidates it ---- */
    function test_finding4_exitFeeVaultUnderflowsVaultSharesOf() public {
        ExitFeeVault v = new ExitFeeVault(IERC20(address(token)));
        uint256 N = 1_000e6;
        _mintAndApprove(ALICE, N);

        vm.startPrank(ALICE);
        uint256 shYes = ybot.deposit(IERC4626(address(v)), cond, true, N, ALICE);
        ybot.deposit(IERC4626(address(v)), cond, false, N, ALICE);
        vm.stopPrank();

        bytes32 id = keccak256(abi.encodePacked(address(v), address(token), cond));
        console2.log("booked vault shares:", ybot.vaultSharesOf(id));
        console2.log("invested balance (previewRedeem, down):", ybot.investedBalance(IERC4626(address(v)), cond));

        vm.prank(ALICE);
        (bool ok1,) =
            address(ybot).call(abi.encodeCall(ybot.redeem, (IERC4626(address(v)), cond, true, shYes, ALICE, ALICE)));
        console2.log("YES-side full redeem ok?", ok1);
        console2.log("  vaultSharesOf after:  ", ybot.vaultSharesOf(id));
        console2.log("  invested balance after:", ybot.investedBalance(IERC4626(address(v)), cond));
        console2.log("  NO dangling after:    ", ybot.danglingBalance(IERC4626(address(v)), cond, false));

        uint256 shNo = ybot.totalShares(IERC4626(address(v)), cond, false);
        vm.prank(ALICE);
        (bool ok2,) =
            address(ybot).call(abi.encodeCall(ybot.redeem, (IERC4626(address(v)), cond, false, shNo, ALICE, ALICE)));
        console2.log("NO-side full redeem ok?", ok2);

        uint256 recovered =
            ct.balanceOf(ALICE, ct.getPositionId(IERC20(address(token)), ct.getCollectionId(PARENT, cond, 1)));
        console2.log("Alice YES tokens back (deposited 1000e6):", recovered);
        console2.log("stranded shares still booked:", ybot.vaultSharesOf(id));
        console2.log("vault actually still holds: ", v.balanceOf(address(ybot)));
        // NOT REPRODUCED: finding 4(a)'s underflow DoS. Both sides exit cleanly; Alice absorbs the 10% fee.
        assertTrue(ok1 && ok2, "both sides exit a fee vault cleanly");
        assertEq(recovered, 900e6, "depositor absorbs the fee, as the design intends");
    }

    /* ---- FINDING 4(b): ceil-rounded share burn strands value, double-counted across both sides ---- */
    function test_finding4b_highSharePriceStrandsValue() public {
        CeilWithdrawVault v = new CeilWithdrawVault(IERC20(address(token)));

        // Seed an assets-per-share of 1e9: 1 share outstanding backed by 1e9 assets.
        token.mint(address(this), 1e9);
        token.approve(address(v), 1);
        v.deposit(1, address(this));
        token.mint(address(v), 1e9 - 1); // donation lifts the price

        uint256 N = 3e9;
        _mintAndApprove(ALICE, N);
        vm.startPrank(ALICE);
        uint256 shYes = ybot.deposit(IERC4626(address(v)), cond, true, N, ALICE);
        ybot.deposit(IERC4626(address(v)), cond, false, N, ALICE);
        vm.stopPrank();

        bytes32 id = keccak256(abi.encodePacked(address(v), address(token), cond));
        uint256 before = ybot.investedBalance(IERC4626(address(v)), cond);
        console2.log("vaultSharesOf booked:", ybot.vaultSharesOf(id));
        console2.log("invested balance before:", before);

        // Redeem a dust amount: one share must be burned to deliver it.
        vm.prank(ALICE);
        uint256 got = ybot.redeem(IERC4626(address(v)), cond, true, shYes / 1e9, ALICE, ALICE);

        uint256 remaining = ybot.investedBalance(IERC4626(address(v)), cond);
        console2.log("outcome tokens received:", got);
        console2.log("vaultSharesOf after:    ", ybot.vaultSharesOf(id));
        console2.log("invested balance after: ", remaining);
        console2.log("side-value destroyed (x2, both sides share it):", (before - remaining) * 2);
        // OPEN: finding 4(b) reproduces. Withdrawing 3 units destroys a third of the market's invested value.
        assertGt((before - remaining), got * 1e8, "ceil-rounded share burn strands value");
    }

    /* ---- FINDING 6: silent zero-share deposit ---- */
    function test_finding6_zeroShareDepositBricksMarket() public {
        ZeroShareVault v = new ZeroShareVault(IERC20(address(token)));
        uint256 N = 1_000e6;
        _mintAndApprove(ALICE, N);

        vm.startPrank(ALICE);
        uint256 shYes = ybot.deposit(IERC4626(address(v)), cond, true, N, ALICE);
        ybot.deposit(IERC4626(address(v)), cond, false, N, ALICE);
        vm.stopPrank();

        bytes32 id = keccak256(abi.encodePacked(address(v), address(token), cond));
        console2.log("collateral now inside the vault:", token.balanceOf(address(v)));
        console2.log("vaultSharesOf (credited):       ", ybot.vaultSharesOf(id));
        console2.log("YES dangling:                   ", ybot.danglingBalance(IERC4626(address(v)), cond, true));
        console2.log("YES totalShares:                ", ybot.totalShares(IERC4626(address(v)), cond, true));

        vm.prank(ALICE);
        uint256 out = ybot.redeem(IERC4626(address(v)), cond, true, shYes, ALICE, ALICE);
        console2.log("Alice deposited", N, "and redeemed:", out);
        // OPEN: finding 6. Total loss - the collateral is in the vault, credited to nobody.
        assertEq(out, 0, "depositor loses everything to a silent zero-share deposit");
        assertEq(token.balanceOf(address(v)), N, "collateral is in the vault, unclaimable");
    }

    /* ---- FINDING 8: redemption coupled to vault callability even with nothing invested ---- */
    function test_finding8_danglingOnlyRedeemBlockedByDeadVault() public {
        BreakableVault v = new BreakableVault(IERC20(address(token)));
        uint256 N = 1_000e6;
        _mintAndApprove(ALICE, N);

        vm.prank(ALICE);
        uint256 shYes = ybot.deposit(IERC4626(address(v)), cond, true, N, ALICE); // YES only -> pure dangling

        bytes32 id = keccak256(abi.encodePacked(address(v), address(token), cond));
        assertEq(ybot.vaultSharesOf(id), 0, "nothing invested");
        assertEq(
            ct.balanceOf(address(ybot), ct.getPositionId(IERC20(address(token)), ct.getCollectionId(PARENT, cond, 1))),
            N,
            "tokens physically held"
        );

        v.breakIt();

        vm.prank(ALICE);
        (bool ok,) =
            address(ybot).call(abi.encodeCall(ybot.redeem, (IERC4626(address(v)), cond, true, shYes, ALICE, ALICE)));
        console2.log("pure-dangling redeem succeeded?", ok);
        assertFalse(ok, "finding 8 still applies: tokens are held but unreachable");
    }
}
