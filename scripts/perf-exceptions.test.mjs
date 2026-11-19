// The perf budget's accepted exceptions (perf-exceptions.mjs). Dependency-free: node builtins only.
import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { classify, parseBudget, readExceptions, verdict } from './perf-exceptions.mjs';

const LIST = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'supabase', 'perf', 'accepted_exceptions.json');
const exceptions = readExceptions(LIST);
const out = (entries) =>
   `NOTICE:  x\npsql:<stdin>:370: ERROR:  budget: ${entries}\nCONTEXT:  PL/pgSQL function inline_code_block line 9 at RAISE\n`;

test('the list documents the internal full-table aggregates Q3 and Q4', () => {
   assert.deepEqual(
      exceptions.map((e) => `${e.actor} ${e.query}`),
      ['internal Q3 count', 'internal Q4 sum(price) per tenant']
   );
   for (const e of exceptions) assert.ok(e.reason.length > 20, `${e.query} has a reason`);
});

test('reads the over-budget reads from the budget error, parentheses in names included', () => {
   assert.deepEqual(parseBudget(out('internal Q4 sum(price) per tenant (78.57 ms vs 67.69 ms); mixed Q1 list 50 newest (timeout ms vs - ms)')), [
      { actor: 'internal', query: 'Q4 sum(price) per tenant', api_ms: '78.57', base_ms: '67.69' },
      { actor: 'mixed', query: 'Q1 list 50 newest', api_ms: 'timeout', base_ms: '-' }
   ]);
   assert.equal(parseBudget('ERROR:  relation "x" does not exist\n'), null);
});

test('an accepted exception alone passes the run, and is reported', () => {
   const v = verdict(3, out('internal Q4 sum(price) per tenant (78.57 ms vs 67.69 ms)'), exceptions);
   assert.equal(v.code, 0);
   assert.deepEqual(v.accepted.map((r) => r.query), ['Q4 sum(price) per tenant']);
   assert.deepEqual(v.failing, []);
});

test('any other over-budget read still fails the run, with or without an accepted one', () => {
   assert.equal(verdict(3, out('restricted Q4 sum(price) per tenant (99.00 ms vs 50.00 ms)'), exceptions).code, 3);
   const both = verdict(3, out('internal Q3 count (60.00 ms vs 46.00 ms); internal Q1 list 50 newest (20.00 ms vs 9.00 ms)'), exceptions);
   assert.equal(both.code, 3);
   assert.deepEqual(both.failing.map((r) => r.query), ['Q1 list 50 newest']);
   assert.deepEqual(classify([{ actor: 'internal', query: 'Q6 purchase_order_overview 50' }], exceptions).failing.length, 1);
});

test('a run that failed for another reason keeps its status; a clean run is 0', () => {
   assert.equal(verdict(1, 'ERROR:  syntax error\n', exceptions).code, 1);
   assert.equal(verdict(0, '', exceptions).code, 0);
});
