-- Condizioni di spedizione per il carrello del cliente: tariffa, cartone e sconto del cliente collegato
create or replace function public.client_shipping_terms()
returns jsonb language sql stable security definer set search_path = '' as $$
    select jsonb_build_object(
        'primo', coalesce((s.value->>'primo')::numeric, 15),
        'extra', coalesce((s.value->>'extra')::numeric, 5),
        'soglia', coalesce((s.value->>'soglia')::numeric, 300),
        'perCartone', greatest(1, coalesce((b.value->>'perCartone')::int, 8)),
        'scontoPct', case when c.data->>'tipo' = 'Rivenditore' then 25 else 0 end
    )
    from public.client_access a
    left join public.admin_clients c on c.code = a.client_code
    left join public.admin_settings s on s.key = 'spedizione'
    left join public.admin_settings b on b.key = 'scatole'
    where a.user_id = (select auth.uid())
    limit 1
$$;
revoke all on function public.client_shipping_terms() from public, anon;
grant execute on function public.client_shipping_terms() to authenticated;
