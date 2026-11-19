import '../setup/mockMain';
import { type TransferOptions, type TransferReport, type TransferRow } from '@/api/transfer';
import { ability } from '@/plugins/casl';
import en from '@/plugins/i18n/locales/en/index.json';
import ProductIndex from '@/views/pages/ops/product/Index.vue';
import ApplyStep from '@/views/pages/ops/transfer/ApplyStep.vue';
import ReportStep from '@/views/pages/ops/transfer/ReportStep.vue';
import ResultStep from '@/views/pages/ops/transfer/ResultStep.vue';
import TargetStep from '@/views/pages/ops/transfer/TargetStep.vue';
import {
   useTransferWizard,
   type TransferWizard
} from '@/views/pages/ops/transfer/useTransferWizard';
import i18n, { i18NPlugin } from '@plugins/i18n';
import { abilitiesPlugin } from '@casl/vue';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils';
import { createPinia, setActivePinia } from 'pinia';
import PrimeVue from 'primevue/config';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { defineComponent, h, nextTick } from 'vue';

// The transfer API is a stand-in: the options, the rehearsal, the run and the file copy. The
// labels and the target lookups go through the real hooks to a stand-in query builder, which
// records the tenant headers.
const api = vi.hoisted(() => ({
   options: null as unknown as TransferOptions,
   rehearse: vi.fn(),
   run: vi.fn(),
   copy: vi.fn(),
   retry: vi.fn(),
   pending: [] as unknown[],
   pendingReads: [] as string[][],
   transferReads: [] as unknown[][],
   push: vi.fn(),
   confirmed: [] as string[],
   rows: {} as Record<string, unknown[]>,
   requests: [] as { table: string; headers: Record<string, string>; in: [string, unknown][] }[]
}));

vi.mock('@/api/transfer', async (importOriginal) => {
   const { ref } = await import('vue');
   const original = await importOriginal<typeof import('@/api/transfer')>();
   return {
      ...original,
      useTransferOptions: () => ({ data: ref(api.options), isLoading: ref(false) }),
      useRehearseTransfer: () => ({ mutateAsync: api.rehearse, isPending: ref(false) }),
      useRunTransfer: () => ({ mutateAsync: api.run, isPending: ref(false) }),
      useCopyTransferFiles: () => ({
         mutateAsync: api.copy,
         isPending: ref(false),
         progress: ref(null)
      }),
      useTransfer: (...keys: (() => unknown)[]) => {
         api.transferReads.push(keys.map((key) => key()));
         return { data: ref(undefined), isFetching: ref(false) };
      },
      useRetryTransferFiles: () => ({ mutateAsync: api.retry, isPending: ref(false) }),
      usePendingTransfers: (tenants: () => string[]) => {
         api.pendingReads.push(tenants());
         return { data: ref(api.pending) };
      }
   };
});
vi.mock('vue-router', async (importOriginal) => ({
   ...(await importOriginal<typeof import('vue-router')>()),
   useRoute: () => ({ query: {} }),
   useRouter: () => ({ push: api.push })
}));
vi.mock('@/api/useTenantKey', async () => {
   const { computed } = await import('vue');
   return { useTenantKey: () => computed(() => 'source') };
});
vi.mock('@/composables/useConfirmAction', () => ({
   useConfirmAction:
      () =>
      async ({ message, accept }: { message: string; accept: () => Promise<void> | void }) => {
         api.confirmed.push(message);
         await accept();
         return true;
      }
}));
vi.mock('@/lib/supabase', () => ({
   supabase: {
      from: (table: string) => {
         const request = {
            table,
            headers: {} as Record<string, string>,
            in: [] as [string, unknown][]
         };
         api.requests.push(request);
         const builder: Record<string, unknown> = {
            select: () => builder,
            abortSignal: () => builder,
            order: () => builder,
            in: (column: string, values: unknown[]) => {
               request.in.push([column, values]);
               return builder;
            },
            setHeader: (name: string, value: string) => {
               request.headers[name] = value;
               return builder;
            },
            throwOnError: () => Promise.resolve({ data: api.rows[table] ?? [] })
         };
         return builder;
      }
   }
}));

