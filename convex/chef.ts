// Chef: the panel's API (exposeChefApi) and the CLI's admin functions (chefAdmin).
// Written by `npx chef init`.
import { chefAdmin, exposeChefApi } from "@convex-dev/feedback";
import { components } from "./_generated/api";
import type { QueryCtx } from "./_generated/server";
import { currentUserId } from "./users";

export const {
  agentState, listPublicItems, submitRequest, upvoteRequest, answerRefinement, skipRefinement,
  generateUploadUrl, submitRequestWithMedia, listAttachments,
  mine, amAdmin, whoAmI, awaitingApproval, review, whatsNew,
  approvalSnapshot, prepareApproval, approveSnapshot, runLogs, skillFeedback,
  approvalRequests, approveApprovalRequest, declineApprovalRequest, runScreenshots,
  runStatus, recentRuns, buildState, buildInCloud,
  shipCandidate, shipDiffChunk, shipApprove,
  retryRun, appLearnings, forgetLearning, buildCosts, applyRepair, buildCard,
  previewDataMode, setPreviewData, splitFromBatch,
} = exposeChefApi(components.feedback, {
  // Who is calling (null = signed out). currentUserId follows merged accounts, so
  // signing in with Apple or Google is the same person to Chef too.
  getUserId: (ctx) => currentUserId(ctx as unknown as QueryCtx),
  getUserName: async (ctx, userId) => {
    const user = await (ctx as unknown as QueryCtx).db.get("users", userId as never);
    return user?.name ?? null;
  },
});

// For `npx chef`: name the app's admin, and the upgrade steps. Internal.
export const {
  chefSetAdmin, chefMigrateAgentKeys,
} = chefAdmin(components.feedback);
