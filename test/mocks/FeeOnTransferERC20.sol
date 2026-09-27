// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/// @notice ERC-20 that burns 1% on every transfer. Test-only.
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("FeeOnTransfer", "FOT", 6) { }

    function _transfer(address from, address to, uint256 amount) internal override returns (bool) {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        return true;
    }
}
