import { fieldLabel, fieldLabelKeys, humaniseField } from '@/lib/fieldLabel';
import en from '@/plugins/i18n/locales/en/index.json';
import { describe, expect, it } from 'vitest';

const lookup = (key: string): string | undefined =>
   key
      .split('.')
      .reduce<unknown>(
         (o, k) => (o && typeof o === 'object' ? (o as Record<string, unknown>)[k] : undefined),
         en
      ) as string | undefined;
const t = (key: string) => lookup(key) ?? key;
const te = (key: string) => typeof lookup(key) === 'string';

describe('fieldLabel', () => {
   it("takes the table's own form first, then the form it is edited in, then the shared fields", () => {
      expect(fieldLabelKeys('sourcing', 'notes')).toEqual([
         'ops.sourcing.fields.notes',
         'ops.product.fields.notes',
         'fields.notes'
      ]);
      expect(fieldLabel('product', 'purchase_price', t, te)).toBe('Purchase price');
      expect(fieldLabel('sourcing', 'sell_price_eur', t, te)).toBe('Sell price (EUR)');
      expect(fieldLabel('purchase_order_line', 'unit_price', t, te)).toBe('Unit price');
      expect(fieldLabel('user', 'email', t, te)).toBe(t('fields.email'));
   });

   it('falls back to the column name as words', () => {
      expect(humaniseField('pi_deposit_amount')).toBe('Pi deposit amount');
      expect(fieldLabel('purchase_order', 'pi_deposit_amount', t, te)).toBe('Pi deposit amount');
      expect(fieldLabel('transfer', 'id_map', t, te)).toBe('Id map');
   });
});
