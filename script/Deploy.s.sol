// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";

contract Deploy is Script {
    // polymarket conditional tokens address on polygon
    IConditionalTokens constant CONDITIONAL_TOKENS = IConditionalTokens(0x4D97DCd97eC945f40cF65F87097ACe5EA0476045);

    function run() external returns (YieldBearingOutcomeTokens vault) {
        vm.startBroadcast();
        vault = new YieldBearingOutcomeTokens(CONDITIONAL_TOKENS);
        vm.stopBroadcast();
    }
}