const options = (sourceWritable = true): TransferOptions => ({
   source_writable: sourceWritable,
   targets: [
      { id: 'branch', display_name: 'Branch', same_company: true, refusal: null },
      {
         id: 'locked',
         display_name: 'Locked Ltd',
         same_company: false,
         refusal: 'transfer_target_unavailable'
      },
      { id: 'other', display_name: 'Other Ltd', same_company: false, refusal: null }
   ]
});

const report = (overrides: Partial<TransferReport> = {}): TransferReport => ({
   mode: 'copy',
   source_tenant: 'source',
   target_tenant: 'branch',
   product_ids: ['p1', 'p2'],
   counts: { product: 2, media: 1 },
   excluded: [],
   excluded_rows: {},
   blanked: [],
   conflicts: [],
   left_behind: [],
   left_behind_links: {},
   cleared: [],
   settings_gaps: [],
   files: 0,
   unresolved: 0,
   report_hash: 'hash-1',
   ...overrides
});

const supplierConflict = {
   key: 'supplier:s1',
   kind: 'supplier_code' as const,
   table: 'supplier',
   source_id: 's1',
   existing_id: 'tc1',
   actions: ['map' as const, 'new_code' as const]
};
const skuConflict = {
   key: 'sku:p1',
   kind: 'sku' as const,
   table: 'product',
   source_id: 'p1',
   existing_id: 'x1',
   actions: ['rename' as const, 'skip' as const],
   skip_drops: { media: 1 }
};
const gtinConflict = {
   key: 'gtin:p2',
   kind: 'gtin' as const,
   table: 'product',
   source_id: 'p2',
   existing_id: null,
   actions: ['clear_gtin' as const, 'skip' as const]
};

const row = (overrides: Partial<TransferRow> = {}): TransferRow =>
   ({
      id: 'tr',
      tenant_id: 'branch',
      source_tenant_id: 'source',
      product_ids: ['p1', 'p2'],
      mode: 'copy',
      started_by: 'u',
      report: {},
      decisions: {},
      id_map: {},
      files: [],
      files_status: 'done',
      missing_files: [],
      audit_transaction_ids: [],
      xact_id: null,
      created_at: '',
      updated_at: '',
      ...overrides
   }) as TransferRow;

let wizard: TransferWizard;

const Host = defineComponent({
   setup() {
      wizard = useTransferWizard({ sourceTenant: 'source', productIds: ['p1', 'p2'] });
      return () =>
         h('div', [
            h(TargetStep, { wizard }),
            wizard.step.value === 'report' && wizard.report.value
               ? h(ReportStep, { wizard })
               : null,
            wizard.step.value === 'apply' && wizard.report.value ? h(ApplyStep, { wizard }) : null,
            wizard.step.value === 'files' && wizard.transfer.value && wizard.report.value
               ? h(ResultStep, {
                    transfer: wizard.transfer.value,
                    report: wizard.report.value,
                    progress: null,
                    copying: false
                 })
               : null
         ]);
   }
});

const plugins = [
   i18NPlugin,
   PrimeVue,
   [VueQueryPlugin, { queryClient: new QueryClient() }],
   [abilitiesPlugin, ability, { useGlobalProperties: true }]
] as never;

const mountWizard = async () => {
   const wrapper = mount(Host, {
      attachTo: document.body,
      global: { plugins, directives: { tooltip: {} } }
   });
   await flushPromises();
   return wrapper;
};

const rehearseTo = async (next: TransferReport) => {
   api.rehearse.mockResolvedValueOnce(next);
   await wizard.rehearse();
   await flushPromises();
};

