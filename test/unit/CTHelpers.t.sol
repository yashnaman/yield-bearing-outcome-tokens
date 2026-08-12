// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CTHelpers} from "src/vendor/CTHelpers.sol";

/// @dev The id-derivation surface of the real ConditionalTokens, which is the oracle these tests measure against.
interface ICTIds {
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256);
}

/// @notice The vendored {CTHelpers} must agree with the real Gnosis ConditionalTokens, exactly.
/// @dev This is the check that matters most about the vendored code and the one thing it is used for: the pool derives
/// both of its position ids through `CTHelpers` at construction, and then addresses real ERC-1155 balances with them.
/// A disagreement would not revert — it would silently point the pool at position ids nobody holds, so every deposit
/// would credit shares against a balance that never moves.
///
/// @dev This test replaces `invariant_danglingMatchesHeldTokens`, which is what that invariant actually verified
/// despite its name. It asserted `pool.danglingBalance(isYes) == ct.balanceOf(pool, <id derived through ct>)`, and
/// `danglingBalance` was itself `ct.balanceOf(address(this), <id derived through CTHelpers>)` — so the balances on both
/// sides were the same call, and the only thing under test was that the two id derivations agreed. Stated directly it
/// needs no pool, no fixture and no invariant campaign, and it covers inputs a campaign would never reach.
contract CTHelpersTest is Test {
    ICTIds internal ct;

    function setUp() public {
        ct = ICTIds(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
    }

    /// @dev Both binary index sets, over a fuzzed condition and collateral.
    function testMatchesConditionalTokensForBinaryPositions(bytes32 conditionId, address collateral) public view {
        _assertAgrees(conditionId, collateral, 1); // YES
        _assertAgrees(conditionId, collateral, 2); // NO
    }

    /// @dev Index sets beyond the binary pair, since `getCollectionId` is general and the vendored copy must not have
    /// diverged for inputs this protocol does not itself use.
    function testMatchesConditionalTokensForWiderIndexSets(bytes32 conditionId, address collateral) public view {
        for (uint256 indexSet = 1; indexSet <= 8; ++indexSet) {
            _assertAgrees(conditionId, collateral, indexSet);
        }
    }

    /// @dev The edge inputs a fuzzer is unlikely to produce.
    function testMatchesConditionalTokensAtEdges() public view {
        bytes32[3] memory conditions = [bytes32(0), bytes32(type(uint256).max), keccak256("condition")];
        address[3] memory collaterals = [address(0), address(type(uint160).max), address(uint160(1))];

        for (uint256 i; i < conditions.length; ++i) {
            for (uint256 j; j < collaterals.length; ++j) {
                _assertAgrees(conditions[i], collaterals[j], 1);
                _assertAgrees(conditions[i], collaterals[j], 2);
            }
        }
    }

    function _assertAgrees(bytes32 conditionId, address collateral, uint256 indexSet) internal view {
        bytes32 mine = CTHelpers.getCollectionId(bytes32(0), conditionId, indexSet);
        bytes32 theirs = ct.getCollectionId(bytes32(0), conditionId, indexSet);
        assertEq(mine, theirs, "collection id diverges from ConditionalTokens");

        assertEq(
            CTHelpers.getPositionId(collateral, mine),
            ct.getPositionId(IERC20(collateral), theirs),
            "position id diverges from ConditionalTokens"
        );
    }
}
