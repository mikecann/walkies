/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as accountDeletion from "../accountDeletion.js";
import type * as auth from "../auth.js";
import type * as chef from "../chef.js";
import type * as crons from "../crons.js";
import type * as grid from "../grid.js";
import type * as http from "../http.js";
import type * as lore from "../lore.js";
import type * as loreBudget from "../loreBudget.js";
import type * as loreChecks from "../loreChecks.js";
import type * as loreConfig from "../loreConfig.js";
import type * as loreCutout from "../loreCutout.js";
import type * as loreMachines from "../loreMachines.js";
import type * as lorePipeline from "../lorePipeline.js";
import type * as lorePrompts from "../lorePrompts.js";
import type * as loreRun from "../loreRun.js";
import type * as loreStates from "../loreStates.js";
import type * as loreStickers from "../loreStickers.js";
import type * as loreWorkflow from "../loreWorkflow.js";
import type * as machines from "../machines.js";
import type * as placeData from "../placeData.js";
import type * as places from "../places.js";
import type * as progression from "../progression.js";
import type * as sync from "../sync.js";
import type * as teams from "../teams.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  accountDeletion: typeof accountDeletion;
  auth: typeof auth;
  chef: typeof chef;
  crons: typeof crons;
  grid: typeof grid;
  http: typeof http;
  lore: typeof lore;
  loreBudget: typeof loreBudget;
  loreChecks: typeof loreChecks;
  loreConfig: typeof loreConfig;
  loreCutout: typeof loreCutout;
  loreMachines: typeof loreMachines;
  lorePipeline: typeof lorePipeline;
  lorePrompts: typeof lorePrompts;
  loreRun: typeof loreRun;
  loreStates: typeof loreStates;
  loreStickers: typeof loreStickers;
  loreWorkflow: typeof loreWorkflow;
  machines: typeof machines;
  placeData: typeof placeData;
  places: typeof places;
  progression: typeof progression;
  sync: typeof sync;
  teams: typeof teams;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {
  auth: import("@convex-dev/auth/_generated/component.js").ComponentApi<"auth">;
  authApple: import("@convex-dev/auth/components/apple/_generated/component.js").ComponentApi<"authApple">;
  authGoogle: import("@convex-dev/auth/components/google/_generated/component.js").ComponentApi<"authGoogle">;
  authAnonymous: import("@convex-dev/auth/components/anonymous/_generated/component.js").ComponentApi<"authAnonymous">;
  feedback: import("@convex-dev/feedback/_generated/component.js").ComponentApi<"feedback">;
  staticHosting: import("@convex-dev/static-hosting/_generated/component.js").ComponentApi<"staticHosting">;
  workflow: import("@convex-dev/workflow/_generated/component.js").ComponentApi<"workflow">;
  agent: import("@convex-dev/agent/_generated/component.js").ComponentApi<"agent">;
  stateMachines: import("@convex-dev/state-machines/_generated/component.js").ComponentApi<"stateMachines">;
};
