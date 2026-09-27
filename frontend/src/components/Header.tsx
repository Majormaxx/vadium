import Link from "next/link";

const links = [
  { href: "/", label: "Pools" },
  { href: "/mechanism", label: "Mechanism" },
  { href: "/status", label: "Status" },
];

export function Header() {
  return (
    <header style={{ borderBottom: "1px solid var(--border)" }}>
      <div className="container flex items-center justify-between gap-4 py-3">
        <Link href="/" className="flex items-center gap-2" style={{ color: "var(--text)" }}>
          <picture>
            <source srcSet="/brand/vadium-mark--reverse.svg" media="(prefers-color-scheme: dark)" />
            <img src="/brand/vadium-mark.svg" alt="" className="brand-mark" width={28} height={28} />
          </picture>
          <span className="font-semibold">Vadium</span>
        </Link>
        <nav className="nav flex items-center gap-5 text-sm" aria-label="Main">
          {links.map((l) => (
            <Link key={l.href} href={l.href}>
              {l.label}
            </Link>
          ))}
        </nav>
      </div>
    </header>
  );
}
