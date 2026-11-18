-- Gestionale amministratori online: ordini, rubrica e catalogo
create table public.admin_orders (
    id text primary key check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
    data jsonb not null check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 200000),
    updated_at timestamptz not null default now(),
    updated_by uuid default auth.uid()
);
create table public.admin_clients (
    code text primary key check (code ~ '^[A-Za-z0-9_-]{1,32}$'),
    data jsonb not null check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 50000),
    updated_at timestamptz not null default now(),
    updated_by uuid default auth.uid()
);
create table public.admin_catalog (
    model text not null check (char_length(model) between 1 and 80),
    size text not null check (char_length(size) between 1 and 40),
    position integer not null default 0,
    data jsonb not null check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 10000),
    updated_at timestamptz not null default now(),
    updated_by uuid default auth.uid(),
    primary key (model, size)
);
create table public.admin_settings (
    key text primary key check (char_length(key) between 1 and 64),
    value jsonb not null,
    updated_at timestamptz not null default now(),
    updated_by uuid default auth.uid()
);

do $$
declare t text;
begin
    foreach t in array array['admin_orders', 'admin_clients', 'admin_catalog', 'admin_settings'] loop
        execute format('alter table public.%I enable row level security', t);
        execute format('revoke all on public.%I from public, anon, authenticated', t);
        execute format('grant select, insert, update, delete on public.%I to authenticated', t);
        execute format($p$create policy "Administrators manage %s" on public.%I for all to authenticated
            using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'))
            with check (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'))$p$, t, t);
    end loop;
end $$;

create or replace function public.admin_touch_row()
returns trigger language plpgsql set search_path = '' as $$
begin
    new.updated_at := now();
    new.updated_by := auth.uid();
    return new;
end $$;

create trigger admin_orders_touch before update on public.admin_orders for each row execute function public.admin_touch_row();
create trigger admin_clients_touch before update on public.admin_clients for each row execute function public.admin_touch_row();
create trigger admin_catalog_touch before update on public.admin_catalog for each row execute function public.admin_touch_row();
create trigger admin_settings_touch before update on public.admin_settings for each row execute function public.admin_touch_row();

-- Storico visibile ai clienti, derivato dagli ordini del gestionale
create or replace function public.sync_client_order_history_row(order_row public.admin_orders)
returns void language plpgsql security definer set search_path = '' as $$
declare
    d jsonb := order_row.data;
    code text := nullif(d->>'codiceCliente', '');
    order_day date;
begin
    begin
        order_day := (d->>'data')::date;
    exception when others then
        order_day := null;
    end;
    if code is null or order_day is null or jsonb_typeof(d->'articoli') is distinct from 'array'
       or not exists (select 1 from public.client_access a where a.client_code = code) then
        delete from public.client_order_history where order_id = order_row.id;
        return;
    end if;
    insert into public.client_order_history as h (order_id, client_code, order_date, amount, paid, fulfilled, items,
        reseller_discount_pct, extra_discount_pct, shipping_charged)
    values (
        order_row.id, code, order_day,
        coalesce((d->>'importo')::numeric, 0),
        coalesce((d->>'pagato')::boolean, false),
        coalesce((d->>'evaso')::boolean, false),
        (select coalesce(jsonb_agg(jsonb_build_object('colore', a->'colore', 'modello', a->'modello', 'quantita', a->'quantita',
            'dimensione', a->'dimensione', 'prezzoUnitario', a->'prezzoUnitario') order by ord), '[]'::jsonb)
         from jsonb_array_elements(d->'articoli') with ordinality t(a, ord)),
        case when d->>'tipo' = 'Rivenditore' then 25 else 0 end,
        least(greatest(coalesce((d->>'scontoExtraPerc')::numeric, 0), 0), 100),
        case when d->>'spedizioneACarico' = 'Cliente' then greatest(coalesce((d->>'costoSpedizione')::numeric, 0), 0) else 0 end
    )
    on conflict (order_id) do update set
        client_code = excluded.client_code, order_date = excluded.order_date, amount = excluded.amount,
        paid = excluded.paid, fulfilled = excluded.fulfilled, items = excluded.items,
        reseller_discount_pct = excluded.reseller_discount_pct, extra_discount_pct = excluded.extra_discount_pct,
        shipping_charged = excluded.shipping_charged;
exception when others then
    -- Un ordine con dati incompleti non deve impedire il salvataggio nel gestionale
    delete from public.client_order_history where order_id = order_row.id;
end $$;
revoke all on function public.sync_client_order_history_row(public.admin_orders) from public, anon, authenticated;

create or replace function public.admin_orders_to_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    if tg_op = 'DELETE' then
        delete from public.client_order_history where order_id = old.id;
        return old;
    end if;
    perform public.sync_client_order_history_row(new);
    return new;
end $$;
revoke all on function public.admin_orders_to_history() from public, anon, authenticated;
create trigger admin_orders_history after insert or update or delete on public.admin_orders
    for each row execute function public.admin_orders_to_history();

-- Quando un cliente riceve l'accesso, vede subito i suoi ordini
create or replace function public.client_access_backfill_history()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r public.admin_orders;
begin
    for r in select * from public.admin_orders o where o.data->>'codiceCliente' = new.client_code loop
        perform public.sync_client_order_history_row(r);
    end loop;
    return new;
end $$;
revoke all on function public.client_access_backfill_history() from public, anon, authenticated;
create trigger client_access_backfill_history after insert on public.client_access
    for each row execute function public.client_access_backfill_history();

-- Listino visibile ai clienti, derivato dal catalogo
create or replace function public.admin_catalog_to_client()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    if tg_op in ('DELETE', 'UPDATE') then
        delete from public.client_order_catalog where model = old.model and size = old.size;
    end if;
    if tg_op in ('INSERT', 'UPDATE') then
        if (new.data->>'prezzo') ~ '^[0-9]+(\.[0-9]+)?$' then
            insert into public.client_order_catalog (model, size, list_price)
            values (new.model, new.size, (new.data->>'prezzo')::numeric)
            on conflict (model, size) do update set list_price = excluded.list_price;
        end if;
        return new;
    end if;
    return old;
end $$;
revoke all on function public.admin_catalog_to_client() from public, anon, authenticated;
create trigger admin_catalog_client after insert or update or delete on public.admin_catalog
    for each row execute function public.admin_catalog_to_client();

-- Al termine del primo trasferimento allinea listino e storico dei clienti al gestionale
create or replace function public.admin_migration_reconcile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    if new.key = 'migration' then
        delete from public.client_order_catalog c
        where not exists (select 1 from public.admin_catalog a where a.model = c.model and a.size = c.size);
        delete from public.client_order_history h
        where not exists (select 1 from public.admin_orders o where o.id = h.order_id);
    end if;
    return new;
end $$;
revoke all on function public.admin_migration_reconcile() from public, anon, authenticated;
create trigger admin_settings_migration after insert on public.admin_settings
    for each row execute function public.admin_migration_reconcile();
