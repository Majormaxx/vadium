import Link from "next/link";

export default function NotFound() {
  return (
    <div className="prose">
      <h1>Not found</h1>
      <p className="mt-3">That page does not exist. Pool ids are 32-byte hex strings and searcher pages take a checksummed or lowercase address.</p>
      <p>
        <Link href="/">Back to pools</Link>
      </p>
    </div>
  );
}
