<script setup>
import { useSignupOpen } from '@/api/platformSetting';

// The sign-in page offers sign-up only while the platform has it open (decision 17).
const { open: signupOpen } = useSignupOpen();

// The route the panel serves: makers in three countries, one quality gate, shipment, the shelf.
const makers = [
   { city: 'İstanbul', y: 50, path: 'M100 50 C210 50 220 140 320 140' },
   { city: 'Shenzhen', y: 140, path: 'M100 140 L320 140' },
   { city: 'Surabaya', y: 230, path: 'M100 230 C210 230 220 140 320 140' }
];
const stops = [
   { key: 'gate', x: 320 },
   { key: 'shipment', x: 470 },
   { key: 'marketplace', x: 620 }
];
</script>

<template>
   <div class="auth min-h-full flex p-2 md:p-4">
      <div
         class="auth__frame flex-1 grid grid-rows-[auto_1fr] md:grid-rows-1 md:grid-cols-[minmax(0,1.4fr)_minmax(26rem,1fr)]"
      >
         <section class="auth__welcome flex flex-col justify-between gap-10 p-8 md:p-14">
            <div class="flex flex-col gap-5 max-w-[34rem]">
               <h1
                  class="auth__headline m-0 text-4xl md:text-6xl font-light"
                  v-text="$t('auth.welcome.headline')"
               />
               <p class="m-0 text-lg auth__lead" v-text="$t('auth.welcome.lead')" />
            </div>

            <svg
               class="auth__route hidden md:block w-full max-w-[58rem]"
               viewBox="0 0 660 280"
               role="img"
               :aria-label="$t('auth.welcome.route.label')"
            >
               <defs>
                  <radialGradient id="auth-shelf-glow">
                     <stop offset="0" class="auth__glow-core" />
                     <stop offset="1" class="auth__glow-edge" />
                  </radialGradient>
               </defs>
               <circle cx="620" cy="140" r="150" fill="url(#auth-shelf-glow)" />
               <g class="auth__lines" fill="none">
                  <path
                     v-for="(maker, i) in makers"
                     :key="maker.city"
                     :d="maker.path"
                     pathLength="1"
                     :style="{ '--delay': `${i * 120}ms` }"
                  />
                  <path class="auth__trunk" d="M320 140 L620 140" pathLength="1" />
               </g>
               <g v-for="maker in makers" :key="maker.city">
                  <circle class="auth__origin" cx="100" :cy="maker.y" r="5" />
                  <text
                     class="auth__city"
                     x="86"
                     :y="maker.y"
                     dy="0.35em"
                     text-anchor="end"
                     v-text="maker.city"
                  />
               </g>
               <g v-for="(stop, i) in stops" :key="stop.key" :style="{ '--step': i }">
                  <circle
                     class="auth__stop"
                     :class="{ 'auth__stop--end': stop.key == 'marketplace' }"
                     :cx="stop.x"
                     cy="140"
                     :r="stop.key == 'marketplace' ? 9 : 6"
                  />
                  <text
                     class="auth__stop-label"
                     :x="stop.x"
                     y="176"
                     :text-anchor="stop.key == 'marketplace' ? 'end' : 'middle'"
                     :dx="stop.key == 'marketplace' ? 14 : 0"
                     v-text="$t(`auth.welcome.route.${stop.key}`)"
                  />
               </g>
            </svg>

            <RouterLink
               v-if="$route.name != 'auth-login' || signupOpen"
               custom
               :to="{
                  name: $route.name == 'auth-login' ? 'auth-register' : 'auth-login',
                  replace: true
               }"
               v-slot="{ href, navigate }"
            >
               <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
                  <span
                     class="auth__lead"
                     v-text="
                        $route.name == 'auth-login'
                           ? $t('auth.welcome.no_account')
                           : $t('auth.welcome.have_account')
                     "
                  />
                  <Button
                     as="a"
                     :data-signup-link="$route.name == 'auth-login' ? '' : undefined"
                     :href="href"
                     @click="navigate"
                     :label="
                        $route.name == 'auth-login'
                           ? $t('route.label.register')
                           : $t('route.label.login')
                     "
                     variant="outlined"
                     class="auth__switch"
                  />
               </div>
            </RouterLink>
         </section>

         <section class="auth__form flex items-start md:items-center justify-center p-8 md:p-12">
            <div class="w-full max-w-[26rem] flex">
               <CustomRouteView
                  :transitionProps="{
                     class: 'transition-[opacity,transform] duration-[calc(var(--transition-duration))]',
                     enterFromClass: 'opacity-0 translate-y-2',
                     leaveToClass: 'opacity-0 -translate-y-2'
                  }"
               />
            </div>
         </section>
      </div>
   </div>
