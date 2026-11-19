-- The client card stores the label logo as an image (up to ~200 KB): 50 KB was too small.
alter table public.admin_clients drop constraint admin_clients_data_check;
alter table public.admin_clients add constraint admin_clients_data_check
    check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 300000);
