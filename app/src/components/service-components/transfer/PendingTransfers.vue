<script setup lang="ts">
import { usePendingTransfers } from '@/api/transfer';
import TransferFilesNotice from './TransferFilesNotice.vue';

// The transfers into or out of the tenants whose files are not all copied yet, each with the
// notice that finishes the copy. Nothing shows when there is none.
const props = defineProps<{ tenants: readonly string[]; title?: string }>();

const { data: pending } = usePendingTransfers(() => props.tenants);
</script>

<template>
   <section v-if="pending?.length" class="flex flex-col gap-2" data-pending-transfers>
      <h4 class="font-semibold">
         {{ title ? `${title}: ` : '' }}{{ $t('ops.transfer.pending.title') }}
      </h4>
      <TransferFilesNotice
         v-for="transfer in pending"
         :key="transfer.id"
         :transfer
         heading
         data-pending-transfer
      />
   </section>
</template>
