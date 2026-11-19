<script setup lang="ts">
import { useDashboardMarket } from '@/api/dashboard';
import DashboardBox from '@/components/service-components/dashboard/DashboardBox.vue';
import type { BoxSize, DashboardBoxDef } from '@/constants/dashboard';
import { useBoxView } from './useBoxView';
import { marketView } from './views';

const props = defineProps<{ box: DashboardBoxDef; size: BoxSize }>();

// Read when the view is computed, so a renamed or newly shared tenant shows at once.
const authStore = useAuthStore();
const tenantName = (id: string | null) =>
   authStore.branches.find((tenant) => tenant.id === id)?.display_name ?? '';
const view = useBoxView(props.box, useDashboardMarket, marketView(tenantName));
</script>

<template>
   <DashboardBox :box :size v-bind="view" />
</template>
