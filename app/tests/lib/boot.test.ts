import { bootHandoff, hideBoot } from '@/lib/boot';
import { flushPromises } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const bootFading = () => !!document.getElementById('boot')?.classList.contains('boot--done');

describe('hideBoot', () => {
   afterEach(() => {
      vi.useRealTimers();
      document.body.innerHTML = '';
   });

   it('fades the boot skeleton out, then removes it', () => {
      vi.useFakeTimers();
      document.body.innerHTML = '<div id="boot"></div><div id="app"></div>';

      hideBoot();
      expect(bootFading()).toBe(true);

      vi.advanceTimersByTime(400);
      expect(document.getElementById('boot')).toBeNull();
      expect(document.getElementById('app')).not.toBeNull();
   });

   it('does nothing when the skeleton is already gone', () => {
      expect(() => hideBoot()).not.toThrow();
   });
});

describe('bootHandoff', () => {
   beforeEach(() => {
      document.body.innerHTML = '<div id="boot"></div><div id="app"></div>';
   });
   afterEach(() => {
      document.body.innerHTML = '';
   });

   it('keeps the skeleton while the router has not placed a page yet', async () => {
      let ready!: () => void;
      bootHandoff(new Promise<void>((r) => (ready = r)), () => false);
      expect(bootFading()).toBe(false);

      ready();
      await flushPromises();
      expect(bootFading()).toBe(false);
   });

   it('hides it once the router is ready and nothing is pending', async () => {
      let matched = false;
      let ready!: () => void;
      bootHandoff(new Promise<void>((r) => (ready = r)), () => matched);

      matched = true;
      ready();
      await flushPromises();
      expect(bootFading()).toBe(true);
   });

   it('waits for a page that is still loading', async () => {
      let rendered = false;
      let ready!: () => void;
      bootHandoff(new Promise<void>((r) => (ready = r)), () => rendered);

      // Router ready, but the page's async parts are still loading: nothing on screen yet.
      ready();
      await flushPromises();
      expect(bootFading()).toBe(false);

      // The page lands in #app later, with no event to say so.
      rendered = true;
      document.getElementById('app')!.append(document.createElement('div'));
      await flushPromises();
      expect(bootFading()).toBe(true);
   });

   it('gives up on the skeleton when the first navigation fails', async () => {
      bootHandoff(Promise.reject(new Error('guard failed')), () => false);
      await flushPromises();
      expect(bootFading()).toBe(true);
   });
});