enableAutoUnmount(afterEach);
beforeAll(() => i18n.setLocaleMessage('en', en));
beforeEach(() => {
   setActivePinia(createPinia());
   ability.update([{ action: 'manage', subject: 'all' }]);
   api.options = options();
   api.rehearse.mockReset();
   api.run.mockReset();
   api.copy.mockReset();
   api.retry.mockReset();
   api.pending = [];
   api.pendingReads = [];
   api.transferReads = [];
   api.push.mockReset();
   api.confirmed = [];
   api.rows = {};
   api.requests = [];
   document.body.innerHTML = '';
});

describe('transfer wizard', () => {
   it('starts on copy and disables move for a read-only source', async () => {
      api.options = options(false);
      const wrapper = await mountWizard();

      expect(wizard.mode.value).toBe('copy');
      expect(wrapper.find('[data-read-only]').exists()).toBe(true);
      wizard.mode.value = 'move';
      await nextTick();
      expect(wizard.mode.value).toBe('copy');
   });

   it("lists the target's refusal, localised", async () => {
      const wrapper = await mountWizard();
      await wrapper.find('#transfer-target').trigger('click');
      await flushPromises();

      const refusal = document.body.querySelector('[data-target="locked"] [data-refusal]');
      expect(refusal?.textContent?.trim()).toBe(en.errors.transfer_target_unavailable);
      expect(document.body.querySelector('[data-target="other"] [data-refusal]')).toBeNull();
   });

   it('cannot rehearse into a refused target', async () => {
      await mountWizard();
      wizard.target.value = 'locked';
      await nextTick();
      expect(wizard.canRehearse.value).toBe(false);
      wizard.target.value = 'other';
      await nextTick();
      expect(wizard.canRehearse.value).toBe(true);
   });

   it('a decision makes the report stale until rehearsed again', async () => {
      const wrapper = await mountWizard();
      wizard.target.value = 'branch';
      await nextTick();
      await rehearseTo(report({ unresolved: 1, conflicts: [skuConflict] }));

      expect(wizard.step.value).toBe('report');
      expect(wizard.stale.value).toBe(false);
      wizard.decide('sku:p1', { action: 'rename', suffix: '-B' });
      await nextTick();
      expect(wizard.stale.value).toBe(true);
      expect(wizard.canRun.value).toBe(false);
      expect(wrapper.find('[data-rehearse-again]').exists()).toBe(true);

      await rehearseTo(report({ unresolved: 0, conflicts: [skuConflict] }));
      expect(wizard.stale.value).toBe(false);
      expect(wizard.canRun.value).toBe(true);
   });

   it('does not read a decision set again in another order as a change', async () => {
      await mountWizard();
      wizard.target.value = 'branch';
      await nextTick();
      wizard.decide('b', { action: 'skip' });
      wizard.decide('a', { action: 'clear_gtin' });
      await rehearseTo(report());
      wizard.decide('a', { action: 'clear_gtin' });
      expect(wizard.stale.value).toBe(false);
   });

   it('changing the target clears decisions and the report', async () => {
      await mountWizard();
      wizard.target.value = 'branch';
      await nextTick();
      wizard.decide('sku:p1', { action: 'skip' });
      await rehearseTo(report());

      wizard.target.value = 'other';
      await nextTick();
      expect(wizard.decisions.value).toEqual({});
      expect(wizard.report.value).toBeNull();
      expect(wizard.step.value).toBe('target');
   });

   it('rehearses with the source, target, products and mode only', async () => {
      await mountWizard();
      wizard.target.value = 'branch';
      await nextTick();
      await rehearseTo(report());

      expect(api.rehearse).toHaveBeenCalledWith({
         source_tenant: 'source',
         target_tenant: 'branch',
         mode: 'copy',
         decisions: {},
         product_ids: ['p1', 'p2']
      });
   });
});

