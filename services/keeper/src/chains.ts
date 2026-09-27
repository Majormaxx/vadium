import { defineChain, type Chain } from "viem";

export const unichainSepolia = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://sepolia.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
  testnet: true,
});

export const unichain = defineChain({
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://uniscan.xyz" } },
});

export const supportedChains: Record<number, Chain> = {
  [unichainSepolia.id]: unichainSepolia,
  [unichain.id]: unichain,
};

export function chainFor(chainId: number): Chain {
  const chain = supportedChains[chainId];
  if (!chain) {
    throw new Error(`unsupported CHAIN_ID ${chainId}; supported: ${Object.keys(supportedChains).join(", ")}`);
  }
  return chain;
}
