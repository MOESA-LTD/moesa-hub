/**
 * The label of a table column outside its own form (the role editor's field rows). A column is
 * labelled where it is edited: `ops.<table>.fields.<field>`, else the form the table is edited in
 * (a sourcing row in the product form, an order line in the order form ...), else the shared
 * `fields.<field>`, else the column name made readable.
 */

/** The forms (under ops.*) a table's columns are edited in, besides its own section. */
export const FIELD_LABEL_SECTIONS: Readonly<Record<string, readonly string[]>> = {
   contact: ['company.contact'],
   incident_log: ['incident.log', 'incident'],
   market_cell: ['market'],
   platform_account: ['company.platform'],
   provider_invitation: ['client.invitation', 'client'],
   provider_relationship: ['client'],
   purchase_order_line: ['purchase_order', 'product'],
   purchase_order_payment: ['purchase_order.payment', 'purchase_order'],
   shipment_event: ['shipment'],
   sourcing: ['product'],
   supplier_contact: ['supplier.contact'],
   warehouse: ['company.warehouse']
};

/** The keys tried for a column, in order. */
export const fieldLabelKeys = (table: string, field: string): string[] => [
   ...[table, ...(FIELD_LABEL_SECTIONS[table] ?? [])].map(
      (section) => `ops.${section}.fields.${field}`
   ),
   `fields.${field}`
];

/** A column name as words: "pi_deposit_amount" → "Pi deposit amount". */
export const humaniseField = (field: string): string => {
   const words = field.replace(/_+/g, ' ').trim();
   return words.charAt(0).toUpperCase() + words.slice(1);
};

/** The label of `table.field`, with the i18n lookups of the caller. */
export const fieldLabel = (
   table: string,
   field: string,
   t: (key: string) => string,
   te: (key: string) => boolean
): string => {
   const key = fieldLabelKeys(table, field).find((k) => te(k));
   return key ? t(key) : humaniseField(field);
};