</template>

<style lang="scss" scoped>
.auth__frame {
   border-radius: calc(var(--content-border-radius) * 3);
   overflow: hidden;
   background: var(--p-content-background);
   border: 1px solid var(--p-content-border-color);
}

// Map panel in the theme's primary: a pale chart by day, a night map in dark mode; a faint dot
// grid, and the route's end glows.
.auth__welcome {
   --ink: var(--p-primary-50);
   --line: var(--p-primary-600);
   --text: var(--p-primary-950);
   --dot: color-mix(in srgb, var(--p-primary-400) 35%, transparent);
   --glow: 0.22;

   overflow: hidden;
   color: var(--text);
   background-color: var(--ink);
   background-image: radial-gradient(var(--dot) 1px, transparent 1.5px);
   background-size: 22px 22px;
}

// (Not `:global(.dark) …`: in a scoped block that compiles to a bare `.dark` rule.)
.auth__welcome:where(.dark *) {
   --ink: var(--p-primary-950);
   --line: var(--p-primary-400);
   --text: var(--p-surface-0);
   --dot: color-mix(in srgb, var(--p-primary-200) 16%, transparent);
   --glow: 0.35;
}

.auth__glow-core {
   stop-color: var(--p-primary-500);
   stop-opacity: var(--glow);
}

.auth__glow-edge {
   stop-color: var(--p-primary-500);
   stop-opacity: 0;
}

.auth__headline {
   // The global heading colour follows the page, not this always-dark panel.
   color: var(--text);
   line-height: 1.05;
   letter-spacing: -0.02em;
   text-wrap: balance;
}

.auth__lead {
   color: color-mix(in srgb, var(--text) 72%, transparent);
   line-height: 1.55;
   max-width: 32em;
}

.auth__switch {
   color: var(--text);
   border-color: color-mix(in srgb, var(--text) 45%, transparent);

   &:hover {
      background: color-mix(in srgb, var(--text) 10%, transparent);
   }
}

.auth__route {
   overflow: visible;

   text {
      font-family: inherit;
      fill: var(--text);
   }
}

.auth__lines path {
   stroke: color-mix(in srgb, var(--line) 70%, transparent);
   stroke-width: 2;
   stroke-dasharray: 1;
   stroke-dashoffset: 0;
}

.auth__lines .auth__trunk {
   stroke: var(--line);
   stroke-width: 3;
}

.auth__origin {
   fill: var(--ink);
   stroke: var(--line);
   stroke-width: 2;
}

.auth__city {
   font-size: 13px;
   opacity: 0.65;
}

.auth__stop {
   fill: var(--line);
   stroke: var(--ink);
   stroke-width: 3;
}

.auth__stop--end {
   fill: var(--text);
   stroke: var(--line);
}

.auth__stop-label {
   font-size: 15px;
   font-weight: 700;
}

// The one moment of motion: the route draws itself once, then its stops appear in order.
@media (prefers-reduced-motion: no-preference) {
   .auth__lines path {
      stroke-dashoffset: 1;
      animation: auth-draw 900ms cubic-bezier(0.6, 0, 0.3, 1) var(--delay, 0ms) forwards;
   }

   .auth__lines .auth__trunk {
      animation-duration: 1100ms;
      animation-delay: 700ms;
   }

   .auth__stop,
   .auth__stop-label {
      opacity: 0;
      animation: auth-appear 300ms ease-out forwards;
      animation-delay: calc(900ms + var(--step) * 360ms);
   }
}

@keyframes auth-draw {
   to {
      stroke-dashoffset: 0;
   }
}

@keyframes auth-appear {
   to {
      opacity: 1;
   }
}
</style>
