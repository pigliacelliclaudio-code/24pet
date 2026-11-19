-- Consegna prevista visibile al cliente
alter table public.client_order_history add column if not exists expected_delivery date;

create or replace function public.sync_client_order_history_row(order_row admin_orders)
returns void language plpgsql security definer set search_path = '' as $$
declare
    d jsonb := order_row.data;
    code text := nullif(d->>'codiceCliente', '');
    order_day date;
begin
    begin
        order_day := (d->>'data')::date;
    exception when others then
        order_day := null;
    end;
    if code is null or order_day is null or jsonb_typeof(d->'articoli') is distinct from 'array'
       or not exists (select 1 from public.client_access a where a.client_code = code) then
        delete from public.client_order_history where order_id = order_row.id;
        return;
    end if;
    insert into public.client_order_history as h (order_id, client_code, order_date, amount, paid, fulfilled, items,
        reseller_discount_pct, extra_discount_pct, shipping_charged, payments, shipments, in_production, expected_delivery)
    values (
        order_row.id, code, order_day,
        coalesce((d->>'importo')::numeric, 0),
        coalesce((d->>'pagato')::boolean, false),
        coalesce((d->>'evaso')::boolean, false),
        (select coalesce(jsonb_agg(jsonb_build_object('colore', a->'colore', 'modello', a->'modello', 'quantita', a->'quantita',
            'dimensione', a->'dimensione', 'prezzoUnitario', a->'prezzoUnitario') order by ord), '[]'::jsonb)
         from jsonb_array_elements(d->'articoli') with ordinality t(a, ord)),
        case when d->>'tipo' = 'Rivenditore' then 25 else 0 end,
        least(greatest(coalesce((d->>'scontoExtraPerc')::numeric, 0), 0), 100),
        case when d->>'spedizioneACarico' = 'Cliente' then greatest(coalesce((d->>'costoSpedizione')::numeric, 0), 0) else 0 end,
        -- Solo i campi utili al cliente: tipo, importo, scadenza, pagata e data di pagamento
        (select coalesce(jsonb_agg(jsonb_build_object('tipo', left(p->>'tipo', 30), 'importo', (p->>'importo')::numeric,
            'scadenza', nullif(p->>'scadenza', ''), 'pagato', coalesce((p->>'pagato')::boolean, false),
            'data_pagamento', nullif(p->>'dataPagamento', '')) order by ord), '[]'::jsonb)
         from jsonb_array_elements(case when jsonb_typeof(d->'pagamenti') = 'array' then d->'pagamenti' else '[]'::jsonb end) with ordinality t(p, ord)),
        -- Spedizioni senza la nota interna: data, tracciamento e urne spedite
        (select coalesce(jsonb_agg(jsonb_build_object('data', nullif(s->>'data', ''), 'tracking', left(coalesce(s->>'tracking', ''), 120),
            'items', (select coalesce(jsonb_agg(jsonb_build_object('modello', i->'modello', 'dimensione', i->'dimensione', 'colore', i->'colore',
                'quantita', i->'quantita')), '[]'::jsonb) from jsonb_array_elements(case when jsonb_typeof(s->'articoli') = 'array' then s->'articoli' else '[]'::jsonb end) i)) order by ord), '[]'::jsonb)
         from jsonb_array_elements(case when jsonb_typeof(d->'spedizioni') = 'array' then d->'spedizioni' else '[]'::jsonb end) with ordinality t(s, ord)),
        -- In produzione: almeno un'urna segnata come stampata (senza dire quante)
        (select coalesce(bool_or(case when e.v ~ '^[0-9]+(\.[0-9]+)?$' then e.v::numeric > 0 else false end), false)
         from jsonb_each_text(case when jsonb_typeof(d->'stampate') = 'object' then d->'stampate' else '{}'::jsonb end) e(k, v)),
        -- Consegna prevista calcolata dalla dashboard (data AAAA-MM-GG)
        case when coalesce(d->>'consegnaPrevista', '') ~ '^\d{4}-\d{2}-\d{2}$' then (d->>'consegnaPrevista')::date else null end
    )
    on conflict (order_id) do update set
        client_code = excluded.client_code, order_date = excluded.order_date, amount = excluded.amount,
        paid = excluded.paid, fulfilled = excluded.fulfilled, items = excluded.items,
        reseller_discount_pct = excluded.reseller_discount_pct, extra_discount_pct = excluded.extra_discount_pct,
        shipping_charged = excluded.shipping_charged, payments = excluded.payments, shipments = excluded.shipments,
        in_production = excluded.in_production, expected_delivery = excluded.expected_delivery;
exception when others then
    -- Un ordine con dati incompleti non deve impedire il salvataggio nel gestionale
    delete from public.client_order_history where order_id = order_row.id;
end $$;

-- Allinea gli ordini già presenti
select public.sync_client_order_history_row(o) from public.admin_orders o;
