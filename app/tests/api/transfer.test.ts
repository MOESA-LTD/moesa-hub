import {
   asIdMap,
   asTransferFiles,
   asTransferReport,
   copyTransferFiles,
   fetchTransferOptions,
   idMapCsv,
   rehearseTransfer,
   runTransfer,
   transferErrorText,
   transferFilesState,
   useRunTransfer,
   useTransfer,
   type TransferArgs,
   type TransferRow
} from '@/api/transfer';
import { QueryClient, VueQueryPlugin } from '@tanstack/vue-query';
import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { computed, defineComponent, h } from 'vue';
import { ZodError } from 'zod';

// The RPCs and the media bucket, recording what the API asks of them.
const mock = vi.hoisted(() => ({
   rpc: vi.fn(),
   rpcResults: {} as Record<string, unknown>,
   rpcErrors: {} as Record<string, Error>,
   // The table reads, as the builder calls each makes: [method, ...args].
   calls: [] as unknown[][],
   tableResult: null as unknown,
   copy: vi.fn(),
   remove: vi.fn(),
   bucket: vi.fn()
}));

vi.mock('@/lib/supabase', () => {
   const supabase = {
      rpc: (name: string, args: unknown) => {
         mock.rpc(name, args);
         return {
            throwOnError: () =>
               mock.rpcErrors[name]
                  ? Promise.reject(mock.rpcErrors[name])
                  : Promise.resolve({ data: mock.rpcResults[name] })
         };
      },
      from: (table: string) => {
         mock.calls.push(['from', table]);
         const builder: Record<string, unknown> = new Proxy(
            {},
            {
               get: (_target, method: string) =>
                  method === 'throwOnError'
                     ? () => Promise.resolve({ data: mock.tableResult })
                     : method === 'then'
                       ? undefined
                       : (...rest: unknown[]) => {
                            mock.calls.push([
                               method,
                               ...rest.filter((a) => !(a instanceof AbortSignal))
                            ]);
                            return builder;
                         }
            }
         );
         return builder;
      },
      storage: {
         from: (bucket: string) => {
            mock.bucket(bucket);
            return { copy: mock.copy, remove: mock.remove };
         }
      }
   };
   return { supabase, publicSchema: supabase };
});

vi.mock('@/api/useTenantKey', () => ({ useTenantKey: () => computed(() => 's') }));

const args: TransferArgs = {
   source_tenant: 's',
   target_tenant: 't',
   mode: 'copy',
   decisions: { 'sku:p1': { action: 'rename', suffix: '-B' } },
   product_ids: ['p1', 'p2']
};

const report = {
   mode: 'copy',
   source_tenant: 's',
   target_tenant: 't',
   product_ids: ['p1', 'p2'],
   counts: { product: 2, media: 1 },
   excluded: ['supplier', 'supplier_contact', 'sourcing'],
   conflicts: [
      {
         key: 'supplier:a',
         kind: 'supplier_code',
         table: 'supplier',
         source_id: 'a',
         existing_id: 'x',
         actions: ['map', 'new_code']
      },
      {
         key: 'sku:p1',
         kind: 'sku',
         table: 'product',
         source_id: 'p1',
         existing_id: 'y',
         actions: ['rename', 'skip', 'teleport'],
         skip_drops: { media: 1 },
         taken: true
      },
      {
         key: 'gtin:p2',
         kind: 'gtin',
         table: 'product',
         source_id: 'p2',
         existing_id: null,
         actions: ['clear_gtin', 'skip']
      }
   ],
   left_behind: [
      {
         table: 'project',
         column: 'product_id',
         refers_to: 'product',
         refers_to_id: 'p1',
         rows: 2,
         blocks: true
      }
   ],
   left_behind_links: { sourcing: 2 },
   cleared: [],
   settings_gaps: [{ rule: 'spec_sheet_required', table: 'product', source_id: 'p1' }],
   files: 2,
   unresolved: 1,
   report_hash: 'h'
};

