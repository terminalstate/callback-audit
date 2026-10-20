import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

const mock = (name: string) => fileURLToPath(new URL(`./mocks/${name}`, import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "wasp/server/api": mock("wasp-server-api.ts"),
      "wasp/server": mock("wasp-server.ts"),
      "@prisma/client": mock("prisma-client.ts"),
    },
  },
  test: { include: ["tests/**/*.test.ts"] },
});
