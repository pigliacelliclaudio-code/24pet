create table public.client_billing_profiles (
    client_code text primary key references public.client_access (client_code) on delete cascade,
    legal_name text not null check (char_length(legal_name) <= 160 and legal_name ~ '[^[:space:]]'),
    vat_number text not null check (vat_number ~ '^[0-9]{11}$'),
    street_address text not null check (char_length(street_address) <= 200 and street_address ~ '[^[:space:]]'),
    postal_code text not null check (postal_code ~ '^[0-9]{5}$'),
    city text not null check (char_length(city) <= 100 and city ~ '[^[:space:]]'),
    province text not null check (province ~ '^[A-Z]{2}$'),
    tax_code text check (tax_code ~ '^([A-Z0-9]{16}|[0-9]{11})$'),
    recipient_code text check (recipient_code ~ '^[A-Z0-9]{7}$'),
    certified_email text check (char_length(certified_email) <= 254 and certified_email ~ '^[^[:space:]@]+@[^[:space:]@]+$')
);

alter table public.client_billing_profiles enable row level security;
revoke all on public.client_billing_profiles from public, anon, authenticated;
grant select, insert, update on public.client_billing_profiles to authenticated;

create policy "Client manages own billing profile"
    on public.client_billing_profiles
    for all to authenticated
    using (
        client_code in (select a.client_code from public.client_access a where a.user_id = (select auth.uid()))
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'client')
    )
    with check (
        client_code in (select a.client_code from public.client_access a where a.user_id = (select auth.uid()))
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'client')
    );

alter table public.client_order_requests add column billing_details jsonb;
grant select (billing_details) on public.client_order_requests to authenticated;

create function public.capture_client_order_billing()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    if current_user = 'authenticated' then
        select jsonb_strip_nulls(jsonb_build_object(
            'legal_name', profile.legal_name,
            'vat_number', profile.vat_number,
            'street_address', profile.street_address,
            'postal_code', profile.postal_code,
            'city', profile.city,
            'province', profile.province,
            'tax_code', profile.tax_code,
            'recipient_code', profile.recipient_code,
            'certified_email', profile.certified_email
        )) into new.billing_details
        from public.client_billing_profiles profile
        where profile.client_code = new.client_code;
    end if;
    return new;
end;
$$;

revoke all on function public.capture_client_order_billing() from public, anon, authenticated;

create trigger capture_client_order_billing
    before insert on public.client_order_requests
    for each row execute function public.capture_client_order_billing();

-- Copy only the historical list price. The admin backup contains internal costs.
with original_orders as (
    select source_order.value as data
    from public.dashboard_imports imports
    cross join lateral jsonb_array_elements(imports.payload->'orders') source_order
    where imports.import_id = 'legacy-2026-11-16'
), priced_orders as (
    select history.order_id, jsonb_agg(
        case when source_item.value->>'prezzoUnitario' ~ '^[0-9]+([.][0-9]+)?$'
            and (source_item.value->>'modello') is not distinct from (history_item.value->>'modello')
            and (source_item.value->>'dimensione') is not distinct from (history_item.value->>'dimensione')
            and (source_item.value->>'colore') is not distinct from (history_item.value->>'colore')
            and (source_item.value->>'quantita') is not distinct from (history_item.value->>'quantita')
            then history_item.value || jsonb_build_object('prezzoUnitario', (source_item.value->>'prezzoUnitario')::numeric)
            else history_item.value
        end order by history_item.position
    ) as items
    from public.client_order_history history
    join original_orders original on original.data->>'id' = history.order_id
        and original.data->>'codiceCliente' = history.client_code
    cross join lateral jsonb_array_elements(history.items) with ordinality history_item(value, position)
    left join lateral jsonb_array_elements(original.data->'articoli') with ordinality source_item(value, position)
        on source_item.position = history_item.position
    group by history.order_id
)
update public.client_order_history history
set items = priced_orders.items
from priced_orders
where history.order_id = priced_orders.order_id and history.items is distinct from priced_orders.items;
