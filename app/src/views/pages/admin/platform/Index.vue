<script setup lang="ts">
import { usePlatformSettings, useSetPlatformSetting } from '@/api/platformSetting';
import { useToast } from 'primevue';

// The super admin's platform switches (supabase/migrations/070). Open sign-up (decision 17): off,
// companies join only through a provider's invitation; on, anyone may sign up, verify-first.
const { t } = useI18n();
const toast = useToast();
const { data: settings, isPending } = usePlatformSettings();
const { mutateAsync, isPending: saving } = useSetPlatformSetting();

const openSignup = computed(() => settings.value?.open_signup === true);

const setOpenSignup = async (value: boolean) => {
   await mutateAsync({ key: 'open_signup', value });
   toast.add({ life: 3000, severity: ToastSeverity.SUCCESS, summary: t('admin.platform.saved') });
};
</script>

<template>
   <div class="flex flex-col gap-4 p-4" data-admin-platform>
      <h2 class="m-0 text-xl font-medium">{{ $t('admin.platform.title') }}</h2>
      <div class="flex items-start gap-3" data-open-signup>
         <ToggleSwitch
            inputId="platform-open-signup"
            :modelValue="openSignup"
            :disabled="isPending || saving"
            @update:modelValue="setOpenSignup"
         />
         <label for="platform-open-signup" class="flex flex-col gap-1">
            <span class="font-medium">{{ $t('admin.platform.open_signup') }}</span>
            <span class="text-muted-color">{{ $t('admin.platform.open_signup_hint') }}</span>
         </label>
      </div>
   </div>
</template>
