-- La copia notturna include anche le impostazioni del gestionale (per esempio colori urna ↔ filamenti Bambu)
create or replace function public.take_admin_backup(backup_kind text default 'auto')
returns bigint language plpgsql security definer set search_path = '' as $$
declare
    new_id bigint;
    o jsonb; c jsonb; k jsonb; s jsonb;
begin
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'data', data, 'updated_at', updated_at) order by id), '[]') into o from public.admin_orders;
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'data', data, 'updated_at', updated_at) order by code), '[]') into c from public.admin_clients;
    select coalesce(jsonb_agg(jsonb_build_object('model', model, 'size', size, 'position', position, 'data', data) order by position, model, size), '[]') into k from public.admin_catalog;
    select coalesce(jsonb_object_agg(key, value), '{}') into s from public.admin_settings where key <> 'migration';
    insert into public.admin_backups (kind, counts, payload)
    values (backup_kind,
        jsonb_build_object('orders', jsonb_array_length(o), 'clients', jsonb_array_length(c), 'catalog', jsonb_array_length(k)),
        jsonb_build_object('orders', o, 'clients', c, 'catalog', k, 'settings', s))
    returning id into new_id;
    delete from public.admin_backups where kind = 'auto' and taken_at < now() - interval '30 days';
    return new_id;
end $$;
revoke all on function public.take_admin_backup(text) from public, anon, authenticated;
