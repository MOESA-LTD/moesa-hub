// The accepted exceptions of the field-security perf budget (supabase/perf/accepted_exceptions.json):
// field_security_perf.sql raises 'budget: <actor> <query> (<api> ms vs <base> ms); ...' for every
// read over budget; a read on the list is reported and passes, any other one still fails the run.
// Dependency-free: node builtins only.
import { readFileSync } from 'node:fs';

/** The list, from `file`: [{ actor, query, reason }]. */
export const readExceptions = (file) => {
   const { exceptions } = JSON.parse(readFileSync(file, 'utf8'));
   if (!Array.isArray(exceptions)) throw new Error(`${file}: no "exceptions" array`);
   for (const e of exceptions) {
      if (typeof e?.actor !== 'string' || typeof e?.query !== 'string' || typeof e?.reason !== 'string') {
         throw new Error(`${file}: every exception names an actor, a query and a reason`);
      }
   }
   return exceptions;
};

const ENTRY = /^(\S+) (.+) \(([^()]+) ms vs ([^()]+) ms\)$/;

/**
 * The over-budget reads named by the 'budget: ...' error in psql's output, or null when there is no
 * such error (the run passed, or failed for another reason).
 */
export const parseBudget = (output) => {
   // psql prefixes the error with its input position (psql:<stdin>:370: ERROR:  budget: ...).
   const line = output.split(/\r?\n/).find((l) => /(^|: )ERROR:\s+budget: /.test(l));
   if (!line) return null;
   return line
      .replace(/^.*?ERROR:\s+budget: /, '')
      .split('; ')
      .map((entry) => {
         const m = ENTRY.exec(entry.trim());
         if (!m) throw new Error(`unreadable budget entry: ${entry}`);
         return { actor: m[1], query: m[2], api_ms: m[3], base_ms: m[4] };
      });
};

/** The over-budget reads split into the accepted ones and the rest. */
export const classify = (over, exceptions) => {
   const accepted = [];
   const failing = [];
   for (const read of over) {
      const rule = exceptions.find((e) => e.actor === read.actor && e.query === read.query);
      (rule ? accepted : failing).push(rule ? { ...read, reason: rule.reason } : read);
   }
   return { accepted, failing };
};

/**
 * The exit code of a run: psql's status, but 0 when the only failure is the budget error and every
 * read it names is an accepted exception.
 */
export const verdict = (status, output, exceptions) => {
   if (status === 0) return { code: 0, accepted: [], failing: [] };
   const over = parseBudget(output);
   if (!over) return { code: status ?? 1, accepted: [], failing: [] };
   const { accepted, failing } = classify(over, exceptions);
   return { code: failing.length ? (status ?? 1) : 0, accepted, failing };
};
