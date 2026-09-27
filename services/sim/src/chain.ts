import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
  type Chain,
  type PublicClient,
  type WalletClient,
  type Transport,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import type { SimConfig } from "./config.js";

export function simChain(chainId: number, rpcUrl: string): Chain {
  return defineChain({
    id: chainId,
    name: chainId === 1301 ? "Unichain Sepolia" : chainId === 130 ? "Unichain" : `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
}

export interface Clients {
  chain: Chain;
  publicClient: PublicClient<Transport, Chain>;
  /** Present only when a private key was configured. */
  walletClient: WalletClient<Transport, Chain, PrivateKeyAccount> | undefined;
  account: PrivateKeyAccount | undefined;
  /** The sim owner: the signing account, or SIM_ADDRESS for read-only work. */
  owner: Address | undefined;
}

export function makeClients(config: SimConfig): Clients {
  const chain = simChain(config.chainId, config.rpcUrl);
  const transport = http(config.rpcUrl, { retryCount: 3 });
  const publicClient = createPublicClient({ chain, transport });
  if (config.privateKey === undefined) {
    return { chain, publicClient, walletClient: undefined, account: undefined, owner: config.address };
  }
  const account = privateKeyToAccount(config.privateKey);
  const walletClient = createWalletClient({ chain, transport, account });
  return { chain, publicClient, walletClient, account, owner: account.address };
}