describe('report step', () => {
   const rehearse = async (next: TransferReport, mode: 'copy' | 'move' = 'copy') => {
      const wrapper = await mountWizard();
      wizard.target.value = 'branch';
      wizard.mode.value = mode;
      await nextTick();
      await rehearseTo(next);
      return wrapper;
   };

   it('shows the left-behind warning when the report has links', async () => {
      const wrapper = await rehearse(
         report({ mode: 'move', left_behind_links: { sourcing: 2, purchase_order_line: 1 } }),
         'move'
      );

      const warning = wrapper.find('[data-left-behind-links]');
      expect(warning.exists()).toBe(true);
      expect(warning.text()).toContain(en.ops.transfer.report.links_title);
      expect(warning.text()).toContain('(2)');
      expect(warning.text()).toContain('(1)');
   });

   it('shows no left-behind warning without links, or for a copy', async () => {
      const move = await rehearse(report({ mode: 'move' }), 'move');
      expect(move.find('[data-left-behind-links]').exists()).toBe(false);
      move.unmount();

      const copy = await rehearse(report({ left_behind_links: { sourcing: 2 } }));
      expect(copy.find('[data-left-behind-links]').exists()).toBe(false);
   });

   it('explains the tables left out because the target is a client', async () => {
      const wrapper = await rehearse(
         report({ excluded: ['supplier', 'supplier_contact', 'sourcing'] })
      );

      const note = wrapper.find('[data-excluded]');
      expect(note.text()).toContain(en.ops.transfer.report.excluded_title);
      expect(note.text()).toContain('Supplier, Supplier contact, Sourcing');
      expect(note.text()).toContain('stay with you');
      expect((await rehearse(report())).find('[data-excluded]').exists()).toBe(false);
   });

   it('explains the rows left out and the columns emptied for a client (C1)', async () => {
      const wrapper = await rehearse(
         report({
            excluded: ['supplier', 'supplier_contact', 'sourcing'],
            excluded_rows: { document: 1, media: 2, media_link: 0 },
            blanked: [{ table: 'product', column: 'notes', rows: 1 }]
         })
      );

      const note = wrapper.find('[data-withheld]');
      expect(note.text()).toContain(en.ops.transfer.report.withheld_title);
      expect(note.text()).toContain(en.ops.transfer.report.withheld_intro);
      expect(note.find('[data-withheld-rows]').text()).toContain('Document (1), Media (2)');
      expect(note.find('[data-withheld-rows]').text()).not.toContain('Media link');
      expect(note.find('[data-blanked]').text()).toContain('Product: notes (1)');
      expect((await rehearse(report())).find('[data-withheld]').exists()).toBe(false);
   });

   it('blocks a move whose products are used by records left in the source', async () => {
      const wrapper = await rehearse(
         report({
            mode: 'move',
            left_behind: [
               {
                  table: 'project',
                  column: 'product_id',
                  refers_to: 'product',
                  refers_to_id: 'p1',
                  rows: 2,
                  blocks: true
               }
            ]
         }),
         'move'
      );

      expect(wizard.moveBlocked.value).toBe(true);
      expect(wizard.canRun.value).toBe(false);
      expect(wrapper.find('[data-move-blocked]').exists()).toBe(true);
      expect(wrapper.find('[data-left-behind]').text()).toContain('2');
   });

   it('does not block a move for left-behind rows that do not block', async () => {
      await rehearse(
         report({
            mode: 'move',
            left_behind: [
               {
                  table: 'note',
                  column: 'product_id',
                  refers_to: 'product',
                  refers_to_id: 'p1',
                  rows: 1,
                  blocks: false
               }
            ]
         }),
         'move'
      );
      expect(wizard.canRun.value).toBe(true);
   });

   it('labels conflicts with the SKUs and codes read through the views, in the source', async () => {
      api.rows.product = [
         { id: 'p1', sku: 'THO-MOP40-2P', display_name: 'Mop' },
         { id: 'p2', sku: 'THO-TIPS', display_name: 'Tips' }
      ];
      api.rows.supplier = [{ id: 's1', code: 'XY12', display_name: 'Xy Ltd' }];
      const wrapper = await rehearse(
         report({
            unresolved: 3,
            conflicts: [supplierConflict, skuConflict, gtinConflict]
         })
      );
      await flushPromises();

      expect(wrapper.find('[data-conflict="supplier:s1"]').text()).toContain('XY12');
      expect(wrapper.find('[data-conflict="sku:p1"]').text()).toContain('THO-MOP40-2P');
      expect(wrapper.find('[data-conflict="gtin:p2"]').text()).toContain('THO-TIPS');
      // The labels are read in the source tenant alone.
      const labelReads = api.requests.filter((r) => r.in.some(([c]) => c === 'id'));
      expect(labelReads.length).toBeGreaterThan(0);
      for (const read of labelReads) {
         expect(read.headers['x-tenant-id']).toBe('source');
         expect(read.headers['x-tenant-ids']).toBe('source');
      }
   });

   it('falls back to the id when the label is masked', async () => {
      api.rows.product = [{ id: 'p1', sku: null, display_name: null }];
      const wrapper = await rehearse(
         report({ unresolved: 1, conflicts: [{ ...skuConflict, source_id: 'p1abcdef123' }] })
      );
      expect(wrapper.find('[data-conflict="sku:p1"]').text()).toContain('p1abcdef');
   });

   it('decides a SKU conflict with a rename suffix and previews the new SKU', async () => {
      api.rows.product = [{ id: 'p1', sku: 'THO-MOP40-2P', display_name: 'Mop' }];
      const wrapper = await rehearse(report({ unresolved: 1, conflicts: [skuConflict] }));
      await flushPromises();

      wizard.decide('sku:p1', { action: 'rename' });
      await nextTick();
      await wrapper.find('[data-suffix]').setValue('-B');
      expect(wizard.decisions.value['sku:p1']).toEqual({ action: 'rename', suffix: '-B' });
      expect(wrapper.find('[data-new-sku]').text()).toBe('New SKU: THO-MOP40-2P-B');

      await wrapper.find('[data-suffix]').setValue('bad suffix!');
      expect(wrapper.find('[data-typed-reason]').text()).toBe(
         en.ops.transfer.conflict.suffix_format
      );
   });

   it('offers clear_gtin and skip for a GTIN conflict, and says what a skip drops', async () => {
      const wrapper = await rehearse(
         report({
            unresolved: 1,
            conflicts: [{ ...gtinConflict, skip_drops: { media: 2 } }]
         })
      );
      wizard.decide('gtin:p2', { action: 'skip' });
      await nextTick();
      expect(wrapper.find('[data-drops]').text()).toContain('2');
      wizard.decide('gtin:p2', { action: 'clear_gtin' });
      await nextTick();
      expect(wizard.decisions.value['gtin:p2']).toEqual({ action: 'clear_gtin' });
   });

   it('shows a code input for a new supplier code and maps to a supplier of the target', async () => {
      api.rows.supplier = [{ id: 'tc1', code: 'AB1', display_name: 'Acme' }];
      const wrapper = await rehearse(report({ unresolved: 1, conflicts: [supplierConflict] }));

      wizard.decide('supplier:s1', { action: 'new_code' });
      await nextTick();
      await flushPromises();
      expect(wrapper.find('[data-code]').exists()).toBe(true);
      await wrapper.find('[data-code]').setValue('ab12');
      expect(wizard.decisions.value['supplier:s1']).toEqual({ action: 'new_code', code: 'AB12' });

      // The target's suppliers are read in the target tenant alone.
      const lookup = api.requests.find((r) => r.in.some(([c]) => c === 'tenant_id'));
      expect(lookup?.headers['x-tenant-id']).toBe('branch');
      expect(lookup?.headers['x-tenant-ids']).toBe('branch');

      // A code the target has is refused with its reason.
      await wrapper.find('[data-code]').setValue('ab1');
      expect(wrapper.find('[data-typed-reason]').text()).toBe(en.ops.transfer.conflict.code_taken);
   });

   it('blocks the run while two suppliers get the same new code', async () => {
      const second = { ...supplierConflict, key: 'supplier:s2', source_id: 's2' };
      await rehearse(report({ unresolved: 0, conflicts: [supplierConflict, second] }));
      wizard.decide('supplier:s1', { action: 'new_code', code: 'AB1' });
      wizard.decide('supplier:s2', { action: 'new_code', code: 'AB1' });
      await rehearseTo(report({ conflicts: [supplierConflict, second] }));

      expect(wizard.duplicateCodes.value).toEqual(new Set(['supplier:s1', 'supplier:s2']));
      expect(wizard.canRun.value).toBe(false);
      wizard.decide('supplier:s2', { action: 'new_code', code: 'AB2' });
      await rehearseTo(report({ conflicts: [supplierConflict, second] }));
      expect(wizard.canRun.value).toBe(true);
   });

   it('shows a failed rehearsal in the wizard and rethrows it', async () => {
      await mountWizard();
      wizard.target.value = 'branch';
      await nextTick();
      api.rehearse.mockRejectedValueOnce({ message: 'transfer_forbidden' });

      await expect(wizard.rehearse()).rejects.toBeTruthy();
      await nextTick();
      expect(wizard.error.value).toBe(en.errors.transfer_forbidden);
   });
});

