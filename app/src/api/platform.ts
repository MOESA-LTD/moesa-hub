import { useLookup } from '@/api/useLookup';

export type PlatformOption = Pick<Tables['platform']['Row'], 'id' | 'display_name' | 'countries'>;

/** The marketplaces in display order (global, no tenant); their countries bound an account's. */
export const usePlatformOptions = () =>
   useLookup<PlatformOption>('platform', {
      select: 'id, display_name, countries',
      order: 'position'
   });
