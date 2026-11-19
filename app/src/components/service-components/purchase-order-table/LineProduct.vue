<script setup lang="ts">
import { lineProductLabel, type LineProductSource } from '@/api/purchaseOrder';

// An order line's product as `SKU · name`: the linked product's, or the snapshot the line kept
// once its product is gone or out of reach (a client's product).
const props = defineProps<{ line: LineProductSource }>();

const label = computed(() => lineProductLabel(props.line));
</script>

<template>
   <span>{{ label }}</span>
</template>
