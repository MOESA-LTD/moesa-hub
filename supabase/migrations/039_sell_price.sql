-- The selling price: the price the procuring tenant sells a product at, in EUR
-- (sourcing.sell_price_eur), and the price list it comes from (sourcing.price_list_version). Both
-- live on the product's sourcing row in the procuring tenant (019_products.sql), not on the product:
-- a provider's selling price is its price to the client, and a client's own sourcing row holds its
-- own. The S10 import (020) writes both there.
--
-- The two columns form the field group sell_price of the field catalog (049_field_catalog.sql),
-- created with the rest of the catalog: management reads and writes it, a coordinator only reads
-- it. The selling price is the one sourcing value a provider's client may see.

COMMENT ON COLUMN public.sourcing.sell_price_eur IS 'The price the procuring tenant sells the product at, in EUR: a provider''s price to its client. Field group sell_price.';

COMMENT ON COLUMN public.sourcing.price_list_version IS 'The price list sell_price_eur comes from. Field group sell_price.';
