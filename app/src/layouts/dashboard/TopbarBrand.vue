<script setup lang="ts">
// The company's own logo when it has one (see the branch profile); otherwise the MOESA Hub
// lockup. The mark is moesaltd.com's file, unaltered, and only on light grounds as the
// design system asks; in dark mode the name stands alone.
defineProps<{ logo?: string | null; alt?: string }>();
</script>

<template>
   <img v-if="logo" :src="logo" :alt="alt" class="h-10 max-w-40 object-contain" />
   <span v-else class="brand">
      <img src="/brand/moesa_mark.png" alt="" class="brand__mark dark:hidden" />
      <span class="brand__name">MOESA</span>
      <span class="brand__product">Hub</span>
   </span>
</template>

<style scoped>
.brand {
   --brand-ink: #19324a;
   --brand-sub: #536b7d;

   display: inline-flex;
   align-items: center;
   gap: 0.75rem;
   font-family: 'Manrope', Arial, 'Segoe UI', sans-serif;
   font-size: 1.25rem;
   line-height: 1;
   white-space: nowrap;
}

.brand:where(.dark *) {
   --brand-ink: #ffffff;
   --brand-sub: #b4cfe0;
}

.brand__mark {
   height: 26px;
   width: auto;
}

.brand__name {
   color: var(--brand-ink);
   font-weight: 700;
   letter-spacing: 0.04em;
}

.brand__product {
   color: var(--brand-sub);
   font-weight: 400;
   padding-inline-start: 0.75rem;
   border-inline-start: 1px solid color-mix(in srgb, var(--brand-sub) 55%, transparent);
}
</style>