const row = (overrides: Partial<TransferRow> = {}): TransferRow =>
   ({
      id: 'tr',
      tenant_id: 't',
      source_tenant_id: 's',
      product_ids: ['p1'],
      mode: 'move',
      started_by: 'u',
      report: {},
      decisions: {},
      id_map: {},
      files: [
         { media_id: 'm1', from: 's/a', to: 't/a', keep_source: false },
         { media_id: 'm2', from: 's/b', to: 't/b', keep_source: true },
         { media_id: 'm3', from: 's/c', to: 't/c', keep_source: false }
      ],
      files_status: 'pending',
      missing_files: [],
      audit_transaction_ids: [],
      xact_id: null,
      created_at: '',
      updated_at: '',
      ...overrides
   }) as TransferRow;

const mountHook = <T>(hook: () => T, queryClient = new QueryClient()) => {
   let result!: T;
   mount(
      defineComponent({
         setup() {
            result = hook();
            return () => h('div');
         }
      }),
      { global: { plugins: [[VueQueryPlugin, { queryClient }]] } }
   );
   return result;
};

beforeEach(() => {
   mock.rpc.mockReset();
   mock.rpcResults = {};
   mock.rpcErrors = {};
   mock.calls = [];
   mock.tableResult = null;
   mock.copy.mockReset().mockResolvedValue({ data: {}, error: null });
   mock.remove.mockReset().mockResolvedValue({ data: [], error: null });
   mock.bucket.mockReset();
});

describe('fetchTransferOptions', () => {
   it('asks for the targets of the source', async () => {
      const options = { source_writable: true, targets: [] };
      mock.rpcResults.transfer_options = options;

      await expect(fetchTransferOptions('s')).resolves.toEqual(options);
      expect(mock.rpc).toHaveBeenCalledWith('transfer_options', { source_tenant: 's' });
   });
});

describe('rehearseTransfer and runTransfer', () => {
   it('transferProducts sends source, target, product ids and mode only', async () => {
      mock.rpcResults.transfer_products = report;

      await rehearseTransfer(args);

      // No customer, no path: the decisions and the rehearsal flag are the only other keys.
      expect(mock.rpc).toHaveBeenCalledWith('transfer_products', {
         source_tenant: 's',
         target_tenant: 't',
         product_ids: ['p1', 'p2'],
         mode: 'copy',
         decisions: { 'sku:p1': { action: 'rename', suffix: '-B' } },
         rehearse: true
      });
   });

   it('runs with the rehearsal hash inside the decisions', async () => {
      mock.rpcResults.transfer_products = row({ mode: 'copy' });

      await runTransfer(args, 'h');

      expect(mock.rpc).toHaveBeenCalledWith('transfer_products', {
         source_tenant: 's',
         target_tenant: 't',
         product_ids: ['p1', 'p2'],
         mode: 'copy',
         decisions: { 'sku:p1': { action: 'rename', suffix: '-B' }, report_hash: 'h' },
         rehearse: false
      });
   });

   it('narrows the report: unknown actions are dropped, taken and links are kept', async () => {
      mock.rpcResults.transfer_products = report;

      const result = await rehearseTransfer(args);

      expect(result.conflicts[1]!.actions).toEqual(['rename', 'skip']);
      expect(result.conflicts[1]!.taken).toBe(true);
      expect(result.excluded).toEqual(['supplier', 'supplier_contact', 'sourcing']);
      expect(result.left_behind_links).toEqual({ sourcing: 2 });
   });
});

