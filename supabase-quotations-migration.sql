
begin;

do $$
begin
  if to_regprocedure('public.save_bill(uuid,text,jsonb,jsonb)') is null then
    raise exception 'Required POS RPC public.save_bill(uuid, text, jsonb, jsonb) is missing; restore that function before applying this migration';
  end if;
  if to_regprocedure('public.record_bill_payment(uuid,numeric,text,text,text)') is null then
    raise exception 'Required POS RPC public.record_bill_payment(uuid, numeric, text, text, text) is missing; restore that function before applying this migration';
  end if;
end;
$$;

create sequence if not exists public.quotation_number_seq;

create table if not exists public.quotations (
  id uuid primary key,
  quotation_number text not null unique,
  quotation_data jsonb not null default '{}'::jsonb,
  status text not null default 'Pending' check (status in ('Pending', 'Approved')),
  bill_id uuid references public.bills(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.quotations enable row level security;

drop policy if exists "POS anonymous access" on public.quotations;
create policy "POS anonymous access" on public.quotations
  for all to anon, authenticated using (true) with check (true);

grant select, insert, update, delete on public.quotations to anon, authenticated;
grant usage, select on sequence public.quotation_number_seq to anon, authenticated;
grant usage on schema public to anon, authenticated;

create or replace function public.save_quotation(
  p_id uuid,
  p_quotation_data jsonb
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_existing public.quotations%rowtype;
  v_number text;
  v_counter bigint;
begin
  if p_id is null or jsonb_typeof(p_quotation_data) is distinct from 'object' then
    raise exception 'Invalid quotation data';
  end if;
  if jsonb_typeof(p_quotation_data->'items') is distinct from 'array' then
    raise exception 'A quotation must include at least one item';
  end if;
  if jsonb_array_length(p_quotation_data->'items') = 0 then
    raise exception 'Invalid quotation data';
  end if;

  select * into v_existing
  from public.quotations
  where id = p_id
  for update;

  if found then
    if v_existing.status <> 'Pending' then
      raise exception 'Only pending quotations can be edited';
    end if;
    v_number := v_existing.quotation_number;
    update public.quotations
    set quotation_data = jsonb_set(
          jsonb_set(p_quotation_data, '{quotationNumber}', to_jsonb(v_number), true),
          '{status}', to_jsonb('Pending'::text), true
        ),
        updated_at = now()
    where id = p_id;
  else
    v_counter := nextval('public.quotation_number_seq');
    v_number := 'QT-EST-' || repeat('0', greatest(0, 4 - length(v_counter::text))) || v_counter::text;
    insert into public.quotations (id, quotation_number, quotation_data)
    values (
      p_id,
      v_number,
      jsonb_set(
        jsonb_set(p_quotation_data, '{quotationNumber}', to_jsonb(v_number), true),
        '{status}', to_jsonb('Pending'::text), true
      )
    );
  end if;

  return v_number;
end;
$$;

create or replace function public.approve_quotation(
  p_quotation_id uuid,
  p_bill_id uuid,
  p_bill_number text
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_quotation public.quotations%rowtype;
  v_bill_data jsonb;
  v_total numeric;
begin
  select * into v_quotation
  from public.quotations
  where id = p_quotation_id
  for update;

  if not found then
    raise exception 'Quotation not found';
  end if;
  if v_quotation.status = 'Approved' then
    if v_quotation.bill_id is null then
      raise exception 'Approved quotation has no linked bill';
    end if;
    return v_quotation.bill_id;
  end if;
  if p_bill_id is null or nullif(trim(p_bill_number), '') is null then
    raise exception 'Invalid bill details';
  end if;

  v_total := coalesce((v_quotation.quotation_data->>'total')::numeric, 0);
  v_bill_data := v_quotation.quotation_data || jsonb_build_object(
    'id', p_bill_id,
    'number', trim(p_bill_number),
    'quotationNumber', v_quotation.quotation_number,
    'date', to_char(current_date, 'YYYY-MM-DD'),
    'paymentDate', to_char(current_date, 'YYYY-MM-DD'),
    'amountPaid', 0,
    'balanceDue', greatest(0, v_total),
    'payments', '[]'::jsonb,
    'status', 'Approved'
  );

  perform public.save_bill(
    p_bill_id,
    trim(p_bill_number),
    v_bill_data,
    coalesce(v_bill_data->'items', '[]'::jsonb)
  );

  update public.quotations
  set status = 'Approved',
      bill_id = p_bill_id,
      quotation_data = jsonb_set(quotation_data, '{status}', to_jsonb('Approved'::text), true),
      updated_at = now()
  where id = p_quotation_id;

  return p_bill_id;
end;
$$;

create or replace function public.save_bill_with_payment_adjustment(
  p_id uuid,
  p_bill_number text,
  p_bill_data jsonb,
  p_items jsonb,
  p_additional_payment numeric,
  p_payment_date text,
  p_payment_notes text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_total numeric;
  v_paid numeric;
begin
  v_total := coalesce((p_bill_data->>'total')::numeric, 0);
  v_paid := coalesce((p_bill_data->>'amountPaid')::numeric, 0);
  if coalesce(p_additional_payment, 0) < 0 then
    raise exception 'Paid amount cannot be reduced while editing a bill';
  end if;
  if v_paid + coalesce(p_additional_payment, 0) > v_total then
    raise exception 'Paid amount cannot exceed the updated bill total';
  end if;

  perform public.save_bill(p_id, p_bill_number, p_bill_data, p_items);

  if coalesce(p_additional_payment, 0) > 0 then
    perform public.record_bill_payment(
      p_id,
      p_additional_payment,
      p_payment_date,
      p_payment_notes,
      ''
    );
  end if;
end;
$$;

revoke all on function public.save_quotation(uuid, jsonb) from public;
revoke all on function public.approve_quotation(uuid, uuid, text) from public;
revoke all on function public.save_bill_with_payment_adjustment(uuid, text, jsonb, jsonb, numeric, text, text) from public;
grant execute on function public.save_quotation(uuid, jsonb) to anon, authenticated;
grant execute on function public.approve_quotation(uuid, uuid, text) to anon, authenticated;
grant execute on function public.save_bill_with_payment_adjustment(uuid, text, jsonb, jsonb, numeric, text, text) to anon, authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'quotations'
     ) then
    execute 'alter publication supabase_realtime add table public.quotations';
  end if;
end;
$$;

commit;

-- PostgREST (Supabase RPC) caches function signatures; reload after commit.
notify pgrst, 'reload schema';
