// The field-security performance budget over HTTP (Task 20, spec R10), against the local stack.
//
//   eval "$(supabase status -o env | sed 's/^/export /')" && cd supabase/functions && deno task perf:http
//   then: supabase db reset (the load is committed) and pnpm dev:seed-story from app/.
//
// 1. Loads supabase/perf/field_security_perf_load.sql (committed; skipped when already loaded)
//    and the HTTP fixtures (http-tests/helpers.ts adminSetup).
// 2. Baseline, measured live: GRANT SELECT, UPDATE on the measured public tables TO authenticated,
//    the same requests with Accept-Profile: public, then REVOKE in a finally block, and a check that
//    no public relation grants anything to anon/authenticated afterwards (exit 3 if one does).
// 3. The same requests through api. 30 per case per actor (after 3 warm-ups): the product list
//    (50), the sourcing list (50, with supplier(code)), the purchase-order overview (50) and a PATCH with
//    return=representation. Medians compared against R10's budget (amended 2026-11-09): reads
//    internal ≤ max(+15%, +5 ms), restricted and mixed ≤ max(+40%, +10 ms) (the per-query fixed
//    cost of masking dominates indexed lists); writes (a case with a method) ≤ +15 ms absolute,
//    whatever the actor (the forwarder's fixed cost dominates a ~7 ms write).
// 4. Sharing (Plan 2, Task 10): THO, the client of MOESA LTD, over the load's shared orders and
//    shipments. thomas (owner of THO, scope {THO}) lists 50 orders with their lines embedded and 50
//    shipments (restricted); akif (management in MOESA LTD and THO, scope {MOESA LTD, THO}) lists 50
//    orders with their lines (internal) and PATCHes an open field (ready_on) of a shared order (write).
//    The baseline is the same request on the public profile, under the same RLS, as above.
//    Exit 1 when over budget.
//
// No secret is printed; the service key stays in helpers.ts. Not run in CI.
import { adminSetup, adminTeardown, API_URL, type Fixture, rest, signIn } from '../http-tests/helpers.ts';

const CONTAINER = 'supabase_db_moesa-panel';
const N = 30;
const WARMUP = 3;
// R10 as amended 2026-11-09: a write may cost at most this much more than its public baseline (median);
// a read may cost the larger of its ratio and its absolute allowance.
const WRITE_BUDGET_MS = 15;
const READ_ALLOWANCE_MS = { internal: 5, restricted: 10, mixed: 10 } as const;
const PERF_PRODUCT = 'feed0001-0000-4000-8000-000000000001';
const PERF_SHARED_PO = 'feed0007-0000-4000-8000-000000000001';
const MEASURED = [
   'public.product',
   'public.sourcing',
   'public.provider_relationship',
   'public.supplier',
   'public.purchase_order',
   'public.purchase_order_line',
   'public.shipment',
   'public.purchase_order_payment',
   'public.project',
   'public.document',
   'public.purchase_order_overview',
];
// Read by the client_select draft term (067), selectable by api_owner alone: the baseline caller
// needs it to pay the same policies. Granted and revoked with MEASURED, and checked for leaks.
const POLICY_READ = 'private.purchase_order_released';

if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(API_URL)) throw new Error('local stack only');

