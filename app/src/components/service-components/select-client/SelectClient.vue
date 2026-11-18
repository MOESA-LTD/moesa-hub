<script setup lang="ts">
import { useClientOptions } from '@/api/relationship';

/**
 * Picks the client a provider record (an order, a shipment) is for: one of the active tenant's
 * active provider-procures relationships. Empty (null) is an own record. A saved record's client
 * stays listed even once its relationship has ended.
 */
const model = defineModel<string | null>();
const emit = defineEmits<{ change: [clientTenantId: string | null] }>();

const options = useClientOptions(() => model.value);
</script>

<template>
   <Select
      v-model="model"
      :options
      option-value="value"
      option-label="label"
      filter
      showClear
      :placeholder="$t('ops.client.own')"
      @change="emit('change', $event.value ?? null)"
   />
</template>
