# Deployments

One JSON file per chain id, written by the deploy scripts and read by the fork tests, the services, and the frontend.

| Field | Meaning |
|---|---|
| `chainId`, `chainName` | Target chain |
| `commit` | Short git SHA of the deployed source |
| `block`, `deployedAt` | Block and UTC time of the deploy transaction |
| `hook` | `VadiumHook` address (CREATE2-mined so its low bits encode the permission flags) |
| `poolManager`, `bondToken`, `callbackProxy` | Chain constants the hook was constructed with |
| `poolKey`, `poolId` | The first registered pool and its `keccak256(abi.encode(poolKey))` |
| `txs` | Transaction hashes for deploy and pool initialization |
| `reactive` | Reactive Network sidecar record, or `null` when none is deployed |

Chain ids: `1301` Unichain Sepolia, `130` Unichain mainnet.