describe('apply and files', () => {
   const toApply = async (next: TransferReport = report(), mode: 'copy' | 'move' = 'copy') => {
      const wrapper = await mountWizard();
      wizard.target.value = 'branch';
      wizard.mode.value = mode;
      await nextTick();
      await rehearseTo(next);
      wizard.toApply();
      await flushPromises();
      return wrapper;
   };

   it("run sends the last report's hash and the transfer args, then copies the files", async () => {
      const done = row({ files_status: 'pending' });
      api.run.mockResolvedValueOnce(done);
      api.copy.mockResolvedValueOnce(row({ files_status: 'done' }));
      const wrapper = await toApply();

      expect(wrapper.find('[data-summary]').text()).toBe('Copy 3 records to Branch.');
      await wrapper.find('[data-run]').trigger('click');
      await flushPromises();

      expect(api.confirmed).toEqual(['Copy 3 records to Branch?']);
      expect(api.run).toHaveBeenCalledWith({
         args: {
            source_tenant: 'source',
            target_tenant: 'branch',
            mode: 'copy',
            decisions: {},
            product_ids: ['p1', 'p2']
         },
         reportHash: 'hash-1'
      });
      expect(api.copy).toHaveBeenCalledWith(done);
      expect(wizard.step.value).toBe('files');
      expect(wizard.transfer.value?.files_status).toBe('done');
   });

   it('does not copy when the run has no files', async () => {
      api.run.mockResolvedValueOnce(row({ files_status: 'done' }));
      const wrapper = await toApply();
      await wrapper.find('[data-run]').trigger('click');
      await flushPromises();
      expect(api.copy).not.toHaveBeenCalled();
      expect(wizard.step.value).toBe('files');
   });

   it('a move confirms the removal from the source', async () => {
      api.run.mockResolvedValueOnce(row({ mode: 'move' }));
      const wrapper = await toApply(report({ mode: 'move' }), 'move');
      await wrapper.find('[data-run]').trigger('click');
      await flushPromises();
      expect(api.confirmed[0]).toContain('removed from the source');
   });

   it('a stale report is refused: it says so and offers to rehearse again', async () => {
      api.run.mockRejectedValueOnce({ message: 'transfer_report_stale' });
      const wrapper = await toApply();

      await wrapper.find('[data-run]').trigger('click');
      await flushPromises();
      expect(wizard.step.value).toBe('apply');
      expect(wizard.runStale.value).toBe(true);
      expect(wrapper.find('[data-stale]').text()).toBe(en.ops.transfer.apply.stale);
      expect(wrapper.find('[data-run-error]').text()).toBe(en.errors.transfer_report_stale);
      expect(wrapper.find('[data-run]').exists()).toBe(false);

      api.rehearse.mockResolvedValueOnce(report({ report_hash: 'hash-2' }));
      await wrapper.find('[data-rehearse-again]').trigger('click');
      await flushPromises();
      expect(wizard.step.value).toBe('report');
      expect(wizard.runStale.value).toBe(false);
      expect(wizard.report.value?.report_hash).toBe('hash-2');
   });

   it('shows another failed run in the wizard, without offering a re-rehearsal', async () => {
      api.run.mockRejectedValueOnce({ message: 'transfer_permissions_required' });
      const wrapper = await toApply();
      await wrapper.find('[data-run]').trigger('click');
      await flushPromises();

      expect(wrapper.find('[data-run-error]').text()).toBe(en.errors.transfer_permissions_required);
      expect(wrapper.find('[data-stale]').exists()).toBe(false);
      expect(wrapper.find('[data-run]').exists()).toBe(true);
   });
});

