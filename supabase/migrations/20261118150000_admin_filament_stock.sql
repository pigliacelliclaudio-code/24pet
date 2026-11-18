-- Magazzino filamenti: carichi e correzioni inseriti dagli amministratori, scarichi automatici dagli ordini evasi
create table public.admin_filament_moves (
    id bigint generated always as identity primary key,
    code text not null check (code ~ '^[0-9]{5}$'),
    grams numeric not null check (grams <> 0 and abs(grams) <= 1000000),
    kind text not null check (kind in ('carico', 'rettifica', 'scarico')),
    order_id text,
    note text check (char_length(note) <= 300),
    created_at timestamptz not null default now(),
    created_by uuid default auth.uid()
);
create index admin_filament_moves_code on public.admin_filament_moves (code);
create index admin_filament_moves_order on public.admin_filament_moves (order_id) where order_id is not null;
alter table public.admin_filament_moves enable row level security;
revoke all on public.admin_filament_moves from public, anon, authenticated;
grant select, insert, delete on public.admin_filament_moves to authenticated;
create policy "Administrators read filament moves" on public.admin_filament_moves for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
create policy "Administrators add stock" on public.admin_filament_moves for insert to authenticated
    with check (kind in ('carico', 'rettifica') and order_id is null
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
create policy "Administrators remove manual moves" on public.admin_filament_moves for delete to authenticated
    using (kind in ('carico', 'rettifica')
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

-- Grammi di filamento usati da un ordine, per codice Bambu
create or replace function public.order_filament_need(order_data jsonb)
returns table (code text, grams numeric) language sql stable security definer set search_path = '' as $$
    with settings as (
        select coalesce((select value from public.admin_settings where key = 'colori_bambu'), '{}'::jsonb) as cmap,
               coalesce((select value->>'bianco' from public.admin_settings where key = 'magazzino'), '11100') as white
    ),
    lines as (
        select a->>'modello' as model, a->>'dimensione' as size, a->>'colore' as colour,
               case when (a->>'quantita') ~ '^[0-9]+(\.[0-9]+)?$' then (a->>'quantita')::numeric else 0 end as qty
        from jsonb_array_elements(case when jsonb_typeof(order_data->'articoli') = 'array' then order_data->'articoli' else '[]'::jsonb end) a
    ),
    joined as (
        select l.qty, l.colour,
               case when (c.data->>'grammiColore') ~ '^[0-9]+(\.[0-9]+)?$' then (c.data->>'grammiColore')::numeric else 0 end as g_colour,
               case when (c.data->>'grammiBianco') ~ '^[0-9]+(\.[0-9]+)?$' then (c.data->>'grammiBianco')::numeric else 0 end as g_white
        from lines l join public.admin_catalog c on c.model = l.model and c.size = l.size
    ),
    need as (
        select s.cmap->>j.colour as code, j.qty * j.g_colour as grams from joined j, settings s
        union all
        select s.white, j.qty * j.g_white from joined j, settings s
    )
    select n.code, sum(n.grams) from need n
    where n.code ~ '^[0-9]{5}$' and n.grams > 0
    group by n.code
$$;
revoke all on function public.order_filament_need(jsonb) from public, anon, authenticated;

create or replace function public.admin_orders_filament()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    is_done boolean;
    was_done boolean;
    tracked boolean;
begin
    if tg_op = 'DELETE' then
        delete from public.admin_filament_moves where order_id = old.id and kind = 'scarico';
        return old;
    end if;
    is_done := coalesce((new.data->>'evaso')::boolean, false);
    was_done := tg_op = 'UPDATE' and coalesce((old.data->>'evaso')::boolean, false);
    select exists (select 1 from public.admin_filament_moves where order_id = new.id and kind = 'scarico') into tracked;
    if not is_done then
        delete from public.admin_filament_moves where order_id = new.id and kind = 'scarico';
        return new;
    end if;
    -- Scarica quando l'ordine diventa evaso; se era già scaricato e viene modificato, ricalcola.
    -- Gli ordini evasi prima del magazzino non vengono toccati.
    if was_done and not tracked then
        return new;
    end if;
    delete from public.admin_filament_moves where order_id = new.id and kind = 'scarico';
    insert into public.admin_filament_moves (code, grams, kind, order_id, note)
    select n.code, -n.grams, 'scarico', new.id, left('Ordine ' || coalesce(new.data->>'cliente', ''), 300)
    from public.order_filament_need(new.data) n;
    return new;
exception when others then
    -- Un problema nel calcolo non deve impedire di salvare l'ordine
    return coalesce(new, old);
end $$;
revoke all on function public.admin_orders_filament() from public, anon, authenticated;
create trigger admin_orders_filament after insert or update or delete on public.admin_orders
    for each row execute function public.admin_orders_filament();

-- La copia notturna include il magazzino
create or replace function public.take_admin_backup(backup_kind text default 'auto')
returns bigint language plpgsql security definer set search_path = '' as $$
declare
    new_id bigint;
    o jsonb; c jsonb; k jsonb; s jsonb; f jsonb;
begin
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'data', data, 'updated_at', updated_at) order by id), '[]') into o from public.admin_orders;
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'data', data, 'updated_at', updated_at) order by code), '[]') into c from public.admin_clients;
    select coalesce(jsonb_agg(jsonb_build_object('model', model, 'size', size, 'position', position, 'data', data) order by position, model, size), '[]') into k from public.admin_catalog;
    select coalesce(jsonb_object_agg(key, value), '{}') into s from public.admin_settings where key <> 'migration';
    select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]') into f from public.admin_filament_moves m;
    insert into public.admin_backups (kind, counts, payload)
    values (backup_kind,
        jsonb_build_object('orders', jsonb_array_length(o), 'clients', jsonb_array_length(c), 'catalog', jsonb_array_length(k), 'filament_moves', jsonb_array_length(f)),
        jsonb_build_object('orders', o, 'clients', c, 'catalog', k, 'settings', s, 'filament_moves', f))
    returning id into new_id;
    delete from public.admin_backups where kind = 'auto' and taken_at < now() - interval '30 days';
    return new_id;
end $$;
revoke all on function public.take_admin_backup(text) from public, anon, authenticated;
