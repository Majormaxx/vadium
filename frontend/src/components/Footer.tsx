import { addressUrl } from "@/lib/chain";
import { chainContext } from "@/lib/onchain";

export function Footer() {
  const ctx = chainContext();
  return (
    <footer className="mt-12" style={{ borderTop: "1px solid var(--border)" }}>
      <div className="container muted flex flex-wrap items-center justify-between gap-2 py-4 text-sm">
        <div>
          {ctx.chainName}
          {ctx.hook ? (
            <>
              {" "}
              hook{" "}
              <a className="mono" href={addressUrl(ctx.chainId, ctx.hook)} target="_blank" rel="noreferrer">
                {ctx.hook}
              </a>
            </>
          ) : (
            " no hook address configured"
          )}
        </div>
        <div className="flex gap-4">
          <a href="https://github.com/Majormaxx/vadium" target="_blank" rel="noreferrer">
            Source
          </a>
          <a
            href="https://github.com/Majormaxx/vadium/blob/main/docs/THREAT-MODEL.md"
            target="_blank"
            rel="noreferrer"
          >
            Threat model
          </a>
        </div>
      </div>
    </footer>
  );
}
