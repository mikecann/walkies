import { WorkflowManager } from "@convex-dev/workflow";
import { components } from "./_generated/api";

/**
 * Runs lorePipeline.run: two runs of three research angles at once, plus room for
 * stickers. It lives on its own rather than in lorePipeline.ts so that sync.ts, which
 * imports lore.ts, doesn't load the AI libraries on every sync, and lorePipeline.ts
 * doesn't load lore.ts and the machines' catalog.
 */
export const workflow = new WorkflowManager(components.workflow, { workpoolOptions: { maxParallelism: 6 } });