describe('target step: unfinished transfers', () => {
   it('lists the pending transfers of a target refused for them, and retries the copy', async () => {
      api.options = {
         source_writable: true,
         targets: [
            {
               id: 'blocked',
               display_name: 'Blocked Ltd',
               same_company: false,
               refusal: 'transfer_files_pending'
            },
            { id: 'other', display_name: 'Other Ltd', same_company: false, refusal: null }
         ]
      };
      api.pending = [
         row({ tenant_id: 'blocked', files_status: 'partial', missing_files: ['t/a'] })
      ];
      api.retry.mockResolvedValueOnce(row());
      const wrapper = await mountWizard();

      // Only the refused target's transfers are asked for.
      expect(api.pendingReads).toEqual([['blocked']]);
      const section = wrapper.find('[data-pending-target]');
      expect(section.text()).toContain('Blocked Ltd');
      expect(section.text()).toContain(en.ops.transfer.pending.title);
      expect(section.text()).toContain('1 file could not be copied.');

      await section.find('[data-retry] button').trigger('click');
      await flushPromises();
      expect(api.retry).toHaveBeenCalledWith(api.pending[0]);
   });

   it('shows nothing when no target is blocked by files', async () => {
      const wrapper = await mountWizard();
      expect(wrapper.find('[data-pending-target]').exists()).toBe(false);
   });
});

