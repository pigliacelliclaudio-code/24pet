-- Filamento e calamite si scalano urna per urna, quando l'urna viene spuntata come stampata nella lista di
-- stampa (data.stampate = { "URN-SFE-PIC-A1": 2, ... }), non più tutto insieme quando l'ordine è evaso.
-- Un ordine evaso conta comunque tutte le sue urne. Le scatole restano allo stato «evaso».

-- Urne già spuntate negli ordini aperti prima di oggi: stampate quando il magazzino non le contava,
-- quindi non si scalano (altrimenti le bobine perderebbero di colpo grammi già consumati in passato).
create table public.admin_print_baseline (
    order_id text not null,
    code text not null,
    qty integer not null check (qty > 0),
    primary key (order_id, code)
);
alter table public.admin_print_baseline enable row level security;
revoke all on public.admin_print_baseline from public, anon, authenticated;
insert into public.admin_print_baseline (order_id, code, qty)
select o.id, upper(e.key), e.value::integer
from public.admin_orders o, jsonb_each_text(case when jsonb_typeof(o.data->'stampate') = 'object' then o.data->'stampate' else '{}'::jsonb end) e
where not coalesce((o.data->>'evaso')::boolean, false) and e.value ~ '^[0-9]{1,6}$' and e.value::integer > 0;

-- Urne da scalare per ogni riga dell'ordine: le spuntate (o tutte se evaso) meno quelle già contate prima di oggi
create or replace function public.order_used_lines(p_order_id text, order_data jsonb)
returns table (model text, size text, colour text, qty numeric) language sql stable security definer set search_path = '' as $$
    with arts as (
        select t.n, t.a->>'modello' as model, t.a->>'dimensione' as size, t.a->>'colore' as colour,
               upper(coalesce(t.a->>'sku', '')) as code,
               case when (t.a->>'quantita') ~ '^[0-9]+(\.[0-9]+)?$' then (t.a->>'quantita')::numeric else 0 end as qty
        from jsonb_array_elements(case when jsonb_typeof(order_data->'articoli') = 'array' then order_data->'articoli' else '[]'::jsonb end) with ordinality as t(a, n)
    ),
    alloc as (
        select a.*,
               coalesce(sum(a.qty) over (partition by a.code order by a.n rows between unbounded preceding and 1 preceding), 0) as before,
               case when (order_data->'stampate'->>a.code) ~ '^[0-9]{1,6}$' then (order_data->'stampate'->>a.code)::numeric else 0 end as printed,
               coalesce((select b.qty from public.admin_print_baseline b where b.order_id = p_order_id and b.code = a.code), 0) as base
        from arts a
    )
    select model, size, colour,
           greatest(0,
               (case when coalesce((order_data->>'evaso')::boolean, false) then qty else least(qty, greatest(0, printed - before)) end)
               - least(qty, greatest(0, base - before)))
    from alloc
$$;
revoke all on function public.order_used_lines(text, jsonb) from public, anon, authenticated;

create or replace function public.order_filament_used(p_order_id text, order_data jsonb)
returns table (code text, grams numeric) language sql stable security definer set search_path = '' as $$
    with settings as (
        select coalesce((select value from public.admin_settings where key = 'colori_bambu'), '{}'::jsonb) as cmap,
               coalesce((select value->>'bianco' from public.admin_settings where key = 'magazzino'), '11100') as white
    ),
    joined as (
        select l.qty, l.colour,
               case when (c.data->>'grammiColore') ~ '^[0-9]+(\.[0-9]+)?$' then (c.data->>'grammiColore')::numeric else 0 end as g_colour,
               case when (c.data->>'grammiBianco') ~ '^[0-9]+(\.[0-9]+)?$' then (c.data->>'grammiBianco')::numeric else 0 end as g_white
        from public.order_used_lines(p_order_id, order_data) l
        join public.admin_catalog c on c.model = l.model and c.size = l.size
        where l.qty > 0
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
revoke all on function public.order_filament_used(text, jsonb) from public, anon, authenticated;

create or replace function public.order_magnet_used(p_order_id text, order_data jsonb)
returns table (magnet_id text, qty integer) language sql stable security definer set search_path = '' as $$
    select m->>'tipo', sum(l.qty * (m->>'qty')::integer)::integer
    from public.order_used_lines(p_order_id, order_data) l
    join public.admin_catalog c on c.model = l.model and c.size = l.size
    cross join lateral jsonb_array_elements(case when jsonb_typeof(c.data->'calamite') = 'array' then c.data->'calamite' else '[]'::jsonb end) m
    where l.qty > 0 and (m->>'tipo') ~ '^[a-z0-9-]{1,40}$' and (m->>'qty') ~ '^[0-9]{1,4}$' and (m->>'qty')::integer > 0
    group by m->>'tipo'
$$;
revoke all on function public.order_magnet_used(text, jsonb) from public, anon, authenticated;

create or replace function public.admin_orders_filament()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    was_done boolean;
    tracked boolean;
begin
    if tg_op = 'DELETE' then
        delete from public.admin_filament_moves where order_id = old.id and kind = 'scarico';
        delete from public.admin_print_baseline where order_id = old.id;
        return old;
    end if;
    was_done := tg_op = 'UPDATE' and coalesce((old.data->>'evaso')::boolean, false);
    select exists (select 1 from public.admin_filament_moves where order_id = new.id and kind = 'scarico') into tracked;
    -- Gli ordini evasi prima del magazzino non vengono toccati
    if was_done and coalesce((new.data->>'evaso')::boolean, false) and not tracked then
        return new;
    end if;
    delete from public.admin_filament_moves where order_id = new.id and kind = 'scarico';
    insert into public.admin_filament_moves (code, grams, kind, order_id, note)
    select n.code, -round(n.grams), 'scarico', new.id, left('Urne stampate · ' || coalesce(new.data->>'cliente', ''), 300)
    from public.order_filament_used(new.id, new.data) n where round(n.grams) > 0;
    return new;
exception when others then
    -- Un problema nel calcolo non deve impedire di salvare l'ordine
    return coalesce(new, old);
end $$;
revoke all on function public.admin_orders_filament() from public, anon, authenticated;

create or replace function public.admin_orders_magnets()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    was_done boolean;
    tracked boolean;
begin
    if tg_op = 'DELETE' then
        delete from public.admin_magnet_moves where order_id = old.id and kind = 'scarico';
        return old;
    end if;
    was_done := tg_op = 'UPDATE' and coalesce((old.data->>'evaso')::boolean, false);
    select exists (select 1 from public.admin_magnet_moves where order_id = new.id and kind = 'scarico') into tracked;
    if was_done and coalesce((new.data->>'evaso')::boolean, false) and not tracked then
        return new;
    end if;
    delete from public.admin_magnet_moves where order_id = new.id and kind = 'scarico';
    insert into public.admin_magnet_moves (magnet_id, qty, kind, order_id, note)
    select n.magnet_id, -n.qty, 'scarico', new.id, left('Urne stampate · ' || coalesce(new.data->>'cliente', ''), 300)
    from public.order_magnet_used(new.id, new.data) n where n.qty > 0;
    return new;
exception when others then
    return coalesce(new, old);
end $$;
revoke all on function public.admin_orders_magnets() from public, anon, authenticated;
