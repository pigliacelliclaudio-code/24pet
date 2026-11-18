-- Copia automatica notturna del gestionale, conservata per 30 giorni
create table public.admin_backups (
    id bigint generated always as identity primary key,
    taken_at timestamptz not null default now(),
    kind text not null default 'auto' check (kind in ('auto', 'manual')),
    counts jsonb not null,
    payload jsonb not null
);
alter table public.admin_backups enable row level security;
revoke all on public.admin_backups from public, anon, authenticated;
grant select on public.admin_backups to authenticated;
create policy "Administrators read backups" on public.admin_backups for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
create index admin_backups_taken_at on public.admin_backups (taken_at desc);

create or replace function public.take_admin_backup(backup_kind text default 'auto')
returns bigint language plpgsql security definer set search_path = '' as $$
declare
    new_id bigint;
    o jsonb; c jsonb; k jsonb;
begin
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'data', data, 'updated_at', updated_at) order by id), '[]') into o from public.admin_orders;
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'data', data, 'updated_at', updated_at) order by code), '[]') into c from public.admin_clients;
    select coalesce(jsonb_agg(jsonb_build_object('model', model, 'size', size, 'position', position, 'data', data) order by position, model, size), '[]') into k from public.admin_catalog;
    insert into public.admin_backups (kind, counts, payload)
    values (backup_kind,
        jsonb_build_object('orders', jsonb_array_length(o), 'clients', jsonb_array_length(c), 'catalog', jsonb_array_length(k)),
        jsonb_build_object('orders', o, 'clients', c, 'catalog', k))
    returning id into new_id;
    delete from public.admin_backups where kind = 'auto' and taken_at < now() - interval '30 days';
    return new_id;
end $$;
revoke all on function public.take_admin_backup(text) from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('24pet-admin-nightly-backup', '0 2 * * *', $$select public.take_admin_backup('auto')$$);
