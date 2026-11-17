create policy "Order requests require a saved billing profile"
    on public.client_order_requests
    as restrictive
    for insert to authenticated
    with check (billing_details is not null);