describe('result step', () => {
   const mountResult = (transfer: TransferRow) =>
      mount(ResultStep, {
         props: { transfer, report: report(), progress: null, copying: false },
         global: { plugins, directives: { tooltip: {} } }
      });

   it('reads the transfer again with the source and the target in scope', () => {
      mountResult(row());
      expect(api.transferReads).toEqual([['tr', 'source', 'branch']]);
   });

   it('says what is left when a file needs an administrator', () => {
      const wrapper = mountResult(
         row({ files_status: 'partial', missing_files: ['mismatch:branch/a.png'] })
      );
      expect(wrapper.find('[data-files-admin]').text()).toContain('needs an administrator');
      expect(wrapper.find('[data-retry]').exists()).toBe(false);
   });

   it('shows a loading state, not a stale notice, until the refetch lands', async () => {
      const { useTransfer } = await import('@/api/transfer');
      void useTransfer;
      const wrapper = mountResult(row({ files_status: 'pending' }));
      // The stand-in read is settled: the notice shows.
      expect(wrapper.find('[data-loading]').exists()).toBe(false);
      expect(wrapper.find('[data-files-status]').exists()).toBe(true);
   });

   it('shows the progress while the files copy', () => {
      const wrapper = mount(ResultStep, {
         props: {
            transfer: row({ files_status: 'pending' }),
            report: report({ files: 4 }),
            progress: { done: 1, total: 4 },
            copying: true
         },
         global: { plugins, directives: { tooltip: {} } }
      });
      expect(wrapper.find('[data-progress]').text()).toContain('Copying files: 1 of 4');
      expect(wrapper.find('[data-files-status]').exists()).toBe(false);
   });

   it('downloads the ID map', async () => {
      const blobs: Blob[] = [];
      const create = vi.spyOn(URL, 'createObjectURL').mockImplementation((blob) => {
         blobs.push(blob as Blob);
         return 'blob:x';
      });
      const revoke = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
      const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
      const wrapper = mountResult(row({ id_map: { product: { b: 'y', a: 'x' } } as never }));

      await wrapper.find('[data-id-map] button, button[data-id-map]').trigger('click');
      expect(click).toHaveBeenCalledTimes(1);
      const text = await blobs[0]!.text();
      expect(text).toContain('table,source_id,target_id\r\nproduct,a,x\r\nproduct,b,y');
      create.mockRestore();
      revoke.mockRestore();
      click.mockRestore();
   });

   it('offers no ID map when the column is hidden from the caller', () => {
      const wrapper = mountResult(row({ id_map: null as never }));
      expect(wrapper.find('[data-id-map]').exists()).toBe(false);
   });
});

