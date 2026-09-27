import type { ReactNode } from "react";

export function Section({
  title,
  aside,
  children,
}: {
  title: string;
  aside?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="mt-8">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <h2>{title}</h2>
        {aside ? <div className="muted text-sm">{aside}</div> : null}
      </div>
      {children}
    </section>
  );
}
