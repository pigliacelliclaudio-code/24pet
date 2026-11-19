-- Tariffa di spedizione iniziale: 15 € il primo cartone, 5 € ogni cartone in più, inclusa da 300 € di listino
insert into public.admin_settings (key, value) values ('spedizione', '{"primo":15,"extra":5,"soglia":300}'::jsonb)
on conflict (key) do update set value = excluded.value;