describe('product list: copy or move to another company', () => {
   // The table is a stand-in: its toolbar and the selection it reports.
   const Table = defineComponent({
      name: 'ResourceTable',
      props: {
         selection: { type: Array, default: undefined },
         selectionMode: String,
         filters: { type: Object, default: undefined }
      },
      emits: ['update:selection', 'update:filters'],
      setup:
         (_props, { slots }) =>
         () =>
            h('div', slots.header?.())
   });
   const mountList = () =>
      mount(ProductIndex, {
         global: {
            plugins,
            directives: { tooltip: {} },
            stubs: { ResourceTable: Table, CustomLink: true, teleport: true, Dialog: true }
         }
      });

   it('needs one tenant and opens the wizard with the selected products', async () => {
      const wrapper = mountList();
      const table = wrapper.findComponent(Table);
      const button = () => wrapper.find('[data-transfer-open] button');
      const select = async (rows: Record<string, unknown>[]) => {
         table.vm.$emit('update:selection', rows);
         await nextTick();
      };

      expect(button().attributes('disabled')).toBeDefined();
      expect(button().text()).toBe(en.ops.transfer.open);

      await select([
         { id: 'p1', tenant_id: 'k1' },
         { id: 'p2', tenant_id: 'k2' }
      ]);
      expect(button().attributes('disabled')).toBeDefined();

      await select([
         { id: 'p1', tenant_id: 'k1' },
         { id: 'p2', tenant_id: 'k1' }
      ]);
      expect(button().attributes('disabled')).toBeUndefined();
      expect(button().text()).toBe('Copy or move 2 to another company');

      await button().trigger('click');
      expect(api.push).toHaveBeenCalledWith({
         name: 'ops-transfer',
         query: expect.objectContaining({ source_tenant: 'k1', product_ids: 'p1,p2' })
      });
   });

   it('shows the unfinished transfers of the scope, only to those who may transfer', () => {
      api.pending = [row({ files_status: 'pending' })];
      const wrapper = mountList();
      expect(wrapper.find('[data-pending-transfers]').exists()).toBe(true);

      ability.update([{ action: 'select', subject: 'product' }]);
      expect(mountList().find('[data-pending-transfers]').exists()).toBe(false);
   });

   it('follows the transfer right: read and create', () => {
      ability.update([
         { action: 'select', subject: 'product' },
         { action: 'select', subject: 'transfer' }
      ]);
      expect(mountList().find('[data-transfer-open]').exists()).toBe(false);

      ability.update([{ action: 'create', subject: 'transfer' }]);
      expect(mountList().find('[data-transfer-open]').exists()).toBe(false);

      ability.update([
         { action: 'select', subject: 'transfer' },
         { action: 'insert', subject: 'transfer' }
      ]);
      expect(mountList().find('[data-transfer-open]').exists()).toBe(true);
   });
});
