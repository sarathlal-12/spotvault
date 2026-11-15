import { defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

// SpotVault Internet Jam relay (see src/index.ts).
export default defineConfig({
	worker: {
		name: "spotvault-jam",
		compatibilityDate: "2026-11-13",
		entrypoint,
		exports: {
			JamRoom: exports.durableObject({ storage: "sqlite" }),
		},
	},
});
