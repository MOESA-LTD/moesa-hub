<script setup lang="ts">
import CustomLink from '@/components/ui/custom-link/CustomLink.vue';
import { ability } from '@plugins/casl';
import type { MenuItem } from 'primevue/menuitem';
import { computed, toValue } from 'vue';
import { useRouter, type RouteLocationRaw } from 'vue-router';

// The add actions of a module's side-menu entry (its `meta.contextMenuItems`, e.g. "Add" opening
// the new-record dialog) as buttons on the module's list page, so creating a record does not
// depend on finding the menu's right-click. The menu stays the one place they are defined.
const props = defineProps<{
   /** The module's route name, e.g. `ops-incident`. */
   name: string;
}>();

const router = useRouter();

const actions = computed(() => {
   const record = router.getRoutes().find((route) => route.name === props.name);
   const items = (toValue(record?.meta.contextMenuItems) ?? []) as MenuItem[];
   return items.flatMap(({ label, route }) => {
      if (!route || typeof label !== 'string') return [];
      // Only what the user may open and create: the dialog's route needs its permissions, and
      // adding needs `create` on the tables it reads.
      const target = router.resolve(route as RouteLocationRaw);
      const allowed = (target.meta.requiredPermissions ?? []).every(
         ({ action, subject }) => ability.can(action, subject) && ability.can('create', subject)
      );
      return allowed && target.matched.length ? [{ label, route: route as RouteLocationRaw }] : [];
   });
});
</script>

<template>
   <span v-if="actions.length" class="flex gap-2" data-route-add-actions>
      <CustomLink v-for="action in actions" :key="action.label" :to="action.route">
         <template #default="{ navigate }">
            <Button variant="outlined" :label="$t(action.label)" @click="navigate" />
         </template>
      </CustomLink>
   </span>
</template>
