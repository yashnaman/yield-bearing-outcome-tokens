// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity ^0.5.1;

// This file exists only to force Foundry to compile the real Gnosis ConditionalTokens
// contract (Solidity 0.5.x) so the 0.8 test can deploy it via `vm.deployCode`.
import "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
