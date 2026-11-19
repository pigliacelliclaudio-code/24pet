-- Full client profile: the client fills in contacts, shipping address, delivery details and the
-- label logo from the reserved area. Whatever the client saves is copied into the administrator's
-- rubrica (admin_clients.data), so the admin never has to ask for it. The client sees the rubrica
-- values first, so data the admin already has appears pre-filled.

create table public.client_profile_details (
    client_code text primary key references public.client_access (client_code) on delete cascade,
    contact_name text check (char_length(contact_name) <= 120),
    phone text check (char_length(phone) <= 40),
    mobile text check (char_length(mobile) <= 40),
    email text check (email is null or (char_length(email) <= 254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')),
    website text check (website is null or (char_length(website) <= 200 and website ~* '^https?://[^[:space:]]+$')),
    shipping_same boolean not null default true,
    shipping_at text check (char_length(shipping_at) <= 120),
    shipping_street text check (char_length(shipping_street) <= 200),
    shipping_postal_code text check (shipping_postal_code ~ '^[0-9]{5}$'),
    shipping_city text check (char_length(shipping_city) <= 100),
    shipping_province text check (shipping_province ~ '^[A-Z]{2}$'),
    shipping_contact text check (char_length(shipping_contact) <= 120),
    shipping_phone text check (char_length(shipping_phone) <= 40),
    delivery_hours text check (char_length(delivery_hours) <= 200),
    delivery_notes text check (char_length(delivery_notes) <= 500),
    logo text check (logo is null or (char_length(logo) <= 200000 and logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$')),
    -- Public listing on 24pet.it: null = never chosen by the client (the admin's setting stays),
    -- true/false = the client's own choice, with the moment consent was given.
    listing_consent boolean,
    listing_consent_at timestamptz,
    listing_name text check (char_length(listing_name) <= 120),
    listing_kind text check (listing_kind in ('agenzia', 'crematorio', 'altro')),
    listing_street text check (char_length(listing_street) <= 200),
    listing_city text check (char_length(listing_city) <= 100),
    listing_province text check (listing_province ~ '^[A-Z]{2}$'),
    listing_phone text check (char_length(listing_phone) <= 40),
    listing_mobile text check (char_length(listing_mobile) <= 40),
    listing_website text check (listing_website is null or (char_length(listing_website) <= 200 and listing_website ~* '^https?://[^[:space:]]+$')),
    check (listing_consent is not true or (nullif(btrim(listing_name), '') is not null and nullif(btrim(listing_city), '') is not null)),
    updated_at timestamptz not null default now()
);

alter table public.client_profile_details enable row level security;
revoke all on public.client_profile_details from public, anon, authenticated;
grant select, insert, update on public.client_profile_details to authenticated;

create policy "Client manages own profile details"
    on public.client_profile_details
    for all to authenticated
    using (
        client_code in (select a.client_code from public.client_access a where a.user_id = (select auth.uid()))
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'client')
    )
    with check (
        client_code in (select a.client_code from public.client_access a where a.user_id = (select auth.uid()))
        and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'client')
    );

create policy "Administrator reads client profile details"
    on public.client_profile_details
    for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

-- "Via Roma 1 - 00100 Roma (RM)", the same format the admin dashboard uses.
create function public.client_format_address(presso text, street text, cap text, city text, province text)
returns text language sql immutable set search_path = '' as $$
    select concat_ws(' - ',
        nullif(btrim(coalesce(presso, '')), ''),
        nullif(btrim(coalesce(street, '')), ''),
        nullif(btrim(concat_ws(' ', nullif(cap, ''), nullif(city, '')) || case when coalesce(province, '') <> '' then ' (' || upper(province) || ')' else '' end), ''));
$$;

-- Fiscal data → rubrica.
create function public.client_billing_to_rubrica()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    update public.admin_clients set data = data || jsonb_build_object(
        'ragioneSociale', coalesce(new.legal_name, ''),
        'partitaIva', coalesce(new.vat_number, ''),
        'fatturazione', jsonb_build_object('via', coalesce(new.street_address, ''), 'cap', coalesce(new.postal_code, ''),
                                           'comune', coalesce(new.city, ''), 'provincia', coalesce(new.province, '')),
        'indirizzoSede', public.client_format_address(null, new.street_address, new.postal_code, new.city, new.province),
        'codiceFiscale', coalesce(new.tax_code, ''),
        'codiceUnivoco', coalesce(new.recipient_code, ''),
        'pec', coalesce(new.certified_email, '')
    ) where code = new.client_code;
    return new;
end $$;
revoke all on function public.client_billing_to_rubrica() from public, anon, authenticated;
create trigger client_billing_to_rubrica after insert or update on public.client_billing_profiles
    for each row execute function public.client_billing_to_rubrica();

-- Contacts, shipping, delivery and logo → rubrica.
create function public.client_details_to_rubrica()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    new.updated_at := now();
    -- Consent timestamp is set by the server, never trusted from the browser.
    if new.listing_consent is true and (tg_op = 'INSERT' or old.listing_consent is distinct from true) then
        new.listing_consent_at := now();
    elsif new.listing_consent is not true then
        new.listing_consent_at := null;
    else
        new.listing_consent_at := old.listing_consent_at;
    end if;
    if new.listing_consent is not null then
        update public.admin_clients set data = data || jsonb_build_object('sito', jsonb_build_object(
            'visibile', new.listing_consent,
            'nome', coalesce(new.listing_name, ''), 'tipo', coalesce(new.listing_kind, 'agenzia'),
            'indirizzo', coalesce(new.listing_street, ''), 'comune', coalesce(new.listing_city, ''),
            'provincia', coalesce(new.listing_province, ''), 'telefono', coalesce(new.listing_phone, ''),
            'cellulare', coalesce(new.listing_mobile, ''), 'email', '', 'web', coalesce(new.listing_website, ''),
            'consensoCliente', case when new.listing_consent then to_jsonb(new.listing_consent_at) else 'null'::jsonb end))
        where code = new.client_code;
    end if;
    update public.admin_clients set data = data || jsonb_build_object(
        'referente', coalesce(new.contact_name, ''),
        'telefono', coalesce(new.phone, ''),
        'cellulare', coalesce(new.mobile, ''),
        'email', coalesce(new.email, ''),
        'sitoWeb', coalesce(new.website, ''),
        'spedizioneUguale', new.shipping_same,
        'spedizione', case when new.shipping_same then 'null'::jsonb else jsonb_build_object(
            'presso', coalesce(new.shipping_at, ''), 'via', coalesce(new.shipping_street, ''), 'cap', coalesce(new.shipping_postal_code, ''),
            'comune', coalesce(new.shipping_city, ''), 'provincia', coalesce(new.shipping_province, '')) end,
        'indirizzoSpedizione', case when new.shipping_same then '' else
            public.client_format_address(new.shipping_at, new.shipping_street, new.shipping_postal_code, new.shipping_city, new.shipping_province) end,
        'referenteSpedizione', coalesce(new.shipping_contact, ''),
        'telefonoSpedizione', coalesce(new.shipping_phone, ''),
        'orariConsegna', coalesce(new.delivery_hours, ''),
        'noteConsegna', coalesce(new.delivery_notes, ''),
        'logo', coalesce(to_jsonb(new.logo), 'null'::jsonb)
    ) where code = new.client_code;
    return new;
end $$;
revoke all on function public.client_details_to_rubrica() from public, anon, authenticated;
create trigger client_details_to_rubrica before insert or update on public.client_profile_details
    for each row execute function public.client_details_to_rubrica();

-- What the admin already has for the signed-in client, limited to the profile fields.
create function public.client_rubrica_profile()
returns jsonb language sql stable security definer set search_path = '' as $$
    select jsonb_strip_nulls(jsonb_build_object(
        'ragioneSociale', c.data->'ragioneSociale', 'partitaIva', c.data->'partitaIva',
        'fatturazione', c.data->'fatturazione', 'indirizzoSede', c.data->'indirizzoSede',
        'codiceFiscale', c.data->'codiceFiscale', 'codiceUnivoco', c.data->'codiceUnivoco', 'pec', c.data->'pec',
        'referente', c.data->'referente', 'telefono', c.data->'telefono', 'cellulare', c.data->'cellulare',
        'email', c.data->'email', 'sitoWeb', c.data->'sitoWeb',
        'spedizioneUguale', c.data->'spedizioneUguale', 'spedizione', c.data->'spedizione', 'indirizzoSpedizione', c.data->'indirizzoSpedizione',
        'referenteSpedizione', c.data->'referenteSpedizione', 'telefonoSpedizione', c.data->'telefonoSpedizione',
        'orariConsegna', c.data->'orariConsegna', 'noteConsegna', c.data->'noteConsegna', 'logo', c.data->'logo',
        'sito', c.data->'sito'))
    from public.admin_clients c
    join public.client_access a on a.client_code = c.code
    where a.user_id = (select auth.uid())
      and exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'client');
$$;
revoke all on function public.client_rubrica_profile() from public, anon;
grant execute on function public.client_rubrica_profile() to authenticated;

-- Public list: mobile number too (published only when the business asks for it).
alter table public.public_resellers add column mobile text check (char_length(mobile) <= 40);

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
    insert into public.public_resellers as r (client_code, name, kind, address, city, province, phone, mobile, email, website, updated_at)
    values (
        new.code,
        left(btrim(s->>'nome'), 120),
        case when s->>'tipo' in ('agenzia', 'crematorio', 'altro') then s->>'tipo' else 'agenzia' end,
        nullif(left(btrim(coalesce(s->>'indirizzo', '')), 200), ''),
        left(btrim(s->>'comune'), 100),
        case when upper(btrim(coalesce(s->>'provincia', ''))) ~ '^[A-Z]{2}$' then upper(btrim(s->>'provincia')) end,
        nullif(left(btrim(coalesce(s->>'telefono', '')), 40), ''),
        nullif(left(btrim(coalesce(s->>'cellulare', '')), 40), ''),
        nullif(left(btrim(coalesce(s->>'email', '')), 254), ''),
        case when btrim(coalesce(s->>'web', '')) ~ '^https?://' then left(btrim(s->>'web'), 200) end,
        now()
    )
    on conflict (client_code) do update set
        name = excluded.name, kind = excluded.kind, address = excluded.address, city = excluded.city,
        province = excluded.province, phone = excluded.phone, mobile = excluded.mobile, email = excluded.email,
        website = excluded.website, updated_at = now();
    return new;
exception when others then
    delete from public.public_resellers where client_code = new.code;
    return new;
end $$;
revoke all on function public.admin_clients_public_listing() from public, anon, authenticated;

-- The administrator can reject (delete) a professional access request.
grant delete on public.partner_requests to authenticated;
create policy "Administrator deletes requests" on public.partner_requests for delete to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));
