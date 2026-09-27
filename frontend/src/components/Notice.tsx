import type { ReactNode } from "react";

export function Notice({
  tone = "warn",
  title,
  children,
}: {
  tone?: "warn" | "error" | "ok" | "info";
  title: string;
  children?: ReactNode;
}) {
  return (
    <div className="notice" data-tone={tone} role="status">
      <div className="font-semibold">{title}</div>
      {children ? <div className="muted mt-1 text-sm">{children}</div> : null}
    </div>
  );
}
