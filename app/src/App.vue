<script setup>
import { useRouteDialogRestore } from '@/components/layout/route-dialog/useRouteDialogRestore';
import { useAuthUi } from '@/composables/useAuthUi';
import { bootHandoff } from '@/lib/boot';

useAuthUi();
useRouteDialogRestore();

// The boot skeleton (index.html) stays until the first page is really on screen.
const router = useRouter();
const route = useRoute();
bootHandoff(
   router.isReady(),
   () => route.matched.length > 0 && !!document.querySelector('#app > *')
);
</script>

<template>
   <Suspense>
      <ConfirmDialog />
   </Suspense>
   <Suspense>
      <DynamicDialog />
   </Suspense>
   <Toast position="bottom-right" />
   <Transition
      appear
      enter-active-class="animate-fadein animate-duration-[calc(var(--transition-duration)*0.5)]"
      leave-active-class="animate-fadeout animate-duration-[calc(var(--transition-duration)*0.5)]"
      mode="out-in"
   >
      <Suspense>
         <router-view />
      </Suspense>
   </Transition>
</template>

<style>
#app {
   display: flex;
   height: 100vh;
   width: 100vw;
   overflow: hidden;
}
</style>
