-- Order requests get a status: the administrator turns a request into an order (or rejects it) and
-- the client sees the outcome instead of "waiting for confirmation" forever.
alter table public.client_order_requests
    add column status text not null default 'nuova' check (status in ('nuova', 'accettata', 'rifiutata')),
    add column order_id text check (char_length(order_id) <= 40),
    add column handled_at timestamptz;

grant select (status, order_id, handled_at) on public.client_order_requests to authenticated;
grant update (status, order_id) on public.client_order_requests to authenticated;

create policy "Administrator updates requests" on public.client_order_requests
    for update to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'))
    with check (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

-- The moment of the decision comes from the server clock.
create function public.client_order_requests_handled()
returns trigger language plpgsql set search_path = '' as $$
begin
    if new.status is distinct from old.status then
        new.handled_at := case when new.status = 'nuova' then null else now() end;
    else
        new.handled_at := old.handled_at;
    end if;
    return new;
end $$;
create trigger client_order_requests_handled before update on public.client_order_requests
    for each row execute function public.client_order_requests_handled();

create index client_order_requests_client_code_idx on public.client_order_requests (client_code);
create index client_order_requests_submitted_by_idx on public.client_order_requests (submitted_by);
