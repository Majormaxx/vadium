import { defineConfig } from "vitest/config";

// Only the pure modules are tested. src/index.ts and src/api/index.ts import
// Ponder's virtual modules and need its runtime.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    testTimeout: 2_000,
  },
});
