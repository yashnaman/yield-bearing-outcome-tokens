// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {SharesMathLib} from "src/libraries/SharesMathLib.sol";
import {ShareIdLib} from "src/libraries/ShareIdLib.sol";
import {CTHelpers} from "src/vendor/CTHelpers.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {IERC1155TokenReceiver} from "src/interface/IERC1155TokenReceiver.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {IOutcomeYieldPoolFactory} from "src/interface/IOutcomeYieldPoolFactory.sol";

/// @title OutcomeYieldPool
/// @author yashnaman
/// @notice Earns yield on the idle YES/NO outcome tokens of one binary ConditionalTokens market.
/// @dev Rests solely on the par identity `1 YES + 1 NO <-> 1 collateral`, never on market prices, and needs no
/// special handling at resolution: splitting and merging only require the condition to be prepared, not resolved.
/// @dev Holds this market's funds and has no storage of its own — shares are ERC-6909 tokens on the factory, which is
/// the only contract this pool mints or burns against. Deploy through {OutcomeYieldPoolFactory}.
/// @dev See {IOutcomeYieldPool} for the documented surface, and README.md for the design and the accepted risks.
contract OutcomeYieldPool is IOutcomeYieldPool, IERC1155TokenReceiver {
    /* IMMUTABLES & CONSTANTS */

    /// @dev The factory that deployed this pool and holds the ERC-6909 ledger of its shares.
    IOutcomeYieldPoolFactory internal immutable FACTORY;

    /// @dev The ConditionalTokens contract that mints, splits and merges this market's outcome tokens.
    IConditionalTokens internal immutable CONDITIONAL_TOKENS;

    /// @inheritdoc IOutcomeYieldPool
    IERC4626 public immutable YIELD_VAULT;

    /// @inheritdoc IOutcomeYieldPool
    IERC20 public immutable COLLATERAL;

    /// @inheritdoc IOutcomeYieldPool
    bytes32 public immutable CONDITION_ID;

    /// @dev The ConditionalTokens position ids of the two sides, derived once at construction.
    uint256 internal immutable YES_POSITION_ID;

    uint256 internal immutable NO_POSITION_ID;

    /// @dev The factory's ERC-6909 ids of the two sides' shares, cached to avoid recomputing them per call.
    uint256 internal immutable YES_SHARE_ID;

    uint256 internal immutable NO_SHARE_ID;

    /// @dev The parent collection id used for every position. Fixed to zero to restrict the pool to top-level markets,
    /// i.e. positions not nested under another collection.
    bytes32 internal constant PARENT_COLLECTION_ID = bytes32(0);

    /* CONSTRUCTOR */

    /// @param conditionalTokens The ConditionalTokens contract backing this market.
    /// @param yieldVault The ERC-4626 vault merged collateral is invested into; its `asset()` becomes `COLLATERAL`.
    /// @param conditionId The ConditionalTokens condition id of the binary market this pool serves.
    constructor(IConditionalTokens conditionalTokens, IERC4626 yieldVault, bytes32 conditionId) {
        // Checked once here rather than on every deposit. An unprepared condition reports zero slots and fails too.
        require(conditionalTokens.getOutcomeSlotCount(conditionId) == 2, NotBinaryCondition());

        // Read `asset()` exactly once, ever, so no two functions can disagree about which token backs the market. A
        // vault that is its own asset is rejected: its `balanceOf` would mean both "collateral held" and "vault shares
        // held" at once, and the two accounting paths would read each other's balance.
        IERC20 collateral = IERC20(yieldVault.asset());
        require(address(collateral) != address(0) && address(collateral) != address(yieldVault), InvalidCollateral());

        // `getCollectionId` runs a Legendre-symbol square root over the modexp precompile, so hoisting both ids out of
        // the hot paths into construction is the single largest per-call saving in this contract.
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(collateral), CTHelpers.getCollectionId(PARENT_COLLECTION_ID, conditionId, 1)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(collateral), CTHelpers.getCollectionId(PARENT_COLLECTION_ID, conditionId, 2)
        );

        // Both spenders pull this pool's collateral on every merge and split, so approve once instead of per call.
        // Unbounded is safe in a way it would not be in a singleton: the only collateral this contract will ever hold
        // belongs to this one market, whose participants already chose `yieldVault`. Raw approve with a bool check, as
        // ConditionalTokens itself does — a token that does not conform cannot back outcome tokens there either.
        require(collateral.approve(address(conditionalTokens), type(uint256).max), ApproveFailed());
        require(collateral.approve(address(yieldVault), type(uint256).max), ApproveFailed());

        // Binding the ledger to `msg.sender` rather than an argument keeps the init code — and therefore the CREATE2
        // address — independent of the factory. A pool deployed outside a factory binds to whoever deployed it, and so
        // lands at an address `getPoolAddress` never predicts, which is what makes it detectable.
        FACTORY = IOutcomeYieldPoolFactory(msg.sender);
        CONDITIONAL_TOKENS = conditionalTokens;
        YIELD_VAULT = yieldVault;
        COLLATERAL = collateral;
        CONDITION_ID = conditionId;
        YES_POSITION_ID = yesPositionId;
        NO_POSITION_ID = noPositionId;
        YES_SHARE_ID = ShareIdLib.idFor(address(this), true);
        NO_SHARE_ID = ShareIdLib.idFor(address(this), false);
    }

    /* DEPOSIT */

    /// @inheritdoc IOutcomeYieldPool
    function deposit(bool isYes, uint256 assets, address to) external {
        // The pull half of a single deposit path, not a second one: the transfer lands in {onERC1155Received}, which
        // prices and credits it exactly as it would a deposit pushed in unprompted, with `to` riding along in `data`.
        // There is deliberately no `_deposit` call here — that would credit the same tokens twice.
        CONDITIONAL_TOKENS.safeTransferFrom(msg.sender, address(this), _positionId(isYes), assets, abi.encode(to));
    }

    /// @dev Credits a deposit whose outcome tokens have *already* landed in this pool, and rebalances. Reached only
    /// from {onERC1155Received}, so it takes no custody action of its own.
    /// @param caller The account credited as having initiated the deposit, for the event.
    function _deposit(bool isYes, uint256 assets, address caller, address to) internal {
        // Price against the side as it stood *before* these tokens arrived. The dangling balance is the pool's own
        // ConditionalTokens balance, which already includes `assets` by the time this runs, so it must be netted back
        // out or the deposit would be priced against itself.
        uint256 totalAssetsBefore =
            CONDITIONAL_TOKENS.balanceOf(address(this), _positionId(isYes)) - assets + _investedBalance();

        uint256 shares = SharesMathLib.toSharesDown(assets, totalAssetsBefore, FACTORY.totalSupply(_shareId(isYes)));
        FACTORY.mint(to, isYes, shares);

        // Best-effort. The self-call gives the merge and the vault deposit a subframe that rolls back together, so a
        // vault that refuses the deposit defers the merge instead of blocking this one. Nothing needs restoring in the
        // catch: the dangling balances are physical, so the subframe reverting already puts them back.
        try this.mergeAndDeposit() {} catch {}

        emit Deposit(isYes, caller, to, assets, shares);
    }

    /// @inheritdoc IOutcomeYieldPool
    function mergeAndDeposit() external {
        _mergeAndDeposit();
    }

    /// @dev Merges every complete set the pool holds into collateral and invests it. The amount comes from the pool's
    /// own balances, so this needs no arguments and no authorization: the worst a caller can do is merge tokens the
    /// pool already holds, which is what the pool exists to do.
    function _mergeAndDeposit() internal {
        uint256 yesBalance = CONDITIONAL_TOKENS.balanceOf(address(this), YES_POSITION_ID);
        uint256 noBalance = CONDITIONAL_TOKENS.balanceOf(address(this), NO_POSITION_ID);
        uint256 completeSets = yesBalance < noBalance ? yesBalance : noBalance;
        if (completeSets == 0) return;

        // The constructor rejects non-binary conditions, so the `{1},{2}` partition with a zero parent collection pins
        // ConditionalTokens to its `transfer(msg.sender, amount)` branch: the merge always returns exactly
        // `completeSets` of collateral to this contract.
        CONDITIONAL_TOKENS.mergePositions(COLLATERAL, PARENT_COLLECTION_ID, CONDITION_ID, _partition(), completeSets);

        // Deposits `completeSets` rather than the whole collateral balance, so a merge reentered from inside a
        // redemption's vault callback cannot swallow the collateral that redemption is about to split. The minted
        // share count is ignored: the vault rounds it down against the pool, including all the way to zero. See
        // README.md § Accepted risks.
        YIELD_VAULT.deposit(completeSets, address(this));
    }

    /* REDEEM */

    /// @inheritdoc IOutcomeYieldPool
    function redeem(bool isYes, uint256 shares, address onBehalf, address to) external returns (uint256 assets) {
        uint256 id = _positionId(isYes);

        // Each unit of invested collateral splits back into one outcome token of this side, so the side's total assets
        // are its dangling tokens plus the *whole* invested balance.
        uint256 dangling = CONDITIONAL_TOKENS.balanceOf(address(this), id);
        assets = SharesMathLib.toAssetsDown(shares, dangling + _investedBalance(), FACTORY.totalSupply(_shareId(isYes)));

        // The factory owns the ledger, so it also runs the authorization: `msg.sender` is forwarded as the spender and
        // must be `onBehalf`, an operator of `onBehalf`, or hold a sufficient per-id allowance.
        FACTORY.burn(msg.sender, onBehalf, isYes, shares);

        // Only touch the vault when the dangling tokens cannot cover the payout. The counterparty side needs no
        // bookkeeping: `splitPosition` physically mints its tokens, at the instant it mints them.
        if (dangling < assets) _withdrawAndSplit(assets - dangling);

        CONDITIONAL_TOKENS.safeTransferFrom(address(this), to, id, assets, "");

        emit Redeem(isYes, msg.sender, onBehalf, to, shares, assets);
    }

    /// @dev Withdraws exactly `amount` of collateral and splits everything the pool holds into a YES/NO pair. Only
    /// ever reached from a redemption that runs short of dangling tokens.
    function _withdrawAndSplit(uint256 amount) internal {
        // Asking for an exact asset amount burns a `ceil`-rounded share count, leaving up to `assetsPerShare - 1`
        // behind in the vault. See README.md § Accepted risks.
        YIELD_VAULT.withdraw(amount, address(this), address(this));

        // Splits the whole collateral balance, which is this market's by construction, so this can only mint tokens
        // the pool is entitled to. No shortfall check is needed: a vault that under-delivers splits less than `amount`
        // and the caller's trailing `safeTransferFrom` reverts for want of outcome tokens.
        CONDITIONAL_TOKENS.splitPosition(
            COLLATERAL, PARENT_COLLECTION_ID, CONDITION_ID, _partition(), COLLATERAL.balanceOf(address(this))
        );
    }

    /* INTERNAL HELPERS */

    /// @dev The collateral recoverable if the pool's yield-vault position were withdrawn now. Short-circuits on an
    /// empty position, so a redemption needing no vault interaction is never blocked by a vault whose `previewRedeem`
    /// has stopped working.
    function _investedBalance() internal view returns (uint256) {
        uint256 vaultShares = YIELD_VAULT.balanceOf(address(this));
        if (vaultShares == 0) return 0;
        return YIELD_VAULT.previewRedeem(vaultShares);
    }

    /// @dev The ConditionalTokens position id of the given side's outcome token.
    function _positionId(bool isYes) internal view returns (uint256) {
        return isYes ? YES_POSITION_ID : NO_POSITION_ID;
    }

    /// @dev The inverse of {_positionId}: the side whose outcome token has position id `id`. An id this pool does not
    /// serve is rejected rather than assumed to be the other side, so a mistaken transfer can never be credited to
    /// the wrong side, or to a market this pool does not serve.
    function _sideOfPositionId(uint256 id) internal view returns (bool) {
        if (id == YES_POSITION_ID) return true;
        if (id == NO_POSITION_ID) return false;
        revert UnknownPositionId();
    }

    /// @dev The factory's ERC-6909 id of the given side's shares.
    function _shareId(bool isYes) internal view returns (uint256) {
        return isYes ? YES_SHARE_ID : NO_SHARE_ID;
    }

    /// @dev The binary partition every split and merge uses: index set `0b01` (YES) and `0b10` (NO).
    function _partition() internal pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }

    /* ERC-1155 RECEIVER */

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155TokenReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IERC1155TokenReceiver
    /// @dev The only place a deposit is priced and credited, so sending this market's outcome tokens here *is* the
    /// deposit — {deposit}'s own pull arrives like any other transfer, which is why `operator` is ignored. The side is
    /// resolved from `id` by {_sideOfPositionId}; this is the one entry point that cannot take the side as an argument,
    /// because ERC-1155 `safeTransferFrom` has no such parameter. `data` names the account to credit: empty means
    /// `from`, anything else must be a bare `abi.encode(address)`.
    /// @dev The one transfer that must not be credited is the pool sending to itself — a redemption whose `to` is this
    /// pool — because nothing moved, so there is no new backing to price shares against. Those tokens stay dangling,
    /// which is what a redeemer naming the pool asked for. `splitPosition`'s mint arrives as a batch, not here.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4)
    {
        require(msg.sender == address(CONDITIONAL_TOKENS), NotConditionalTokens());

        if (from != address(this)) {
            _deposit(_sideOfPositionId(id), value, from, data.length == 0 ? from : abi.decode(data, (address)));
        }

        return this.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155TokenReceiver
    /// @dev Accepted only from this pool itself, which is how `splitPosition` mints the YES/NO pair back during a
    /// redemption. A batch from anyone else is rejected: it carries both sides at once, and each side is priced
    /// against its own supply, so there is no single deposit it could be credited as. Send one transfer per side.
    function onERC1155BatchReceived(address operator, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(msg.sender == address(CONDITIONAL_TOKENS), NotConditionalTokens());
        require(operator == address(this), BatchDepositNotSupported());

        return this.onERC1155BatchReceived.selector;
    }
}
