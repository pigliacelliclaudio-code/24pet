-- Quando il cliente sceglie la password (dal link d'invito o di recupero) lo registriamo: nel gestionale
-- l'amministratore vede «Password creata il …» invece di dover indovinare dall'ultimo accesso.
alter table public.client_access add column password_set_at timestamptz;

create function public.client_mark_password_set()
returns void language sql security definer set search_path = '' as $$
    update public.client_access set password_set_at = now() where user_id = (select auth.uid());
$$;
revoke all on function public.client_mark_password_set() from public, anon;
grant execute on function public.client_mark_password_set() to authenticated;

drop function public.admin_client_accounts();
create function public.admin_client_accounts()
returns table (client_code text, login_email text, has_account boolean, invite_pending boolean, invited_at timestamptz, last_sign_in_at timestamptz, password_set_at timestamptz)
language sql stable security definer set search_path = '' as $$
    select a.client_code, a.invite_email,
           (u.id is not null and u.email_confirmed_at is not null),
           (u.id is not null and u.email_confirmed_at is null),
           u.invited_at, u.last_sign_in_at, a.password_set_at
    from public.client_access a
    left join auth.users u on u.id = a.user_id
    where exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin');
$$;
revoke all on function public.admin_client_accounts() from public, anon;
grant execute on function public.admin_client_accounts() to authenticated;
