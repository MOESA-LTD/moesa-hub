import {
   applyFixedFilters,
   applyTableMeta,
   hasActiveFilters,
   quoteValue,
   type TableMeta
} from '@/api/postgrest/tableQuery';
import { FilterMatchMode, FilterOperator } from '@primevue/core/api';
import { createClient } from '@supabase/supabase-js';
import dayjs from 'dayjs';
import { describe, expect, it } from 'vitest';

// A real supabase-js builder; nothing is sent until it is awaited, so the URL can be inspected.
const client = createClient('http://localhost', 'anon-key');
// `url` is protected on the builder; it is only read here to assert the generated request.
const urlOf = (builder: unknown) => (builder as { url: URL }).url;
const params = (meta: TableMeta) =>
   urlOf(applyTableMeta(client.from('client').select('*'), meta)).searchParams;

const and = (constraints: Array<{ value: unknown; matchMode: string }>, dataType?: string) => ({
   operator: FilterOperator.AND,
   dataType,
   constraints
});

describe('quoteValue', () => {
   it('quotes values with PostgREST reserved characters', () => {
      expect(quoteValue('plain')).toBe('plain');
      expect(quoteValue('a,b')).toBe('"a,b"');
      expect(quoteValue('x) or(id.gt.0')).toBe('"x) or(id.gt.0"');
      expect(quoteValue('say "hi"')).toBe('"say \\"hi\\""');
   });
});

describe('applyTableMeta filters', () => {
   it('ANDs column constraints', () => {
      const search = params({
         filters: {
            display_name: and([{ value: 'jo', matchMode: FilterMatchMode.CONTAINS }]),
            email: and([{ value: '@example', matchMode: FilterMatchMode.ENDS_WITH }])
         }
      });
      expect(search.get('display_name')).toBe('ilike.*jo*');
      expect(search.get('email')).toBe('ilike.*@example');
   });

   it('keeps commas in column values without breaking the filter', () => {
      expect(
         params({
            filters: { display_name: and([{ value: 'a,b', matchMode: FilterMatchMode.CONTAINS }]) }
         }).get('display_name')
      ).toBe('ilike.*a,b*');
   });

   it('matches "not contains" anywhere in the value', () => {
      expect(
         params({
            filters: { email: and([{ value: 'spam', matchMode: FilterMatchMode.NOT_CONTAINS }]) }
         }).get('email')
      ).toBe('not.ilike.*spam*');
   });

   it('gives each "match any" column its own OR group', () => {
      const search = params({
         filters: {
            display_name: {
               operator: FilterOperator.OR,
               constraints: [
                  { value: 'ann', matchMode: FilterMatchMode.STARTS_WITH },
                  { value: 'bob', matchMode: FilterMatchMode.STARTS_WITH }
               ]
            },
            nationality: {
               operator: FilterOperator.OR,
               constraints: [
                  { value: 'TR', matchMode: FilterMatchMode.EQUALS },
                  { value: 'DE', matchMode: FilterMatchMode.EQUALS }
               ]
            }
         }
      });
      expect(search.getAll('or')).toEqual([
         '(display_name.ilike.ann*,display_name.ilike.bob*)',
         '(nationality.eq.TR,nationality.eq.DE)'
      ]);
   });

   it('searches all top-level columns for the global filter, quoting the value', () => {
      const search = params({
         filters: {
            global: { value: 'a,b', matchMode: FilterMatchMode.CONTAINS },
            display_name: and([{ value: null, matchMode: FilterMatchMode.CONTAINS }]),
            email: and([{ value: null, matchMode: FilterMatchMode.CONTAINS }]),
            'product.brand': and([{ value: null, matchMode: FilterMatchMode.CONTAINS }]),
            quantity: and([{ value: null, matchMode: FilterMatchMode.EQUALS }], 'numeric')
         }
      });
      expect(search.getAll('or')).toEqual(['(display_name.ilike."*a,b*",email.ilike."*a,b*")']);
   });

   it('includes numeric columns in the global search for numeric input', () => {
      const search = params({
         filters: {
            global: { value: '42', matchMode: FilterMatchMode.CONTAINS },
            display_name: and([{ value: null, matchMode: FilterMatchMode.CONTAINS }]),
            quantity: and([{ value: null, matchMode: FilterMatchMode.EQUALS }], 'numeric')
         }
      });
      expect(search.getAll('or')).toEqual(['(display_name.ilike.*42*,quantity.eq.42)']);
   });

   // A list with enum or boolean filter columns (products: status, signed spec) names the text
   // columns its keyword search reads; comparing an enum as text would fail the request.
   it('searches only the keyword columns a list names, as text', () => {
      const search = urlOf(
         applyTableMeta(
            client.from('client').select('*'),
            {
               filters: {
                  global: { value: 'oka', matchMode: FilterMatchMode.CONTAINS },
                  sku: and([{ value: null, matchMode: FilterMatchMode.STARTS_WITH }]),
                  status: and([{ value: null, matchMode: FilterMatchMode.EQUALS }])
               }
            },
            { keywordColumns: ['sku', 'display_name', 'gtin'] }
         )
      ).searchParams;
      expect(search.getAll('or')).toEqual([
         '(sku.ilike.*oka*,display_name.ilike.*oka*,gtin.ilike.*oka*)'
      ]);
      expect(search.has('status')).toBe(false);
   });

   it('skips empty constraints and invalid typed values', () => {
      const search = params({
         filters: {
            display_name: and([{ value: '', matchMode: FilterMatchMode.CONTAINS }]),
            quantity: and([{ value: 'abc', matchMode: FilterMatchMode.EQUALS }], 'numeric'),
            created_at: and([{ value: 'not a date', matchMode: FilterMatchMode.DATE_IS }], 'date')
         }
      });
      expect([...search.keys()].filter((key) => key !== 'select')).toEqual([]);
   });

   it('expands "between" into a closed range', () => {
      expect(
         params({
            filters: { unit_cost: and([{ value: [10, 20], matchMode: FilterMatchMode.BETWEEN }]) }
         }).getAll('unit_cost')
      ).toEqual(['gte.10', 'lte.20']);
   });

   it('filters a whole local day, including the UTC offset', () => {
      const day = new Date(2024, 4, 1);
      const [from, to] = params({
         filters: { created_at: and([{ value: day, matchMode: FilterMatchMode.DATE_IS }], 'date') }
      }).getAll('created_at');

      expect(from.startsWith('gte.')).toBe(true);
      expect(to.startsWith('lt.')).toBe(true);
      expect(dayjs(from.slice(4)).valueOf()).toBe(day.getTime());
      expect(dayjs(to.slice(3)).valueOf()).toBe(new Date(2024, 4, 2).getTime());
   });

   it('excludes a day with an OR group', () => {
      const day = new Date(2024, 4, 1);
      const [group] = params({
         filters: {
            created_at: and([{ value: day, matchMode: FilterMatchMode.DATE_IS_NOT }], 'date')
         }
      }).getAll('or');
      expect(group).toMatch(/^\(created_at\.lt\."[^"]+",created_at\.gte\."[^"]+"\)$/);
   });
});