async function psql(sql: string): Promise<string> {
   const cmd = new Deno.Command('docker', {
      args: ['exec', '-i', '-e', 'PGCLIENTENCODING=UTF8', CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-f', '-'],
      stdin: 'piped',
      stdout: 'piped',
      stderr: 'piped',
   });
   const child = cmd.spawn();
   const writer = child.stdin.getWriter();
   await writer.write(new TextEncoder().encode(sql));
   await writer.close();
   const out = await child.output();
   const stdout = new TextDecoder().decode(out.stdout);
   if (!out.success) throw new Error(`psql failed: ${new TextDecoder().decode(out.stderr).trim()}`);
   return stdout.trim();
}

const publicGrants = () =>
   psql(`SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) x
      WHERE (c.relnamespace = 'public'::regnamespace OR c.oid = '${POLICY_READ}'::regclass)
        AND x.grantee IN (0, 'anon'::regrole, 'authenticated'::regrole);`);

type Actor = { name: 'internal' | 'restricted' | 'mixed'; token: string; headers: Record<string, string>; label?: string };
type Case = { name: string; path: string; method?: string; body?: unknown; prefer?: string };

const CASES: Case[] = [
   { name: 'product list 50', path: 'product?select=*&order=created_at.desc&limit=50' },
   { name: 'sourcing list 50 + embed', path: 'sourcing?select=*,supplier(code)&order=created_at.desc&limit=50' },
   { name: 'purchase_order_overview 50', path: 'purchase_order_overview?select=*&limit=50' },
   {
      name: 'PATCH return=representation',
      path: `product?id=eq.${PERF_PRODUCT}`,
      method: 'PATCH',
      body: { display_name: 'perf' },
      prefer: 'return=representation',
   },
];

// The sharing scenarios: each with its own actor (filled in once the fixture is up).
const SHARED_CASES: (Case & { actor: 'clientOwner' | 'providerTwoTenants' })[] = [
   {
      name: 'shared_client_owner_po_list',
      actor: 'clientOwner',
      path: 'purchase_order?select=*,purchase_order_line(*)&order=created_at.desc&limit=50',
   },
   { name: 'shared_client_owner_shipment_list', actor: 'clientOwner', path: 'shipment?select=*&order=created_at.desc&limit=50' },
   {
      name: 'provider_two_tenants_po_list',
      actor: 'providerTwoTenants',
      path: 'purchase_order?select=*,purchase_order_line(*)&order=created_at.desc&limit=50',
   },
   {
      name: 'provider_po_update_shared',
      actor: 'providerTwoTenants',
      path: `purchase_order?id=eq.${PERF_SHARED_PO}`,
      method: 'PATCH',
      body: { ready_on: '2026-12-02' },
      prefer: 'return=representation',
   },
];

const median = (xs: number[]) => {
   const s = [...xs].sort((a, b) => a - b);
   return s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
};

async function time(actor: Actor, c: Case, profile: 'api' | 'public'): Promise<number> {
   const run = async () => {
      const t0 = performance.now();
      const r = await rest(actor.token, c.path, {
         method: c.method,
         body: c.body,
         profile,
         headers: { ...actor.headers, ...(c.prefer ? { Prefer: c.prefer } : {}) },
      });
      const ms = performance.now() - t0;
      if (r.status >= 300) throw new Error(`${profile} ${actor.name} ${c.name}: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`);
      if (!Array.isArray(r.body) || r.body.length === 0) throw new Error(`${profile} ${actor.name} ${c.name}: no rows`);
      return ms;
   };
   // A failing request (e.g. 57014, the authenticated role's statement timeout) ends the case: NaN,
   // reported as an error and over budget.
   try {
      for (let i = 0; i < WARMUP; i++) await run();
      const xs: number[] = [];
      for (let i = 0; i < N; i++) xs.push(await run());
      return median(xs);
   } catch (error) {
      console.error(`  ${(error as Error).message}`);
      return Number.NaN;
   }
}

type Run = { actor: Actor; c: Case };

async function measure(runs: Run[], profile: 'api' | 'public'): Promise<Map<string, number>> {
   const out = new Map<string, number>();
   for (const { actor, c } of runs) out.set(`${actor.label ?? actor.name}|${c.name}`, await time(actor, c, profile));
   return out;
}

let f: Fixture | undefined;
let exitCode = 0;
try {
   if ((await psql(`SELECT count(*) FROM public.product WHERE id = '${PERF_PRODUCT}';`)) === '0') {
      const load = await Deno.readTextFile(new URL('../../perf/field_security_perf_load.sql', import.meta.url));
      console.log('loading field_security_perf_load.sql (committed) …');
      await psql(`BEGIN;\n${load}\nCOMMIT;\n`);
   }
   f = await adminSetup();
   const internal = await signIn('akif@moesa-panel.test');
   const actors: Actor[] = [
      { name: 'internal', token: internal, headers: { 'x-tenant-id': f.moesa } },
      { name: 'restricted', token: f.restricted, headers: { 'x-tenant-id': f.moesa } },
      { name: 'mixed', token: f.mixed, headers: { 'x-tenant-id': f.moesa, 'x-tenant-ids': `${f.moesa},${f.europe}` } },
   ];
   const sharedActors: Record<'clientOwner' | 'providerTwoTenants', Actor> = {
      clientOwner: { name: 'restricted', label: 'client owner', token: f.clientOwner, headers: { 'x-tenant-id': f.client, 'x-tenant-ids': f.client } },
      providerTwoTenants: {
         name: 'internal',
         label: 'provider {P, C}',
         token: internal,
         headers: { 'x-tenant-id': f.moesa, 'x-tenant-ids': `${f.moesa},${f.client}` },
      },
   };
   const runs: Run[] = [
      ...actors.flatMap((actor) => CASES.map((c) => ({ actor, c }))),
      ...SHARED_CASES.map(({ actor, ...c }) => ({ actor: sharedActors[actor], c })),
   ];

   let base: Map<string, number>;
   await psql(`GRANT SELECT, UPDATE ON ${MEASURED.join(', ')} TO authenticated; GRANT SELECT ON ${POLICY_READ} TO authenticated;`);
   try {
      base = await measure(runs, 'public');
   } finally {
      await psql(`REVOKE SELECT, UPDATE ON ${MEASURED.join(', ')} FROM authenticated; REVOKE SELECT ON ${POLICY_READ} FROM authenticated;`);
      const left = await publicGrants();
      if (left !== '0') {
         console.error(`LEAK: ${left} public ACL entries for anon/authenticated remain after the baseline`);
         exitCode = 3;
      }
   }
   if (exitCode) throw new Error('public grants remain');
   const api = await measure(runs, 'api');

   const rows: string[] = [];
   const over: string[] = [];
   rows.push('| actor | case | public ms | api ms | delta | budget | verdict |', '|---|---|---|---|---|---|---|');
   for (const { actor: a, c } of runs) {
      const key = `${a.label ?? a.name}|${c.name}`;
      const b = base.get(key)!;
      const x = api.get(key)!;
      const write = c.method !== undefined;
      const limit = a.name === 'internal' ? 1.15 : 1.4;
      const ok = write ? x - b <= WRITE_BUDGET_MS : x <= Math.max(b * limit, b + READ_ALLOWANCE_MS[a.name]);
      const verdict = !ok ? 'OVER' : 'ok';
      if (verdict === 'OVER') over.push(key);
      const delta = Number.isNaN(x / b)
         ? 'error'
         : `${x / b >= 1 ? '+' : ''}${((x / b - 1) * 100).toFixed(1)}% (${x - b >= 0 ? '+' : ''}${(x - b).toFixed(2)} ms)`;
      const budget = write ? `+${WRITE_BUDGET_MS} ms` : `max(+${Math.round((limit - 1) * 100)}%, +${READ_ALLOWANCE_MS[a.name]} ms)`;
      rows.push(`| ${a.label ?? a.name} | ${c.name} | ${b.toFixed(2)} | ${x.toFixed(2)} | ${delta} | ${budget} | ${verdict} |`);
   }
   console.log(`\nHTTP medians of ${N} requests (after ${WARMUP} warm-ups), PostgREST at ${API_URL}`);
   console.log(rows.join('\n'));
   if (over.length) {
      console.error(`budget: ${over.join('; ')}`);
      exitCode = 1;
   }
} catch (error) {
   console.error((error as Error).message);
   exitCode ||= 2;
} finally {
   // The grants are closed above; check once more whatever happened.
   try {
      const left = await publicGrants();
      if (left !== '0') {
         console.error(`LEAK: ${left} public ACL entries for anon/authenticated remain`);
         exitCode = 3;
      }
   } catch (error) {
      console.error(`could not verify the public grants: ${(error as Error).message}`);
      exitCode = 3;
   }
   if (f) await adminTeardown(f).catch((error) => console.error(`teardown: ${(error as Error).message}`));
}
Deno.exit(exitCode);
