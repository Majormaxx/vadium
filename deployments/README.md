# Deployments

One JSON file per chain id, written by the deploy scripts and read by the fork tests, the services, and the frontend.

| Field | Meaning |
|---|---|
| `chainId`, `chainName` | Target chain |
| `commit` | Short git SHA of the deployed source (`GIT_SHA` at deploy time) |
| `block`, `timestamp` | Block number and timestamp of the deploy |
| `hook`, `salt` | `VadiumHook` address (CREATE2-mined so its low 14 bits are `0x20C4`) and the mined salt |
| `poolManager`, `stateView`, `bondToken`, `callbackProxy` | Chain constants the hook was constructed with |
| `deployer`, `owner` | Broadcaster, and the address ownership was offered to (two-step) |
| `poolKey`, `poolId` | The first registered pool and its `keccak256(abi.encode(poolKey))` |
| `reactive` | Reactive sidecar address, or empty when none is deployed |

Chain ids: `1301` Unichain Sepolia, `130` Unichain mainnet.
