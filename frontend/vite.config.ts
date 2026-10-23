import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      // the server's same-origin guard stays on: the Origin header is rewritten to the target
      "/api": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on("proxyReq", (proxyReq) => {
            if (proxyReq.getHeader("origin")) {
              proxyReq.setHeader("origin", "http://127.0.0.1:8080");
            }
          });
        },
      },
    },
  },
  build: {
    outDir: "../src/rios_de_asia_accounting/web/dist",
    emptyOutDir: true,
  },
});
