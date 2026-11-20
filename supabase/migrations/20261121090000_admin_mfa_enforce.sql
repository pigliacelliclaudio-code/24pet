-- Verifica in due passaggi per gli amministratori (fase 2: la richiede il database).
-- Da applicare SOLO dopo che gli amministratori hanno attivato Google Authenticator.
-- Ogni regola che prima chiedeva «ruolo admin» ora chiede public.admin_mfa_ok():
-- ruolo admin + sessione con codice (aal2) + uso della dashboard nelle ultime 48 ore.

alter policy "Administrators read backups" on public.admin_backups using ((select public.admin_mfa_ok()));
alter policy "Administrators read box moves" on public.admin_box_moves using ((select public.admin_mfa_ok()));
alter policy "Administrators read filament moves" on public.admin_filament_moves using ((select public.admin_mfa_ok()));
alter policy "Administrators read magnet moves" on public.admin_magnet_moves using ((select public.admin_mfa_ok()));
alter policy "Administrator reads client access" on public.client_access using ((select public.admin_mfa_ok()));
alter policy "Administrator reads billing profiles" on public.client_billing_profiles using ((select public.admin_mfa_ok()));
alter policy "Administrator reads client profile details" on public.client_profile_details using ((select public.admin_mfa_ok()));
alter policy "Administrator reads dashboard imports" on public.dashboard_imports using ((select public.admin_mfa_ok()));
alter policy "Administrator reads requests" on public.partner_requests using ((select public.admin_mfa_ok()));
alter policy "Administrator deletes requests" on public.partner_requests using ((select public.admin_mfa_ok()));
alter policy "Administrators manage admin_catalog" on public.admin_catalog using ((select public.admin_mfa_ok())) with check ((select public.admin_mfa_ok()));
alter policy "Administrators manage admin_clients" on public.admin_clients using ((select public.admin_mfa_ok())) with check ((select public.admin_mfa_ok()));
alter policy "Administrators manage admin_orders" on public.admin_orders using ((select public.admin_mfa_ok())) with check ((select public.admin_mfa_ok()));
alter policy "Administrators manage admin_settings" on public.admin_settings using ((select public.admin_mfa_ok())) with check ((select public.admin_mfa_ok()));
alter policy "Administrator updates requests" on public.client_order_requests using ((select public.admin_mfa_ok())) with check ((select public.admin_mfa_ok()));
alter policy "Administrators add boxes" on public.admin_box_moves with check (kind = any (array['carico', 'rettifica']) and order_id is null and (select public.admin_mfa_ok()));
alter policy "Administrators add stock" on public.admin_filament_moves with check (kind = any (array['carico', 'rettifica']) and order_id is null and (select public.admin_mfa_ok()));
alter policy "Administrators add magnets" on public.admin_magnet_moves with check (kind = any (array['carico', 'rettifica']) and order_id is null and (select public.admin_mfa_ok()));
alter policy "Administrators remove manual box moves" on public.admin_box_moves using (kind = any (array['carico', 'rettifica']) and (select public.admin_mfa_ok()));
alter policy "Administrators remove manual moves" on public.admin_filament_moves using (kind = any (array['carico', 'rettifica']) and (select public.admin_mfa_ok()));
alter policy "Administrators remove manual magnet moves" on public.admin_magnet_moves using (kind = any (array['carico', 'rettifica']) and (select public.admin_mfa_ok()));
alter policy "Client or administrator reads requests" on public.client_order_requests using (submitted_by = (select auth.uid()) or (select public.admin_mfa_ok()));

create or replace function public.admin_client_accounts()
returns table(client_code text, login_email text, has_account boolean, invite_pending boolean, invited_at timestamptz, last_sign_in_at timestamptz, password_set_at timestamptz, last_seen_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
    select a.client_code, a.invite_email,
           (u.id is not null and u.email_confirmed_at is not null),
           (u.id is not null and u.email_confirmed_at is null),
           u.invited_at, u.last_sign_in_at, a.password_set_at,
           nullif(greatest(coalesce(a.last_seen_at, '-infinity'), coalesce(u.last_sign_in_at, '-infinity')), '-infinity')
    from public.client_access a
    left join auth.users u on u.id = a.user_id
    where (select public.admin_mfa_ok());
$$;
