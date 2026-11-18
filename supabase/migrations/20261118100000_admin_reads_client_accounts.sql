-- Administrators can read client billing profiles and the access status of client accounts (read-only).
create policy "Administrator reads billing profiles"
    on public.client_billing_profiles for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

create policy "Administrator reads client access"
    on public.client_access for select to authenticated
    using (exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin'));

create function public.admin_client_accounts()
returns table (client_code text, login_email text, has_account boolean, last_sign_in_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
    select a.client_code, a.invite_email, a.user_id is not null, u.last_sign_in_at
    from public.client_access a
    left join auth.users u on u.id = a.user_id
    where exists (select 1 from public.user_roles r where r.user_id = (select auth.uid()) and r.role = 'admin');
$$;
revoke all on function public.admin_client_accounts() from public, anon;
grant execute on function public.admin_client_accounts() to authenticated;
