-- Client-safe price breakdown for the order history (no internal costs or margins).
alter table public.client_order_history
    add column reseller_discount_pct numeric(5,2) not null default 0 check (reseller_discount_pct between 0 and 100),
    add column extra_discount_pct numeric(5,2) not null default 0 check (extra_discount_pct between 0 and 100),
    add column shipping_charged numeric(10,2) not null default 0 check (shipping_charged >= 0);

grant select (reseller_discount_pct, extra_discount_pct, shipping_charged) on public.client_order_history to authenticated;

with original_orders as (
    select source_order.value as data
    from public.dashboard_imports imports
    cross join lateral jsonb_array_elements(imports.payload->'orders') source_order
    where imports.import_id = 'legacy-2026-11-16'
)
update public.client_order_history history
set reseller_discount_pct = case when original.data->>'tipo' = 'Rivenditore' then 25 else 0 end,
    extra_discount_pct = case when original.data->>'scontoExtraPerc' ~ '^[0-9]+([.][0-9]+)?$'
        then (original.data->>'scontoExtraPerc')::numeric else 0 end,
    shipping_charged = case when original.data->>'spedizioneACarico' = 'Cliente'
        and original.data->>'costoSpedizione' ~ '^[0-9]+([.][0-9]+)?$'
        then (original.data->>'costoSpedizione')::numeric else 0 end
from original_orders original
where original.data->>'id' = history.order_id
    and original.data->>'codiceCliente' = history.client_code;
