<script setup lang="ts">
import Brands from './tabs/Brands.vue';
import Contacts from './tabs/Contacts.vue';
import Platforms from './tabs/Platforms.vue';
import Warehouses from './tabs/Warehouses.vue';

// The company profile of the active tenant: its brands, contacts, warehouses and platform
// accounts. Each tab is its own route, so a tab has a link; a tab is offered to those who may read
// its table.
const props = defineProps<{ tab?: string | null }>();

const router = useRouter();
const { t } = useI18n();

const TABS = [
   { key: 'brands', subject: 'brand' },
   { key: 'contacts', subject: 'contact' },
   { key: 'warehouses', subject: 'warehouse' },
   { key: 'platforms', subject: 'platform_account' }
] as const;
type TabKey = (typeof TABS)[number]['key'];

const activeTab = computed<TabKey>(
   () => TABS.find(({ key }) => key === props.tab)?.key ?? TABS[0].key
);

const open = (key: string | number) => router.push({ name: `ops-company-${key}` });
</script>

<template>
   <div class="card p-0">
      <h2 class="m-4 mb-0 text-xl font-semibold" v-text="t('ops.company.title')" />
      <Tabs :value="activeTab" @update:value="open">
         <TabList>
            <Tab
               v-for="{ key, subject } in TABS"
               v-show="$can('select', subject)"
               :key
               :value="key"
            >
               {{ $t(`ops.company.tabs.${key}`) }}
            </Tab>
         </TabList>
         <TabPanels>
            <TabPanel value="brands">
               <Brands v-if="activeTab === 'brands'" />
            </TabPanel>
            <TabPanel value="contacts">
               <Contacts v-if="activeTab === 'contacts'" />
            </TabPanel>
            <TabPanel value="warehouses">
               <Warehouses v-if="activeTab === 'warehouses'" />
            </TabPanel>
            <TabPanel value="platforms">
               <Platforms v-if="activeTab === 'platforms'" />
            </TabPanel>
         </TabPanels>
      </Tabs>
   </div>
</template>