describe('copyTransferFiles', () => {
   it('copies only the missing files of a partial transfer, then checks them', async () => {
      const partial = row({ mode: 'copy', files_status: 'partial', missing_files: ['t/b'] });
      mock.rpcResults.transfer_check_files = {
         ...partial,
         files_status: 'done',
         missing_files: []
      };

      const checked = await copyTransferFiles(partial);

      expect(mock.bucket).toHaveBeenCalledWith('media');
      expect(mock.copy.mock.calls).toEqual([['s/b', 't/b']]);
      expect(mock.rpc).toHaveBeenCalledWith('transfer_check_files', { transfer_id: 'tr' });
      expect(checked.files_status).toBe('done');
      expect(mock.remove).not.toHaveBeenCalled();
   });

   it('copies every file of a pending transfer and reports the progress', async () => {
      mock.rpcResults.transfer_check_files = row({ mode: 'copy', files_status: 'done' });
      const progress = vi.fn();

      await copyTransferFiles(row({ mode: 'copy' }), progress);

      expect(mock.copy.mock.calls).toEqual([
         ['s/a', 't/a'],
         ['s/b', 't/b'],
         ['s/c', 't/c']
      ]);
      expect(progress.mock.calls).toEqual([
         [{ done: 0, total: 3 }],
         [{ done: 1, total: 3 }],
         [{ done: 2, total: 3 }],
         [{ done: 3, total: 3 }]
      ]);
      expect(mock.remove).not.toHaveBeenCalled();
   });

   it('never copies a mismatch: only an administrator can fix it', async () => {
      const partial = row({
         files_status: 'partial',
         missing_files: ['mismatch:t/a', 't/c']
      });
      mock.rpcResults.transfer_check_files = partial;

      await copyTransferFiles(partial);

      expect(mock.copy.mock.calls).toEqual([['s/c', 't/c']]);
      expect(mock.remove).not.toHaveBeenCalled();
   });

   it('keeps the source files while the copy is partial', async () => {
      const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
      mock.copy.mockImplementation((from: string) =>
         Promise.resolve({ data: null, error: from === 's/c' ? new Error('denied') : null })
      );
      mock.rpcResults.transfer_check_files = row({
         files_status: 'partial',
         missing_files: ['t/c']
      });

      const checked = await copyTransferFiles(row());

      expect(checked.missing_files).toEqual(['t/c']);
      expect(mock.remove).not.toHaveBeenCalled();
      expect(warn).toHaveBeenCalledWith('Transfer files not copied', 'tr', [
         { file: expect.objectContaining({ from: 's/c' }), error: new Error('denied') }
      ]);
      warn.mockRestore();
   });

   it('removes, once done, only the moved sources marked keep_source false', async () => {
      mock.rpcResults.transfer_check_files = row({ files_status: 'done' });

      await copyTransferFiles(row());

      expect(mock.remove).toHaveBeenCalledTimes(1);
      expect(mock.remove).toHaveBeenCalledWith(['s/a', 's/c']);
   });

   it('removes the sources in batches of 1000', async () => {
      const files = Array.from({ length: 1001 }, (_, i) => ({
         media_id: `m${i}`,
         from: `s/${i}`,
         to: `t/${i}`,
         keep_source: false
      }));
      mock.rpcResults.transfer_check_files = row({ files, files_status: 'done' });

      await copyTransferFiles(row({ files, files_status: 'done' }));

      expect(mock.remove.mock.calls.map(([paths]) => paths.length)).toEqual([1000, 1]);
   });

   it('never removes the sources of a copy', async () => {
      mock.rpcResults.transfer_check_files = row({ mode: 'copy', files_status: 'done' });

      await copyTransferFiles(row({ mode: 'copy' }));

      expect(mock.remove).not.toHaveBeenCalled();
   });

   it('counts an object already there as copied, and never throws on another error', async () => {
      const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
      mock.copy
         .mockResolvedValueOnce({ data: null, error: { message: 'The resource already exists' } })
         .mockResolvedValueOnce({ data: null, error: { message: 'Bucket not reachable' } })
         .mockRejectedValueOnce(new Error('network'));
      mock.rpcResults.transfer_check_files = row({ mode: 'copy', files_status: 'partial' });

      await expect(copyTransferFiles(row({ mode: 'copy' }))).resolves.toBeTruthy();
      expect(warn).toHaveBeenCalledTimes(1);
      warn.mockRestore();
   });

   it('throws on malformed files before copying', async () => {
      await expect(copyTransferFiles(row({ files: [{ nope: 1 }] as never }))).rejects.toThrow(
         ZodError
      );
      expect(mock.copy).not.toHaveBeenCalled();
   });
});

describe('transferFilesState', () => {
   it('separates the files to copy again from the ones that need an administrator', () => {
      expect(
         transferFilesState(
            row({ files_status: 'partial', missing_files: ['t/a', 'mismatch:t/b', 'mismatch:t/c'] })
         )
      ).toEqual({ retryable: 1, needsAdmin: 2, canCopy: true });
      expect(transferFilesState(row({ files_status: 'pending' }))).toEqual({
         retryable: 3,
         needsAdmin: 0,
         canCopy: true
      });
      // Masked files cannot be copied by this caller.
      expect(
         transferFilesState(row({ files: null as never, files_status: 'pending' })).canCopy
      ).toBe(false);
   });
});

