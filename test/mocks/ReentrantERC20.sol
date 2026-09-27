// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/// @notice ERC-20 that re-enters a target with arbitrary calldata during transfers.
/// @dev    Test-only.
contract ReentrantERC20 is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    constructor() MockERC20("Reentrant", "RE", 6) { }

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function _reenter() internal {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = target.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _reenter();
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        _reenter();
        return _transfer(from, to, amount);
    }
}
