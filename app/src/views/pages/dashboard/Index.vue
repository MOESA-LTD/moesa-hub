<script setup lang="ts">
import { useDialogRef } from '@/composables/useDialogRef';
import {
   boxById,
   DASHBOARD_BOXES,
   DASHBOARD_EDITING,
   type DashboardBoxId
} from '@/constants/dashboard';
import { useAuthStore } from '@/store/auth';
import { useDashboardLayout, type CanSee } from '@/store/dashboardLayout';
import DashboardBoxEditBar from '@/views/pages/dashboard/DashboardBoxEditBar.vue';
import DashboardHiddenStrip from '@/views/pages/dashboard/DashboardHiddenStrip.vue';
import DashboardOverview from '@/views/pages/dashboard/DashboardOverview.vue';
import { useAbility } from '@casl/vue';
import { PrimeIcons } from '@primevue/core/api';
import { useElementSize } from '@vueuse/core';
import { useToast } from 'primevue/usetoast';
import { computed, onBeforeUnmount, provide, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import draggable from 'vuedraggable';

const dialogRef = useDialogRef();
const auth = useAuthStore();
const layout = useDashboardLayout();
const ability = useAbility();
const toast = useToast();
const { t } = useI18n();

const canSee: CanSee = (id) => ability.can('read', boxById(id).permission);

// Runs on every mount; the store reads storage only when the account changed, so a layout kept in
// memory after a refused write survives leaving and reopening the dashboard.
watch(
   () => auth.user?.id ?? null,
   (id) => layout.load(id),
   { immediate: true }
);

// The permitted set is only known once the access is loaded; until then nothing is said.
const accessLoaded = ref(false);
void auth.accessReady().then(() => {
   accessLoaded.value = true;
});

const shown = computed(() => layout.visibleBoxes(canSee).shown);
const anyPermitted = computed(() => DASHBOARD_BOXES.some((box) => canSee(box.id)));
// While editing, the hidden strip below already says how to bring boxes back.
const emptyText = computed(() => {
   if (shown.value.length) return null;
   if (!anyPermitted.value) return 'dashboard.layout.no_boxes';
   return layout.editing ? null : 'dashboard.layout.all_hidden';
});

// The dashboard's own width, not the screen's, decides its columns (see _charts.scss), so it lays out
// the same in a page and in a dialog of any size.
const root = ref<HTMLElement | null>(null);
const { width } = useElementSize(root);
/** The width (px) from which the grid has two columns: the `dashboard` container's 40rem. */
const TWO_COLUMNS = 640;

// Arranging needs a grid of two columns or more; when it narrows below that, and when the dashboard
// is left, an unsaved draft is dropped so a half-made layout never looks saved later. Before the
// first measure (width 0) nothing is decided.
const canEdit = computed(() => width.value >= TWO_COLUMNS);
watch(canEdit, (wide) => {
   if (!wide && width.value > 0) layout.discard();
});
onBeforeUnmount(() => layout.discard());
provide(
   DASHBOARD_EDITING,
   computed(() => layout.editing)
);

const save = () => {
   if (!layout.save()) {
      toast.add({ severity: 'warn', summary: t('dashboard.layout.not_persisted'), life: 5000 });
   }
};
</script>

<template>
   <div
      ref="root"
      class="dashboard-flow bg-[var(--surface-ground)] flex flex-col gap-4"
      :class="{
         'p-4': !!dialogRef
      }"
   >
      <Teleport
         v-if="canEdit && accessLoaded && anyPermitted"
         to="#page-toolbar"
         :disabled="!!dialogRef"
      >
         <span class="flex-1 flex justify-end gap-2 flex-wrap-reverse">
            <Button
               v-if="!layout.editing"
               variant="outlined"
               :icon="PrimeIcons.PENCIL"
               :label="$t('dashboard.layout.edit')"
               @click="layout.edit()"
            />
            <template v-else>
               <Button
                  text
                  :label="$t('dashboard.layout.reset')"
                  @click="layout.resetToDefault()"
               />
               <Button
                  variant="outlined"
                  severity="secondary"
                  :label="$t('dashboard.layout.discard')"
                  @click="layout.discard()"
               />
               <Button :label="$t('dashboard.layout.save')" @click="save" />
            </template>
         </span>
      </Teleport>
      <template v-if="accessLoaded">
         <DashboardOverview />
         <p v-if="emptyText" class="text-muted-color">
            {{ $t(emptyText) }}
         </p>
         <draggable
            v-else
            tag="div"
            class="dashboard-grid w-full"
            :model-value="shown"
            :item-key="(id: DashboardBoxId) => id"
            handle=".dashboard-drag-handle"
            :disabled="!layout.editing"
            :animation="150"
            @update:model-value="(ids: DashboardBoxId[]) => layout.reorder(ids, canSee)"
         >
            <template #item="{ element: id, index }">
               <div
                  :data-box-id="id"
                  class="dashboard-cell"
                  :class="{
                     'dashboard-cell--wide': layout.sizeOf(id) === 'wide',
                     'outline-dashed outline-2 outline-offset-2 outline-surface-300 dark:outline-surface-600 rounded-xl':
                        layout.editing
                  }"
               >
                  <DashboardBoxEditBar
                     v-if="layout.editing"
                     :box="boxById(id)"
                     :size="layout.sizeOf(id)"
                     :first="index === 0"
                     :last="index === shown.length - 1"
                     @hide="layout.hide(id)"
                     @update:size="(s) => layout.setSize(id, s)"
                     @move="(step) => layout.move(id, step, canSee)"
                  />
                  <component
                     :is="boxById(id).component"
                     :box="boxById(id)"
                     :size="layout.sizeOf(id)"
                  />
               </div>
            </template>
         </draggable>
         <DashboardHiddenStrip
            v-if="layout.editing"
            :ids="layout.visibleBoxes(canSee).hidden"
            @unhide="layout.unhide"
         />
      </template>
   </div>
</template>
