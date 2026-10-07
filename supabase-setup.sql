-- Qadeer Traders POS: destructive full database setup.
-- WARNING: Running this script drops and recreates all four POS tables,
-- permanently deleting every existing bill, inventory item, payment, and expense.
--
-- This app uses the Supabase anon/publishable key without Supabase Auth.
-- The policies below therefore allow unrestricted anonymous access. RLS is
-- enabled, but this is not private or secure: anyone with the app/key can read,
-- insert, update, and delete all POS data. Use authenticated policies before
-- storing sensitive business information.

begin;

drop function if exists public.save_bill(uuid, text, jsonb, jsonb);
drop function if exists public.receive_inventory(uuid, text, text, numeric, numeric, numeric);
drop function if exists public.record_bill_payment(uuid, numeric, text, text, text);
drop function if exists public.delete_bill(uuid);

drop table if exists public.ledger;
drop table if exists public.expenses;
drop table if exists public.inventory;
drop table if exists public.bills;

create table public.bills (
  id uuid primary key,
  bill_number text not null unique,
  bill_data jsonb not null default '{}'::jsonb,
  customer jsonb not null default '{}'::jsonb,
  items jsonb not null default '[]'::jsonb,
  amount numeric not null default 0,
  paid_amount numeric not null default 0,
  balance numeric not null default 0,
  balance_due numeric not null default 0,
  subtotal numeric not null default 0,a
  freight numeric not null default 0,
  other numeric not null default 0,
  profit numeric not null default 0,
  date date not null default current_date,
  payment_date date,
  notes text not null default '',
  description text not null default '',
  type text not null default 'bill',
  reference text,
  created_at timestamptz not null default now()
);

create table public.inventory (
  id uuid primary key,
  product_name text not null,
  description text not null default '',
  stock numeric not null default 0 check (stock >= 0),
  purchase_rate numeric not null default 0 check (purchase_rate >= 0),
  price numeric not null default 0 check (price >= 0),
  type text not null default 'product',
  reference text,
  updated_at timestamptz not null default now()
);

create unique index inventory_product_name_lower_key
  on public.inventory (lower(product_name));

