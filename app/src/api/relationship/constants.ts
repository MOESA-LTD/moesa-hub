import { allValues } from '@/lib/enumValues';

type Enums = Db['public']['Enums'];
export type CommercialModel = Enums['commercial_model'];
export type ContractStatus = Enums['contract_status'];

/** How the provider works for a client (decided per relationship). */
export const COMMERCIAL_MODELS = [
   'trading_partner',
   'commercial_representative',
   'operations_partner'
] as const satisfies readonly CommercialModel[];

/** The service packages a client may take (checked by the database too). */
export const PACKAGES = ['A0', 'A1', 'A2', 'B', 'C', 'D', 'E'] as const;

export const CONTRACT_STATUSES = allValues<ContractStatus>()([
   'lead',
   'onboarding',
   'active',
   'paused',
   'closed'
]);

export type RelationshipStatusValue = Enums['relationship_status'];

/** A provider relationship is in force, or has ended (for good: relationship_ended_final). */
export const RELATIONSHIP_STATUSES = allValues<RelationshipStatusValue>()(['active', 'ended']);
