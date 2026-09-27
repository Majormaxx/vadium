import { sparklinePath } from "@/lib/staleness";

export function Sparkline({
  values,
  width = 320,
  height = 64,
  label,
}: {
  values: number[];
  width?: number;
  height?: number;
  label: string;
}) {
  const d = sparklinePath(values, width, height, 3);
  return (
    <svg
      className="sparkline"
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={label}
      preserveAspectRatio="none"
    >
      <path className="baseline" d={`M3,${height - 3} L${width - 3},${height - 3}`} />
      {d ? <path d={d} /> : null}
    </svg>
  );
}
