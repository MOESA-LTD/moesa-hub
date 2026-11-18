<script setup lang="ts">
import { useLookup } from '@/api/useLookup';

/**
 * Picks one of the projects of the order's client (`tenantId`), or of the form's tenant for an own
 * order (see provideFormTenant).
 */
type ProjectOption = Pick<Tables['project']['Row'], 'id' | 'code' | 'display_name'>;

const props = defineProps<{ tenantId?: string | null }>();
const model = defineModel<string | null>();

const { data: projects } = useLookup<ProjectOption>('project', () => ({
   select: 'id, code, display_name',
   order: 'code',
   tenantId: props.tenantId
}));

const options = computed(() =>
   (projects.value ?? []).map((project) => ({
      value: project.id,
      label: `${project.code} — ${project.display_name}`
   }))
);
</script>

<template>
   <Select
      v-model="model"
      :options
      option-value="value"
      option-label="label"
      filter
      showClear
      :placeholder="$t('ops.project.select')"
   />
</template>
