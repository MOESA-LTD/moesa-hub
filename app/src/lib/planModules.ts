/** A module and the others it cannot work without (public.module.requires, migration 075). */
export type ModuleRequirement = { id: string; is_core: boolean; requires: string[] | null };

/**
 * The plan's modules after the picker changed from `previous` to `next`, kept consistent with the
 * requirements (the database refuses anything else, plan_module_requires): a module picked brings
 * the modules it requires, and a module dropped takes the modules that require it. Core modules
 * come with every plan, so they are never added. Keeps the order of `next`, then what was added.
 */
export function resolvePlanModules(
   previous: string[],
   next: string[],
   modules: ModuleRequirement[]
): string[] {
   const byId = new Map(modules.map((module) => [module.id, module]));
   const isCore = (id: string) => byId.get(id)?.is_core ?? false;
   const requires = (id: string) => (byId.get(id)?.requires ?? []).filter((r) => !isCore(r));

   const dropped = previous.filter((id) => !next.includes(id));
   const picked = next.filter((id) => !previous.includes(id));

   // Drop what (transitively) requires a dropped module.
   const removed = new Set(dropped);
   let grew = true;
   while (grew) {
      grew = false;
      for (const id of next) {
         if (!removed.has(id) && requires(id).some((r) => removed.has(r))) {
            removed.add(id);
            grew = true;
         }
      }
   }
   const result = next.filter((id) => !removed.has(id));

   // Add what a picked module (transitively) requires.
   const pending = [...picked];
   while (pending.length) {
      for (const required of requires(pending.pop()!)) {
         if (!result.includes(required)) {
            result.push(required);
            pending.push(required);
         }
      }
   }
   return result;
}
