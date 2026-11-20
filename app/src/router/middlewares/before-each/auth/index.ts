import { ability } from '@plugins/casl';
import { AuthSessionMissingError, CustomAuthError } from '@supabase/supabase-js';
import { useToast } from 'primevue';
import type { NavigationGuardWithThis } from 'vue-router';

/** The pages an e-mail link signs in to that set the password themselves, and the link types each accepts. */
const LINK_PAGES: Record<string, string[]> = {
   'auth-invitation': ['invite', 'magiclink', 'signup'],
   'auth-register-complete': ['invite']
};

export const authBeforeEach: NavigationGuardWithThis<undefined> = async (to) => {
   // Invite and recovery links sign the user in through tokens in the URL hash.
   const params = new URLSearchParams(window.location.hash?.substring(1));
   const access_token = params.get('access_token');
   const refresh_token = params.get('refresh_token');

   // The pages that set the password themselves sign in only with the link types their mails use:
   // any other tokens in the address are not the recipient's and are ignored (no login fixation).
   // The invitation mails an invite or a magic link; self-signup only ever an invite.
   const linkType = params.get('type');
   const linkTypes = LINK_PAGES[String(to.name)];
   const accepted = !linkTypes || linkTypes.includes(linkType ?? '');

   // The router writes the location it lands on back to the address bar, hash included: a page that
   // drops the link's tokens lands on itself without them, or they come back and the next
   // navigation signs in with them again.
   const withoutTokens = () =>
      to.hash ? { path: to.path, query: to.query, hash: '', replace: true } : undefined;

   if (linkTypes && !accepted && access_token) {
      window.history.replaceState({}, document.title, to.path);
      return withoutTokens();
   }

   if (access_token && refresh_token && accepted) {
      const { error } = await supabase.auth.setSession({ access_token, refresh_token });
      if (error) throw error;

      window.history.replaceState({}, document.title, to.path);

      // The invitation and sign-up pages set the password themselves, in their first step: they
      // stay where they are, signed in, and go on to the checks below.
      if (!linkTypes) {
         // Guards run in the app's injection context (vue-router >= 4.2), so the toast works here.
         useToast().add({
            life: 0,
            closable: true,
            severity: ToastSeverity.INFO,
            summary: i18n.t('auth.welcome.title'),
            detail: i18n.t('auth.please_dont_forget_to_update_your_password')
         });

         return { name: 'account-security' };
      }

      const landing = withoutTokens();
      if (landing) return landing;
   }

   const authStore = useAuthStore();
   await authStore.initialized;
   // Signing in loads the permissions in the background; a navigation right after waits for them.
   await authStore.accessReady();

   const { meta } = to;

   // A protected page without a session goes to the login page (router.onError, 401).
   if (meta.requiresAuth && !authStore.isSignedIn) {
      throw Object.assign(new AuthSessionMissingError(), { status: 401 });
   }

   if (to.matched.some((record) => record.meta.superAdmin) && !authStore.isSuperAdmin) {
      throw new CustomAuthError(
         i18n.t('errors.insufficient_permission'),
         i18n.t('errors.AuthInvalidCredentialsError'),
         403,
         undefined
      );
   }

   // A page of a module outside the company's plan shows what it would take instead, to whom the
   // role would open it; the others are refused below, as they would be with the module in the plan.
   const lockedModule = to.matched
      .flatMap(({ meta: { requiredPermissions, anyPermission } }) => [
         ...(requiredPermissions ?? []),
         // A page open with any of several: locked only when none of them is granted.
         ...(anyPermission?.some(({ action, subject }) => ability.can(action, subject))
            ? []
            : (anyPermission ?? []))
      ])
      .map(({ action, subject }) => authStore.lockedModule(action, subject))
      .find(Boolean);
   if (lockedModule) return { name: 'module-locked', params: { module: lockedModule } };

   if (
      meta.requiredPermissions?.some(({ action, subject }) => ability.cannot(action, subject)) ||
      (meta.anyPermission &&
         !meta.anyPermission.some(({ action, subject }) => ability.can(action, subject)))
   ) {
      throw new CustomAuthError(
         i18n.t('errors.insufficient_permission'),
         i18n.t('errors.AuthInvalidCredentialsError'),
         403,
         undefined
      );
   }
};
