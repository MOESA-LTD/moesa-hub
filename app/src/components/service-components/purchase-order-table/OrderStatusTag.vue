<script setup lang="ts">
import {
   orderStatusLabel,
   type PurchaseOrderClientStatus,
   type PurchaseOrderStatus
} from '@/api/purchaseOrder';

// An order's status, or on the client side of a shared order (raw status NULL) its client status.
const props = defineProps<{
   order: {
      status?: PurchaseOrderStatus | null;
      client_status?: PurchaseOrderClientStatus | null;
   };
}>();

const label = computed(() => orderStatusLabel(props.order));
</script>

<template>
   <Tag v-if="label" :value="$t(label.key)" :severity="label.severity" />
</template>
