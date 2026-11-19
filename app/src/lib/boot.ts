import { nextTick } from 'vue';

/** How long the boot skeleton fades (index.html, `.boot--done`). */
const FADE_MS = 200;

/**
 * Takes the boot skeleton (index.html's `#boot`) away. It sits outside `#app`, so mounting the
 * app does not clear it and the page never goes blank while the layout and route chunks load.
 * Safe to call more than once.
 */
export function hideBoot(): void {
   const boot = document.getElementById('boot');
   if (!boot || boot.classList.contains('boot--done')) return;
   boot.classList.add('boot--done');
   setTimeout(() => boot.remove(), FADE_MS + 100);
}

/**
 * Hides the boot skeleton once the first page is really on screen: the router is ready and
 * `rendered()` holds. No Vue event marks that moment (measured: App.vue's Suspense resolves the
 * empty router-view before the first navigation, and the page lands in #app later with no
 * resolve), so after the router is ready this watches #app until the page is there. A failed
 * first navigation hides it too, so the error page is not covered.
 */
export function bootHandoff(routerReady: Promise<unknown>, rendered: () => boolean): void {
   routerReady
      .then(() => nextTick())
      .then(
         () => {
            if (rendered()) return hideBoot();
            const app = document.getElementById('app');
            if (!app) return hideBoot();
            const observer = new MutationObserver(() => {
               if (!rendered()) return;
               observer.disconnect();
               hideBoot();
            });
            observer.observe(app, { childList: true, subtree: true });
         },
         () => hideBoot()
      );
}
