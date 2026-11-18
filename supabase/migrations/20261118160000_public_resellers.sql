-- Rivenditori visibili sul sito: compilati solo dalla dashboard (scheda cliente, "Mostra sul sito")
create table public.public_resellers (
    client_code text primary key references public.admin_clients (code) on delete cascade,
    name text not null check (char_length(name) between 1 and 120),
    kind text not null default 'agenzia' check (kind in ('agenzia', 'crematorio', 'altro')),
    address text check (char_length(address) <= 200),
    city text not null check (char_length(city) between 1 and 100),
    province text check (province ~ '^[A-Z]{2}$'),
    phone text check (char_length(phone) <= 40),
    email text check (char_length(email) <= 254),
    website text check (char_length(website) <= 200 and website ~ '^https?://'),
    updated_at timestamptz not null default now()
);
alter table public.public_resellers enable row level security;
revoke all on public.public_resellers from public, anon, authenticated;
grant select on public.public_resellers to anon, authenticated;
create policy "Everyone reads public resellers" on public.public_resellers for select to anon, authenticated using (true);

create or replace function public.admin_clients_public_listing()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    s jsonb;
begin
    if tg_op = 'DELETE' then
        return old;
    end if;
    s := new.data->'sito';
    if coalesce((s->>'visibile')::boolean, false) is not true
       or nullif(btrim(s->>'nome'), '') is null or nullif(btrim(s->>'comune'), '') is null then
        delete from public.public_resellers where client_code = new.code;
        return new;
    end if;
    insert into public.public_resellers as r (client_code, name, kind, address, city, province, phone, email, website, updated_at)
    values (
        new.code,
        left(btrim(s->>'nome'), 120),
        case when s->>'tipo' in ('agenzia', 'crematorio', 'altro') then s->>'tipo' else 'agenzia' end,
        nullif(left(btrim(coalesce(s->>'indirizzo', '')), 200), ''),
        left(btrim(s->>'comune'), 100),
        case when upper(btrim(coalesce(s->>'provincia', ''))) ~ '^[A-Z]{2}$' then upper(btrim(s->>'provincia')) end,
        nullif(left(btrim(coalesce(s->>'telefono', '')), 40), ''),
        nullif(left(btrim(coalesce(s->>'email', '')), 254), ''),
        case when btrim(coalesce(s->>'web', '')) ~ '^https?://' then left(btrim(s->>'web'), 200) end,
        now()
    )
    on conflict (client_code) do update set
        name = excluded.name, kind = excluded.kind, address = excluded.address, city = excluded.city,
        province = excluded.province, phone = excluded.phone, email = excluded.email, website = excluded.website,
        updated_at = now();
    return new;
exception when others then
    -- Dati non validi per il sito: il cliente si salva comunque, ma non compare
    delete from public.public_resellers where client_code = new.code;
    return new;
end $$;
revoke all on function public.admin_clients_public_listing() from public, anon, authenticated;
create trigger admin_clients_public_listing after insert or update on public.admin_clients
    for each row execute function public.admin_clients_public_listing();
