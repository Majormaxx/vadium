// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Chains
/// @notice Per-chain constants for the deploy scripts. Adding a chain is one entry.
library Chains {
    struct Config {
        uint256 chainId;
        string name;
        address poolManager;
        address stateView;
        address universalRouter;
        address usdc;
        address reactiveCallbackProxy;
    }

    error UnsupportedChain(uint256 chainId);

    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant UNICHAIN = 130;
    uint256 internal constant REACTIVE_LASNA = 5318007;
    uint256 internal constant REACTIVE_MAINNET = 1597;

    /// @dev Sources: developers.uniswap.org/contracts/v4/deployments,
    ///      developers.circle.com/stablecoins/usdc-contract-addresses,
    ///      dev.reactive.network/origins-and-destinations.
    function get(uint256 chainId) internal pure returns (Config memory c) {
        if (chainId == UNICHAIN_SEPOLIA) {
            return Config({
                chainId: UNICHAIN_SEPOLIA,
                name: "Unichain Sepolia",
                poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
                stateView: 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222,
                universalRouter: address(0),
                usdc: 0x31d0220469e10c4E71834a79b1f276d740d3768F,
                reactiveCallbackProxy: 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
            });
        }
        if (chainId == UNICHAIN) {
            return Config({
                chainId: UNICHAIN,
                name: "Unichain",
                poolManager: 0x1F98400000000000000000000000000000000004,
                stateView: 0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2,
                universalRouter: 0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3,
                usdc: 0x078D782b760474a361dDA0AF3839290b0EF57AD6,
                reactiveCallbackProxy: 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
            });
        }
        revert UnsupportedChain(chainId);
    }
}
