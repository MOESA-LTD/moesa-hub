<script setup lang="ts">
// The account an e-mail link signed in, on every step of the pages it opens (invitation, sign-up
// completion): a link carries its own session, which may not be the reader's (Task 11 M3), so the
// address is always in view with a way out.
defineProps<{ email: string }>();
const emit = defineEmits<{ signOut: [] }>();
</script>

<template>
   <div class="flex flex-wrap items-center gap-x-2 text-sm text-muted-color" data-signed-in-as>
      <i class="pi pi-user" />
      <span>{{ $t('signed_in.as', { email }) }}</span>
      <Button
         variant="link"
         size="small"
         class="!p-0"
         data-sign-out
         :label="$t('signed_in.not_you')"
         @click="emit('signOut')"
      />
   </div>
</template>
