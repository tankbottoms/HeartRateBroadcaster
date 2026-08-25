import { defineConfig } from "oxlint";

// Correctness and suspicious-pattern rules only. The app is Swift; everything
// linted here is build and release tooling, where the failure mode that matters
// is a script that runs and does the wrong thing rather than a style argument.
export default defineConfig({
  ignorePatterns: ["build/**", "node_modules/**", "web/dist/**"],
  categories: { correctness: "error", suspicious: "warn" },
});
