/** A plan as `invitation_preview` returns it (plans[] of supabase/migrations/071). */
export type PlanSummary = {
   id: string;
   display_name: string;
   description: string | null;
   /** Free text: who the plan suits. */
   audience: string | null;
   price: number | null;
   currency: string | null;
   billing_period: string | null;
   trial_days: number | null;
   position: number | null;
   modules: string[];
   /** By plan_limit.limit_key; a missing key is unlimited. */
   limits: Record<string, number | null | undefined>;
};

export type PlanDiff = {
   modulesGained: string[];
   modulesLost: string[];
   /** The limits that differ; null is unlimited. */
   limits: { key: string; from: number | null; to: number | null }[];
};

/** What changes when moving from one plan to another. */
export function planDiff(from: PlanSummary, to: PlanSummary): PlanDiff {
   const had = new Set(from.modules);
   const has = new Set(to.modules);
   const keys = [...new Set([...Object.keys(from.limits), ...Object.keys(to.limits)])].sort();

   return {
      modulesGained: to.modules.filter((module) => !had.has(module)),
      modulesLost: from.modules.filter((module) => !has.has(module)),
      limits: keys
         .map((key) => ({ key, from: from.limits[key] ?? null, to: to.limits[key] ?? null }))
         .filter((limit) => limit.from !== limit.to)
   };
}

/** Whether the move takes something away: a module, or a lower (or newly set) limit. */
export const isDowngrade = (diff: PlanDiff) =>
   diff.modulesLost.length > 0 ||
   diff.limits.some(({ from, to }) => to !== null && (from === null || to < from));
