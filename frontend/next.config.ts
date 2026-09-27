import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // deployments.json is read with fs at request time; make sure it ships with the server bundle.
  outputFileTracingIncludes: { "/**": ["./src/generated/*.json"] },
};

export default nextConfig;
