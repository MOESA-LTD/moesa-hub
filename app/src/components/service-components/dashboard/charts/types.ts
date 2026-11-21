import type { RouteLocationRaw } from 'vue-router';

/** One part of a bar or column: its series, colour (a --viz-* token) and amount. */
export type ChartSegment = { key: string; label: string; color: string; value: number };

/** A bar (or column): its parts, stacked in order from the baseline. */
export type ChartBar = {
   key: string;
   label: string;
   segments: ChartSegment[];
   /** What the bar's end says; the parts' sum by default. */
   value?: string;
   /** What the bar is read against (e.g. a target), when more than its parts' sum. */
   total?: number;
   /** A short line beside the label (e.g. "2 contained"). */
   note?: string;
   /** An icon before the label, for a status the colour alone must not carry. */
   icon?: string;
   /** Marks a bar whose label needs attention (e.g. the overdue column). */
   emphasis?: 'critical';
   /** Where a click on the bar leads. */
   to?: RouteLocationRaw;
};

export type ChartLegendItem = { key: string; label: string; color: string; icon?: string };

/** One ratio against its whole (e.g. signed SKUs of the active ones). */
export type ChartMeter = {
   key: string;
   label: string;
   value: number;
   total: number;
   to?: RouteLocationRaw;
};

export type ChartMeterRow = { key: string; label: string; meters: ChartMeter[] };

/** A bar's parts summed. */
export const barTotal = (bar: Pick<ChartBar, 'segments'>): number =>
   bar.segments.reduce((sum, segment) => sum + segment.value, 0);

/** What a bar says on hover and to a screen reader: its label, then each non-empty part. */
export const barDescription = (bar: ChartBar): string => {
   const parts = bar.segments.filter((segment) => segment.value > 0);
   const total = bar.value ?? String(barTotal(bar));
   if (parts.length <= 1) return `${bar.label}: ${total}`;
   return `${bar.label}: ${total} (${parts.map((p) => `${p.label} ${p.value}`).join(', ')})`;
};

/**
 * A clean axis maximum at or above `max`: the count itself up to 5, else 1, 2, 5 or 10 times a power
 * of ten.
 */
export const niceMax = (max: number): number => {
   if (max <= 5) return Math.max(1, Math.ceil(max));
   const power = 10 ** Math.floor(Math.log10(max));
   const step = [1, 2, 5, 10].find((m) => m * power >= max)!;
   return step * power;
};
