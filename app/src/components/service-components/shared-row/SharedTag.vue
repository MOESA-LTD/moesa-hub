<script setup lang="ts">
// Marks a provider's row shared with the client side (useSharedRow): "From <provider>", or just
// "Shared" while the provider's name is not known.
defineProps<{ provider?: string | null }>();
</script>

<template>
   <Tag
      severity="contrast"
      data-test="shared-tag"
      :value="provider ? $t('ops.shared.from', { provider }) : $t('ops.shared.shared')"
   />
</template>