describe('useRunTransfer', () => {
   it('runs and marks both tenants stale', async () => {
      const queryClient = new QueryClient();
      const invalidate = vi.spyOn(queryClient, 'invalidateQueries');
      mock.rpcResults.transfer_products = row({ mode: 'copy' });

      const run = mountHook(useRunTransfer, queryClient);
      const result = await run.mutateAsync({ args, reportHash: 'h' });

      expect(result.id).toBe('tr');
      const { predicate } = invalidate.mock.calls[0]![0] as unknown as {
         predicate: (query: { queryKey: unknown[] }) => boolean;
      };
      const stale = (key: unknown[]) => predicate({ queryKey: key });
      expect(stale(['tenant', 's', 'product'])).toBe(true);
      expect(stale(['tenant', 'x,t', 'product'])).toBe(true);
      expect(stale(['tenant', 'x', 'product'])).toBe(false);
   });
});

describe('transfer reads', () => {
   it('reads a transfer with the source and the target in scope, keyed by the target', async () => {
      const queryClient = new QueryClient();
      mock.tableResult = row();
      const query = mountHook(() => useTransfer('tr', 's', 't'), queryClient);

      await vi.waitFor(() => expect(query.data.value).toEqual(row()));
      expect(mock.calls).toEqual([
         ['from', 'transfer'],
         ['select', '*'],
         ['eq', 'id', 'tr'],
         ['abortSignal'],
         ['setHeader', 'x-tenant-id', 't'],
         ['setHeader', 'x-tenant-ids', 's,t'],
         ['maybeSingle']
      ]);
      expect(queryClient.getQueryData(['tenant', 't', 'transfer', 'detail', 'tr'])).toEqual(row());
   });

   it('waits for the target tenant', () => {
      const query = mountHook(() => useTransfer('tr', 's', null));
      expect(query.isFetching.value).toBe(false);
      expect(mock.calls).toEqual([]);
   });
});

describe('idMapCsv', () => {
   it('writes the map by table, then source id', () => {
      expect(idMapCsv({ product: { b: 'y', a: 'x' }, media: { m: 'n' } })).toBe(
         'table,source_id,target_id\r\nmedia,m,n\r\nproduct,a,x\r\nproduct,b,y\r\n'
      );
   });
});

describe('narrowing the Json columns', () => {
   it('reads a valid id map unchanged and throws on a malformed one', () => {
      expect(asIdMap({ product: { a: 'b' } })).toEqual({ product: { a: 'b' } });
      expect(() => asIdMap({ product: 'x' })).toThrow(ZodError);
   });

   it('reads valid files unchanged and throws on malformed ones', () => {
      const files = [{ media_id: 'm', from: 'a', to: 'b', keep_source: true }];
      expect(asTransferFiles(files)).toEqual(files);
      expect(() => asTransferFiles([{ media_id: 'm' }])).toThrow(ZodError);
   });

   it('reads a report, an unknown conflict kind included', () => {
      const unknown = { ...report.conflicts[0], kind: 'mystery' };
      const result = asTransferReport({ ...report, conflicts: [unknown] });
      expect(result.conflicts[0]!.kind).toBe('unknown');
   });

   it('throws on a report of another shape', () => {
      expect(() => asTransferReport({ counts: 'x' })).toThrow(ZodError);
   });
});

describe('transferErrorText', () => {
   it.each([
      'transfer_mode_invalid',
      'transfer_same_tenant',
      'transfer_forbidden',
      'transfer_target_unavailable',
      'transfer_permissions_required',
      'transfer_field_rights_required',
      'transfer_source_read_only',
      'transfer_files_pending',
      'transfer_report_stale',
      'transfer_decision_required',
      'transfer_decision_invalid',
      'transfer_code_invalid',
      'transfer_product_in_use',
      'transfer_products_invalid',
      'transfer_package_invalid',
      'transfer_not_found'
   ])('has a message for %s', async (code) => {
      const { default: i18n } = await import('@plugins/i18n');
      const en = (await import('@/plugins/i18n/locales/en/index.json')).default;
      i18n.setLocaleMessage('en', en);
      const text = transferErrorText({ message: code });
      expect(text).not.toBe(code);
      expect(text).not.toBe('');
   });
});
