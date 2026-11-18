-- Live dashboard badges (Realtime) and Telegram notifications for new requests.
create extension if not exists pg_net with schema extensions;

create table public.notification_log (
    source text not null,
    record_id uuid not null,
    sent_at timestamptz not null default now(),
    primary key (source, record_id)
);
alter table public.notification_log enable row level security;
revoke all on public.notification_log from public, anon, authenticated;

create function public.notify_new_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    begin
        perform net.http_post(
            url := 'https://vacxudtbzpfygkkxmhyz.supabase.co/functions/v1/notify-telegram',
            body := jsonb_build_object('table', tg_table_name, 'id', new.id),
            headers := '{"Content-Type": "application/json"}'::jsonb,
            timeout_milliseconds := 5000
        );
    exception when others then
        null; -- a notification problem must never block the request itself
    end;
    return new;
end;
$$;
revoke all on function public.notify_new_request() from public, anon, authenticated;

create trigger notify_new_order_request
    after insert on public.client_order_requests
    for each row execute function public.notify_new_request();

create trigger notify_new_partner_request
    after insert on public.partner_requests
    for each row execute function public.notify_new_request();

alter publication supabase_realtime add table public.client_order_requests, public.partner_requests;
