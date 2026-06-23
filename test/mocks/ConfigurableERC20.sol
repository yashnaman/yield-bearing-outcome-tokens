// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

/// @notice A MockERC20 whose `transfer`/`approve` can be made to return `false` for a specific caller, used to cover
/// the vault's raw-bool failure paths (`TransferFailed` / `ApproveFailed`). Keying on `msg.sender` lets the same token
/// keep working for ConditionalTokens' collateral transfers and users' approvals while only the vault's call fails.
contract ConfigurableERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev If non-zero, `transfer` returns false (a no-op) when called by this address.
    address public transferRevertsFor;
    /// @dev If non-zero, `approve` returns false (a no-op) when called by this address.
    address public approveRevertsFor;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function setTransferRevertsFor(address caller) external {
        transferRevertsFor = caller;
    }

    function setApproveRevertsFor(address caller) external {
        approveRevertsFor = caller;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (msg.sender == approveRevertsFor) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender == transferRevertsFor) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