describe('applyTableMeta sorting and paging', () => {
   it('orders by columns, including embedded ones', () => {
      expect(
         params({
            multiSortMeta: [
               { field: 'display_name', order: 1 },
               { field: 'product.category.display_name', order: -1 }
            ]
         }).get('order')
      ).toBe('display_name.asc,product(category(display_name)).desc');
   });

   it('pages with offset and limit', () => {
      const search = params({ first: 10, rows: 5 });
      expect(search.get('offset')).toBe('10');
      expect(search.get('limit')).toBe('5');
   });

   // Without a unique last key, rows that tie on the sorted columns come back in any order, so
   // one row shows on two pages and another on none.
   it('breaks ties on the key when paging, so pages neither repeat nor skip rows', () => {
      expect(
         params({ first: 10, rows: 5, multiSortMeta: [{ field: 'status', order: 1 }] }).get('order')
      ).toBe('status.asc,id.asc');
      expect(params({ first: 0, rows: 5 }).get('order')).toBe('id.asc');
      expect(
         params({ first: 0, rows: 5, multiSortMeta: [{ field: 'id', order: -1 }] }).get('order')
      ).toBe('id.desc');
      const keyed = urlOf(
         applyTableMeta(
            client.from('client').select('*'),
            { first: 0, rows: 5, multiSortMeta: [{ field: 'status', order: 1 }] },
            { tiebreaker: 'code' }
         )
      ).searchParams;
      expect(keyed.get('order')).toBe('status.asc,code.asc');
   });

   it('can skip paging, e.g. for count-only queries', () => {
      const search = urlOf(
         applyTableMeta(
            client.from('client').select('*'),
            { first: 10, rows: 5 },
            { paginate: false }
         )
      ).searchParams;
      expect(search.has('limit')).toBe(false);
   });
});

describe('applyFixedFilters', () => {
   it('keeps rows in or out of a list, or with a column empty', () => {
      const search = urlOf(
         applyFixedFilters(client.from('product').select('*') as never, [
            { column: 'tenant_id', in: ['t1', 't2'] },
            { column: 'status', notIn: ['archived'] },
            { column: 'parent_id', isNull: true }
         ])
      ).searchParams;
      expect(search.get('tenant_id')).toBe('in.(t1,t2)');
      expect(search.get('status')).toBe('not.in.(archived)');
      expect(search.get('parent_id')).toBe('is.null');
   });
});

describe('hasActiveFilters', () => {
   it('tells a keyword or a column value from an empty filter state', () => {
      expect(hasActiveFilters(null)).toBe(false);
      expect(
         hasActiveFilters({
            global: { value: null, matchMode: FilterMatchMode.CONTAINS },
            sku: and([{ value: null, matchMode: FilterMatchMode.STARTS_WITH }])
         })
      ).toBe(false);
      expect(
         hasActiveFilters({ global: { value: 'oka', matchMode: FilterMatchMode.CONTAINS } })
      ).toBe(true);
      expect(
         hasActiveFilters({ sku: and([{ value: 'OKA', matchMode: FilterMatchMode.STARTS_WITH }]) })
      ).toBe(true);
      expect(hasActiveFilters({ tags: { value: [], matchMode: FilterMatchMode.IN } })).toBe(false);
   });
});
