-- Limite alle richieste di accesso anonime dal sito (contro spam e intasamento delle notifiche)
create or replace function public.partner_requests_rate_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    if (select count(*) from public.partner_requests where created_at > now() - interval '10 minutes') >= 5 then
        raise exception 'Troppe richieste, riprova più tardi' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.partner_requests where lower(email) = lower(new.email) and created_at > now() - interval '24 hours') then
        raise exception 'Richiesta già ricevuta' using errcode = 'check_violation';
    end if;
    return new;
end $$;
revoke all on function public.partner_requests_rate_limit() from public, anon, authenticated;
drop trigger if exists partner_requests_rate_limit on public.partner_requests;
create trigger partner_requests_rate_limit before insert on public.partner_requests
    for each row execute function public.partner_requests_rate_limit();

-- Le funzioni dei trigger non devono essere chiamabili dall'esterno
revoke all on function public.admin_touch_row() from public, anon, authenticated;
