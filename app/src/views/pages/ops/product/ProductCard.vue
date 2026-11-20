<script setup lang="ts">
import type { ProductRow } from '@/api/product';
import { useAbility } from '@casl/vue';
import Amazon from './tabs/Amazon.vue';
import Dimensions from './tabs/Dimensions.vue';
import Documents from './tabs/Documents.vue';
import General from './tabs/General.vue';
import Incidents from './tabs/Incidents.vue';
import Media from './tabs/Media.vue';
import Orders from './tabs/Orders.vue';
import Sourcing from './tabs/Sourcing.vue';
import {
   PRODUCT_CARD_TABS,
   PRODUCT_FORM,
   tabForField,
   useProductForm,
   type ProductCardTab
} from './useProductForm';

// The product card's tabs around its one form, which the general and dimensions tabs share.
// The sourcing tab edits the active tenant's sourcing row of the product in a form of its own.
// The orders tab (its purchase orders and shipments) is read-only and has no form of its own; the
// Amazon tab has its own (the Amazon columns), read-only without the right to update products.
// Manage re-creates the card when a new product is saved, so the form goes on under its id.
const props = defineProps<{ id: string | null }>();
const emit = defineEmits<{ saved: [product: ProductRow] }>();

const activeTab = defineModel<ProductCardTab>('tab', { default: 'general' });

const form = useProductForm(
   () => props.id,
   (product) => emit('saved', product)
);
await form.ready;

/** Saves; when a field is invalid, opens the tab that shows the first one. */
const submit = async () => {
   await form.save();
   const [first] = Object.keys(form.errors.value);
   if (first) activeTab.value = tabForField(first.split('.')[0]);
};

provide(PRODUCT_FORM, { ...form, submit });

const ability = useAbility();
const tabs = computed(() =>
   PRODUCT_CARD_TABS.filter((key) => {
      if (key === 'sourcing') return ability.can('read', 'sourcing');
      if (key === 'incidents') return ability.can('read', 'incident');
      if (key === 'orders')
         return ability.can('read', 'purchase_order') || ability.can('read', 'shipment');
      return true;
   })
);
</script>

<template>
   <Tabs v-model:value="activeTab">
      <TabList>
         <Tab v-for="key in tabs" :key :value="key" :disabled="key !== 'general' && !id">
            {{ $t(`ops.product.tabs.${key}`) }}
         </Tab>
      </TabList>
      <TabPanels>
         <TabPanel value="general">
            <General />
         </TabPanel>
         <TabPanel value="dimensions">
            <Dimensions v-if="id" />
         </TabPanel>
         <TabPanel v-if="tabs.includes('sourcing')" value="sourcing">
            <Sourcing v-if="id && activeTab === 'sourcing'" :id />
         </TabPanel>
         <TabPanel v-if="tabs.includes('orders')" value="orders">
            <Orders v-if="id && activeTab === 'orders'" :id />
         </TabPanel>
         <TabPanel value="documents">
            <Documents v-if="id && activeTab === 'documents'" :id />
         </TabPanel>
         <TabPanel v-if="tabs.includes('incidents')" value="incidents">
            <Incidents v-if="id && activeTab === 'incidents'" :id />
         </TabPanel>
         <TabPanel value="media">
            <Media v-if="id && activeTab === 'media'" :id />
         </TabPanel>
         <TabPanel value="amazon">
            <Amazon v-if="id && activeTab === 'amazon'" :id />
         </TabPanel>
      </TabPanels>
   </Tabs>
</template>