create table public.ledger (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  payment_number integer not null,
  amount numeric not null check (amount > 0),
  paid_amount numeric not null check (paid_amount > 0),
  date date not null default current_date,
  payment_date date not null default current_date,
  notes text not null default '',
  description text not null default '',
  type text not null default 'payment',
  reference text,
  customer jsonb not null default '{}'::jsonb,
  balance numeric not null default 0,
  ledger_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (bill_id, payment_number)
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  amount numeric not null check (amount > 0),
  date date not null default current_date,
  expense_date date not null default current_date,
  notes text not null default '',
  description text not null default '',
  type text not null default 'expense',
  reference text,
  title text not null,
  category text not null,
  expense_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.bills enable row level security;
alter table public.inventory enable row level security;
alter table public.ledger enable row level security;
alter table public.expenses enable row level security;

create policy "POS anonymous access" on public.bills
  for all to anon, authenticated using (true) with check (true);
create policy "POS anonymous access" on public.inventory
  for all to anon, authenticated using (true) with check (true);
create policy "POS anonymous access" on public.ledger
  for all to anon, authenticated using (true) with check (true);
create policy "POS anonymous access" on public.expenses
  for all to anon, authenticated using (true) with check (true);

grant select, insert, update, delete on public.bills, public.inventory, public.ledger, public.expenses
  to anon, authenticated;

create or replace function public.save_bill(
  p_id uuid,
  p_bill_number text,
  p_bill_data jsonb,
  p_items jsonb
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_old_data jsonb;
  v_product record;
  v_old_quantity numeric;
  v_new_quantity numeric;
  v_total numeric;
  v_paid numeric;
  v_bill_date date;
  v_payment_date date;
begin
  if p_id is null or nullif(trim(p_bill_number), '') is null
     or jsonb_typeof(p_bill_data) <> 'object'
     or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Invalid bill data';
  end if;

  select bill_data into v_old_data
  from public.bills
  where id = p_id
  for update;

  for v_product in
    select id, product_name, stock
    from public.inventory
    where lower(product_name) in (
      select lower(old_item.value->>'name')
      from jsonb_array_elements(coalesce(v_old_data->'items', '[]'::jsonb)) as old_item(value)
      union
      select lower(new_item.value->>'name')
      from jsonb_array_elements(p_items) as new_item(value)
    )
    order by id
    for update
  loop
    select coalesce(sum((old_item.value->>'quantity')::numeric), 0)
      into v_old_quantity
    from jsonb_array_elements(coalesce(v_old_data->'items', '[]'::jsonb)) as old_item(value)
    where lower(old_item.value->>'name') = lower(v_product.product_name);

    select coalesce(sum((new_item.value->>'quantity')::numeric), 0)
      into v_new_quantity
    from jsonb_array_elements(p_items) as new_item(value)
    where lower(new_item.value->>'name') = lower(v_product.product_name);

    if v_product.stock + v_old_quantity - v_new_quantity < 0 then
      raise exception 'Insufficient stock for %', v_product.product_name;
    end if;

    update public.inventory
    set stock = stock + v_old_quantity - v_new_quantity,
        updated_at = now()
    where id = v_product.id;
  end loop;

  v_total := coalesce((p_bill_data->>'total')::numeric, 0);
  v_paid := coalesce((p_bill_data->>'amountPaid')::numeric, 0);
  v_bill_date := case
    when coalesce(p_bill_data->>'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
      then (p_bill_data->>'date')::date
    else current_date
  end;
  v_payment_date := case
    when coalesce(p_bill_data->>'paymentDate', '') ~ '^\d{4}-\d{2}-\d{2}$'
      then (p_bill_data->>'paymentDate')::date
    else null
  end;

  insert into public.bills (
    id, bill_number, bill_data, customer, items, amount, paid_amount,
    balance, balance_due, subtotal, freight, other, profit, date,
    payment_date, notes, description, type, reference, created_at
  ) values (
    p_id,
    trim(p_bill_number),
    jsonb_set(p_bill_data, '{payments}', '[]'::jsonb, true),
    coalesce(p_bill_data->'customer', '{}'::jsonb),
    p_items,
    v_total,
    v_paid,
    greatest(0, v_total - v_paid),
    greatest(0, v_total - v_paid),
    coalesce((p_bill_data->>'subtotal')::numeric, 0),
    coalesce((p_bill_data->>'freight')::numeric, 0),
    coalesce((p_bill_data->>'other')::numeric, 0),
    coalesce((p_bill_data->>'profit')::numeric, 0),
    v_bill_date,
    v_payment_date,
    coalesce(p_bill_data->>'paymentNotes', ''),
    coalesce(p_bill_data->>'description', ''),
    'bill',
    p_bill_data->>'reference',
    coalesce((p_bill_data->>'createdAt')::timestamptz, now())
  )
  on conflict (id) do update
    set bill_number = excluded.bill_number,
        bill_data = excluded.bill_data,
        customer = excluded.customer,
        items = excluded.items,
        amount = excluded.amount,
        paid_amount = excluded.paid_amount,
        balance = excluded.balance,
        balance_due = excluded.balance_due,
        subtotal = excluded.subtotal,
        freight = excluded.freight,
        other = excluded.other,
        profit = excluded.profit,
        date = excluded.date,
        payment_date = excluded.payment_date,
        notes = excluded.notes,
        description = excluded.description,
        type = excluded.type,
        reference = excluded.reference;

  if v_old_data is null and v_paid > 0 then
    insert into public.ledger (
      bill_id, payment_number, amount, paid_amount, date, payment_date,
      notes, customer, balance, ledger_data
    )
    values (
      p_id,
      1,
      v_paid,
      v_paid,
      coalesce(v_payment_date, v_bill_date),
      coalesce(v_payment_date, v_bill_date),
      coalesce(p_bill_data->>'paymentNotes', ''),
      coalesce(p_bill_data->'customer', '{}'::jsonb),
      greatest(0, v_total - v_paid),
      jsonb_build_object(
        'amount', v_paid,
        'date', coalesce(v_payment_date, v_bill_date),
        'notes', coalesce(p_bill_data->>'paymentNotes', '')
      )
    )
    on conflict (bill_id, payment_number) do nothing;
  end if;
end;
$$;

create or replace function public.receive_inventory(
  p_id uuid,
  p_product_name text,
  p_description text,
  p_purchase_rate numeric,
  p_price numeric,
  p_quantity numeric
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_product public.inventory%rowtype;
  v_new_stock numeric;
begin
  if nullif(trim(p_product_name), '') is null or p_quantity <= 0
     or p_purchase_rate < 0 or p_price < 0 then
    raise exception 'Invalid inventory values';
  end if;

  select * into v_product
  from public.inventory
  where lower(product_name) = lower(trim(p_product_name))
  for update;

  if found then
    v_new_stock := v_product.stock + p_quantity;
    update public.inventory
    set stock = v_new_stock,
        purchase_rate = (v_product.stock * v_product.purchase_rate + p_quantity * p_purchase_rate) / v_new_stock,
        price = p_price,
        description = case when trim(p_description) = '' then v_product.description else trim(p_description) end,
        updated_at = now()
    where id = v_product.id;
  else
    insert into public.inventory (id, product_name, description, stock, purchase_rate, price)
    values (p_id, trim(p_product_name), trim(p_description), p_quantity, p_purchase_rate, p_price);
  end if;
end;
$$;

create or replace function public.record_bill_payment(
  p_bill_id uuid,
  p_amount numeric,
  p_date text,
  p_notes text,
  p_formatted_note text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_bill public.bills%rowtype;
  v_data jsonb;
  v_paid numeric;
  v_due numeric;
  v_payment_number integer;
begin
  select * into v_bill
  from public.bills
  where id = p_bill_id
  for update;

  if not found then
    raise exception 'Bill not found';
  end if;

  v_data := v_bill.bill_data;
  v_paid := coalesce(v_bill.paid_amount, 0);
  v_due := greatest(0, v_bill.amount - v_paid);
  if p_amount <= 0 or p_amount > v_due then
    raise exception 'Payment must be positive and no greater than the remaining balance';
  end if;
  if coalesce(p_date, '') !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'Invalid payment date';
  end if;

  v_paid := v_paid + p_amount;
  v_due := greatest(0, v_bill.amount - v_paid);
  v_data := jsonb_set(v_data, '{amountPaid}', to_jsonb(v_paid), true);
  v_data := jsonb_set(v_data, '{balanceDue}', to_jsonb(v_due), true);
  v_data := jsonb_set(v_data, '{paymentDate}', to_jsonb(p_date), true);
  v_data := jsonb_set(
    v_data,
    '{paymentNotes}',
    to_jsonb(concat_ws(' | ', nullif(v_data->>'paymentNotes', ''), nullif(p_formatted_note, ''))),
    true
  );

  select coalesce(max(payment_number), 0) + 1 into v_payment_number
  from public.ledger
  where bill_id = p_bill_id;

  insert into public.ledger (
    bill_id, payment_number, amount, paid_amount, date, payment_date,
    notes, customer, balance, ledger_data
  )
  values (
    p_bill_id,
    v_payment_number,
    p_amount,
    p_amount,
    p_date::date,
    p_date::date,
    coalesce(p_notes, ''),
    v_bill.customer,
    v_due,
    jsonb_build_object('amount', p_amount, 'date', p_date, 'notes', coalesce(p_notes, ''))
  );

  update public.bills
  set bill_data = v_data,
      paid_amount = v_paid,
      balance = v_due,
      balance_due = v_due,
      payment_date = p_date::date,
      notes = coalesce(v_data->>'paymentNotes', '')
  where id = p_bill_id;
end;
$$;

create or replace function public.delete_bill(p_bill_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  delete from public.bills where id = p_bill_id;
$$;

revoke all on function public.save_bill(uuid, text, jsonb, jsonb) from public;
revoke all on function public.receive_inventory(uuid, text, text, numeric, numeric, numeric) from public;
revoke all on function public.record_bill_payment(uuid, numeric, text, text, text) from public;
revoke all on function public.delete_bill(uuid) from public;
grant execute on function public.save_bill(uuid, text, jsonb, jsonb) to anon, authenticated;
grant execute on function public.receive_inventory(uuid, text, text, numeric, numeric, numeric) to anon, authenticated;
grant execute on function public.record_bill_payment(uuid, numeric, text, text, text) to anon, authenticated;
grant execute on function public.delete_bill(uuid) to anon, authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bills') then
      execute 'alter publication supabase_realtime add table public.bills';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory') then
      execute 'alter publication supabase_realtime add table public.inventory';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ledger') then
      execute 'alter publication supabase_realtime add table public.ledger';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'expenses') then
      execute 'alter publication supabase_realtime add table public.expenses';
    end if;
  end if;
end;
$$;

commit;
