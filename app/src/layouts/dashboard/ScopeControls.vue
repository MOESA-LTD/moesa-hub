<script setup lang="ts">
import TenantPicker from '@/components/service-components/tenant-picker/TenantPicker.vue';

// The tenant picker: inline in the topbar, stacked in the mobile drawer.
defineProps<{ layout: 'row' | 'column' }>();

const { isSignedIn } = storeToRefs(useAuthStore());
</script>

<template>
   <div
      v-if="isSignedIn"
      class="items-center gap-2"
      :class="layout === 'column' ? 'flex flex-col items-stretch' : 'flex flex-row'"
   >
      <TenantPicker :class="{ 'w-full': layout === 'column' }" />
   </div>
</template>
