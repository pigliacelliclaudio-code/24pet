-- Magazzino scatole: carichi e correzioni dagli amministratori, scarichi automatici dagli ordini evasi
create table public.admin_box_moves (
    id bigint generated always as identity primary key,
    box_id text not null check (box_id ~ '^[a-z0-9-]{1,40}$'),
    qty integer not null check (qty <> 0 and abs(qty) <= 100000),
    kind text not null check (kind in ('carico', 'rettifica', 'scarico')),
    order_id text,
    note text check (char_length(note) <= 300),
    created_at timestamptz not null default now(),
    created_by uuid default auth.uid()
);
create index admin_box_moves_box on public.admin_box_moves (box_id);
create index admin_box_moves_order on public.admin_box_moves (order_id) where order_id is not null;
alter table public.admin_box_moves enable row level security;
revoke all on public.admin_box_moves from public, anon, authenticated;
grant select, insert, delete on public.admin_box_moves to authenticated;
create policy "Administrators read box moves" on public.admin_box_moves for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
create policy "Administrators add boxes" on public.admin_box_moves for insert to authenticated
    with check (kind in ('carico', 'rettifica') and order_id is null
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
create policy "Administrators remove manual box moves" on public.admin_box_moves for delete to authenticated
    using (kind in ('carico', 'rettifica')
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

-- Scatole usate da un ordine: una per urna (dal catalogo) più le scatole di spedizione indicate nell'ordine
create or replace function public.order_box_need(order_data jsonb)
returns table (box_id text, qty integer) language sql stable security definer set search_path = '' as $$
    with lines as (
        select a->>'modello' as model, a->>'dimensione' as size,
               case when (a->>'quantita') ~ '^[0-9]+$' then (a->>'quantita')::integer else 0 end as q
        from jsonb_array_elements(case when jsonb_typeof(order_data->'articoli') = 'array' then order_data->'articoli' else '[]'::jsonb end) a
    ),
    need as (
        select c.data->>'scatola' as box_id, l.q as qty
        from lines l join public.admin_catalog c on c.model = l.model and c.size = l.size
        union all
        select s->>'id', case when (s->>'qta') ~ '^[0-9]+$' then (s->>'qta')::integer else 0 end
        from jsonb_array_elements(case when jsonb_typeof(order_data->'scatoleSpedizione') = 'array' then order_data->'scatoleSpedizione' else '[]'::jsonb end) s
    )
    select n.box_id, sum(n.qty)::integer from need n
    where n.box_id ~ '^[a-z0-9-]{1,40}$' and n.qty > 0
    group by n.box_id
$$;
revoke all on function public.order_box_need(jsonb) from public, anon, authenticated;

create or replace function public.admin_orders_boxes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    is_done boolean;
    was_done boolean;
    tracked boolean;
begin
    if tg_op = 'DELETE' then
        delete from public.admin_box_moves where order_id = old.id and kind = 'scarico';
        return old;
    end if;
    is_done := coalesce((new.data->>'evaso')::boolean, false);
    was_done := tg_op = 'UPDATE' and coalesce((old.data->>'evaso')::boolean, false);
    select exists (select 1 from public.admin_box_moves where order_id = new.id and kind = 'scarico') into tracked;
    if not is_done then
        delete from public.admin_box_moves where order_id = new.id and kind = 'scarico';
        return new;
    end if;
    if was_done and not tracked then
        return new;
    end if;
    delete from public.admin_box_moves where order_id = new.id and kind = 'scarico';
    insert into public.admin_box_moves (box_id, qty, kind, order_id, note)
    select n.box_id, -n.qty, 'scarico', new.id, left('Ordine ' || coalesce(new.data->>'cliente', ''), 300)
    from public.order_box_need(new.data) n;
    return new;
exception when others then
    return coalesce(new, old);
end $$;
revoke all on function public.admin_orders_boxes() from public, anon, authenticated;
create trigger admin_orders_boxes after insert or update or delete on public.admin_orders
    for each row execute function public.admin_orders_boxes();

-- La copia notturna include anche le scatole
create or replace function public.take_admin_backup(backup_kind text default 'auto')
returns bigint language plpgsql security definer set search_path = '' as $$
declare
    new_id bigint;
    o jsonb; c jsonb; k jsonb; s jsonb; f jsonb; b jsonb;
begin
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'data', data, 'updated_at', updated_at) order by id), '[]') into o from public.admin_orders;
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'data', data, 'updated_at', updated_at) order by code), '[]') into c from public.admin_clients;
    select coalesce(jsonb_agg(jsonb_build_object('model', model, 'size', size, 'position', position, 'data', data) order by position, model, size), '[]') into k from public.admin_catalog;
    select coalesce(jsonb_object_agg(key, value), '{}') into s from public.admin_settings where key <> 'migration';
    select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]') into f from public.admin_filament_moves m;
    select coalesce(jsonb_agg(to_jsonb(m) order by m.id), '[]') into b from public.admin_box_moves m;
    insert into public.admin_backups (kind, counts, payload)
    values (backup_kind,
        jsonb_build_object('orders', jsonb_array_length(o), 'clients', jsonb_array_length(c), 'catalog', jsonb_array_length(k), 'filament_moves', jsonb_array_length(f), 'box_moves', jsonb_array_length(b)),
        jsonb_build_object('orders', o, 'clients', c, 'catalog', k, 'settings', s, 'filament_moves', f, 'box_moves', b))
    returning id into new_id;
    delete from public.admin_backups where kind = 'auto' and taken_at < now() - interval '30 days';
    return new_id;
end $$;
revoke all on function public.take_admin_backup(text) from public, anon, authenticated;
