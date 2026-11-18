-- The Edge Function can take more than 5 s on a cold start: wait up to 20 s (pg_net runs in background).
create or replace function public.notify_new_request()
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
            timeout_milliseconds := 20000
        );
    exception when others then
        null; -- a notification problem must never block the request itself
    end;
    return new;
end;
$$;
revoke all on function public.notify_new_request() from public, anon, authenticated;
