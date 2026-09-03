// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {VadiumHook} from "../../src/core/VadiumHook.sol";

/// @title DeployVadium
/// @notice Deploys VadiumHook to Unichain Sepolia (chain ID 1301) and creates the
///         Vadium pool.
///
/// @dev    Deployment order:
///           1. Mine a CREATE2 salt so VadiumHook lands at an address whose lower
///              14 bits match the required hook permission flags (beforeSwap, afterSwap).
///           2. Deploy VadiumHook at the mined address (builds its own PoolKey with
///              `hooks = address(this)`).
///           3. Initialize the pool with the static 30 bps fee.
///
///         Pool: ETH (native, token0) / USDC (token1). The bond is denominated in
///         token1 (USDC), which makes the slash → donate path oracle-free.
///
///         Run with:
///           forge script app/script/Deploy.s.sol:DeployVadium \
///             --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
///             --broadcast -vvvv
///
/// @custom:chain  Unichain Sepolia — chain ID 1301
contract DeployVadium is Script {
    // -------------------------------------------------------------------------
    // Unichain Sepolia addresses
    // -------------------------------------------------------------------------

    // Uniswap v4 PoolManager (Unichain Sepolia, chain ID 1301)
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    // USDC — the pool's token1 and the bond denomination
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    // Reactive Network Callback Proxy (Unichain Sepolia, chain ID 1301)
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    // Initial pool sqrtPrice: tick 0 = 1:1
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;

    // Pool fee — static 30 bps (0.30%). Bonded searchers pay this minus the discount
    // via the beforeSwap fee override; unbonded searchers pay it in full.
    uint24 constant POOL_FEE = 3000;

    // -------------------------------------------------------------------------
    // Hook permission flags (must match VadiumHook.getHookPermissions())
    // -------------------------------------------------------------------------

    // beforeSwap = 1 << 7 = 0x0080
    // afterSwap  = 1 << 6 = 0x0040
    uint160 constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------

    function run() external {
        require(block.chainid == 1301, "Deploy: wrong chain - expected Unichain Sepolia (1301)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Vadium deployment ===");
        console2.log("Deployer:     ", deployer);
        console2.log("PoolManager:  ", POOL_MANAGER);

        // ── 1. Mine CREATE2 salt for the hook's permission bits ──────────────
        // The PoolKey is built inside the hook constructor with `hooks = address(this)`,
        // so the creation code only needs the scalars — the mined address is stable.
        bytes memory hookCreationCode = abi.encodePacked(
            type(VadiumHook).creationCode,
            abi.encode(
                IPoolManager(POOL_MANAGER),
                Currency.wrap(address(0)), // native ETH — token0
                Currency.wrap(USDC), // token1 — the bond token
                POOL_FEE,
                10,
                deployer, // owner — must be the EOA, not the CREATE2 factory
                CALLBACK_PROXY // Reactive Callback Proxy on Unichain Sepolia
            )
        );

        address foundryCreate2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        bytes32 salt;
        address hookAddress;
        for (uint256 i = 0; i < 160_000; i++) {
            salt = bytes32(i);
            hookAddress = _computeCreate2Address(foundryCreate2Factory, salt, keccak256(hookCreationCode));
            if (uint160(hookAddress) & 0x3FFF == uint160(HOOK_FLAGS)) break;
        }
        console2.log("Mined hook address:", hookAddress);
        console2.log("CREATE2 salt (uint):", uint256(salt));

        vm.startBroadcast(deployerKey);

        // ── 2. Deploy VadiumHook at the mined address ─────────────────────────
        VadiumHook hook = new VadiumHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            Currency.wrap(address(0)),
            Currency.wrap(USDC),
            POOL_FEE,
            10,
            deployer, // owner — the EOA, not the CREATE2 factory
            CALLBACK_PROXY // Reactive Callback Proxy on Unichain Sepolia
        );
        require(address(hook) == hookAddress, "Hook address mismatch - re-mine salt");
        console2.log("VadiumHook:   ", address(hook));
        console2.log("Owner:        ", hook.owner());

        // ── 3. Initialize the pool ────────────────────────────────────────────
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: POOL_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        IPoolManager(POOL_MANAGER).initialize(poolKey, INITIAL_SQRT_PRICE);
        console2.log("Pool initialized at tick 0 (1:1)");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment complete ===");
        console2.log("VadiumHook:   ", address(hook));
        console2.log("Bond token1:  ", USDC);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. LP: add liquidity to the pool");
        console2.log("  2. Searcher: bond() with USDC, then swap for the discounted fee");
        console2.log("  3. Verify on Uniscan");
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Computes the CREATE2 address without deploying anything.
    function _computeCreate2Address(address deployer_, bytes32 salt_, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, initCodeHash)))));
    }
}