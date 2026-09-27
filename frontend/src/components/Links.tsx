import Link from "next/link";
import { addressUrl, blockUrl, txUrl } from "@/lib/chain";
import { formatInt, shortAddress, shortHash } from "@/lib/format";

export function AddressLink({
  chainId,
  address,
  full = false,
}: {
  chainId: number;
  address: string;
  full?: boolean;
}) {
  return (
    <a className="mono" href={addressUrl(chainId, address)} target="_blank" rel="noreferrer" title={address}>
      {full ? address : shortAddress(address)}
    </a>
  );
}

/** Links to the searcher page inside this site. */
export function SearcherLink({ address, full = false }: { address: string; full?: boolean }) {
  return (
    <Link className="mono" href={`/searcher/${address}`} title={address}>
      {full ? address : shortAddress(address)}
    </Link>
  );
}

export function TxLink({ chainId, hash }: { chainId: number; hash: string }) {
  return (
    <a className="mono" href={txUrl(chainId, hash)} target="_blank" rel="noreferrer" title={hash}>
      {shortHash(hash)}
    </a>
  );
}

export function BlockLink({ chainId, block }: { chainId: number; block: string | number | bigint }) {
  return (
    <a className="mono" href={blockUrl(chainId, block)} target="_blank" rel="noreferrer">
      {formatInt(block)}
    </a>
  );
}

export function PoolLink({ poolId, label }: { poolId: string; label?: string }) {
  return (
    <Link href={`/pool/${poolId}`} className={label ? undefined : "mono"} title={poolId}>
      {label ?? shortHash(poolId)}
    </Link>
  );
}
