-- Verifica in due passaggi per gli amministratori (fase 1: solo funzioni, nessuna regola cambia).
-- Un amministratore è "verificato" se la sua sessione è aal2 (password + codice dell'app)
-- e se ha usato la dashboard, o inserito un codice, nelle ultime 48 ore.
create table if not exists public.admin_mfa_activity (
    user_id uuid primary key references auth.users (id) on delete cascade,
    last_active_at timestamptz not null default now()
);
alter table public.admin_mfa_activity enable row level security;
revoke all on public.admin_mfa_activity from anon, authenticated;

create or replace function public.admin_mfa_ok()
returns boolean
language sql stable security definer
set search_path = ''
as $$
    select exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin')
       and coalesce((select auth.jwt() ->> 'aal'), '') = 'aal2'
       and coalesce(greatest(
               (select a.last_active_at from public.admin_mfa_activity a where a.user_id = (select auth.uid())),
               (select max(c.verified_at) from auth.mfa_challenges c
                  join auth.mfa_factors f on f.id = c.factor_id
                 where f.user_id = (select auth.uid()) and f.status = 'verified')
           ) > now() - interval '48 hours', false);
$$;

-- Segna l'uso della dashboard. Non riapre una finestra scaduta: dopo 48 ore serve di nuovo il codice.
create or replace function public.admin_mark_active()
returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
begin
    if not public.admin_mfa_ok() then
        return false;
    end if;
    insert into public.admin_mfa_activity (user_id, last_active_at)
    values ((select auth.uid()), now())
    on conflict (user_id) do update set last_active_at = excluded.last_active_at;
    return true;
end;
$$;

revoke all on function public.admin_mfa_ok() from public, anon;
revoke all on function public.admin_mark_active() from public, anon;
grant execute on function public.admin_mfa_ok() to authenticated;
grant execute on function public.admin_mark_active() to authenticated;
