-- =====================================================================
-- POS247 · ฐานข้อมูลบน Supabase
-- วิธีใช้: Supabase → SQL Editor → New query → วางไฟล์นี้ทั้งหมด → Run
-- รันซ้ำได้ ข้อมูลเดิมไม่หาย
-- =====================================================================

create extension if not exists pg_net;

-- ---------- ตาราง ----------
create table if not exists products (
  id text primary key,
  name text not null,
  category text default '',
  price numeric default 0,
  cost numeric default 0,
  stock numeric default 0,
  low numeric default 0,
  image text default '',
  active boolean default true,
  sort int default 0,
  updated_at timestamptz default now()
);

create table if not exists staff (
  id text primary key,
  name text not null,
  role text default 'CASHIER',
  pin_hash text not null,
  active boolean default true,
  updated_at timestamptz default now()
);

create table if not exists settings (
  id int primary key default 1,
  data jsonb default '{}'::jsonb,
  updated_at timestamptz default now(),
  constraint settings_one_row check (id = 1)
);
insert into settings (id) values (1) on conflict do nothing;

create table if not exists shifts (
  id text primary key,
  opened_at timestamptz not null default now(),
  opened_by text,
  opening_cash numeric default 0,
  closed_at timestamptz,
  closed_by text,
  expected numeric,
  actual numeric,
  diff numeric,
  note text,
  summary jsonb
);
-- เปิดกะได้ทีละกะเดียว (ลิ้นชักเดียว)
create unique index if not exists shifts_one_open on shifts ((closed_at is null)) where closed_at is null;

create table if not exists sales (
  bill_no text primary key,
  ts timestamptz not null,
  day date not null,
  staff text,
  staff_id text,
  shift_id text,
  device text,
  items jsonb not null,
  subtotal numeric default 0,
  discount numeric default 0,
  net numeric default 0,
  payment text,
  paid numeric default 0,
  change numeric default 0,
  note text,
  status text default 'ok',
  void_reason text,
  void_by text,
  void_at timestamptz,
  created_at timestamptz default now()
);
create index if not exists sales_day_idx on sales (day);

-- Token Telegram เก็บที่นี่ หน้าเว็บอ่านไม่ได้
create table if not exists secrets (
  id int primary key default 1,
  tg_token text,
  tg_chat text,
  tg_on boolean default false,
  constraint secrets_one_row check (id = 1)
);
insert into secrets (id) values (1) on conflict do nothing;

-- ---------- สิทธิ์: ต้องล็อกอินบัญชีร้านก่อนจึงอ่าน/เขียนได้ ----------
do $$
declare t text;
begin
  foreach t in array array['products','staff','settings','shifts','sales'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists shop_all on %I', t);
    execute format('create policy shop_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;
alter table secrets enable row level security;  -- ไม่มี policy = ไม่มีใครอ่านตรงได้

-- ---------- เรียลไทม์ ----------
do $$
declare t text;
begin
  foreach t in array array['products','staff','settings','shifts','sales'] loop
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ---------- ขาย: บันทึกบิล + ตัดสต๊อก ในครั้งเดียว (ส่งซ้ำได้ ไม่ตัดซ้ำ) ----------
create or replace function create_sale(s jsonb) returns jsonb
language plpgsql as $$
declare it jsonb;
begin
  insert into sales (bill_no, ts, day, staff, staff_id, shift_id, device, items, subtotal, discount, net, payment, paid, change, note, status)
  values (
    s->>'billNo', to_timestamp((s->>'ts')::numeric / 1000), (s->>'day')::date,
    s->>'staff', s->>'staffId', s->>'shiftId', s->>'device', s->'items',
    (s->>'subtotal')::numeric, (s->>'discount')::numeric, (s->>'net')::numeric,
    s->>'payment', (s->>'paid')::numeric, (s->>'change')::numeric, s->>'note', 'ok')
  on conflict (bill_no) do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;
  for it in select value from jsonb_array_elements(s->'items') loop
    update products set stock = stock - (it->>'qty')::numeric, updated_at = now() where id = it->>'id';
  end loop;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- ยกเลิกบิล + คืนสต๊อก ----------
create or replace function void_sale(p_bill text, p_reason text, p_by text) returns jsonb
language plpgsql as $$
declare s sales; it jsonb;
begin
  update sales set status = 'void', void_reason = p_reason, void_by = p_by, void_at = now()
    where bill_no = p_bill and status <> 'void'
    returning * into s;
  if s.bill_no is null then
    return jsonb_build_object('ok', false, 'error', 'ไม่พบบิล หรือยกเลิกไปแล้ว');
  end if;
  for it in select value from jsonb_array_elements(s.items) loop
    update products set stock = stock + (it->>'qty')::numeric, updated_at = now() where id = it->>'id';
  end loop;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Telegram (ส่งจากฐานข้อมูล Token ไม่หลุดไปหน้าเว็บ) ----------
create or replace function tg_status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('on', tg_on, 'chat', tg_chat, 'hasToken', coalesce(tg_token, '') <> '')
  from secrets where id = 1 and auth.role() = 'authenticated';
$$;

create or replace function set_telegram(p_on boolean, p_chat text, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'not allowed'; end if;
  update secrets set
    tg_on = p_on,
    tg_chat = coalesce(nullif(p_chat, ''), tg_chat),
    tg_token = case when coalesce(p_token, '') = '' then tg_token else p_token end
  where id = 1;
  return tg_status();
end $$;

create or replace function notify(msg text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s secrets; rid bigint;
begin
  if auth.role() <> 'authenticated' then raise exception 'not allowed'; end if;
  select * into s from secrets where id = 1;
  if not coalesce(s.tg_on, false) or coalesce(s.tg_token, '') = '' or coalesce(s.tg_chat, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'off');
  end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || s.tg_token || '/sendMessage',
    body := jsonb_build_object('chat_id', s.tg_chat, 'text', msg, 'parse_mode', 'HTML', 'disable_web_page_preview', true)
  ) into rid;
  return jsonb_build_object('ok', true, 'request_id', rid);
end $$;

create or replace function tg_check(rid bigint) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('status', status_code, 'body', left(content, 300), 'error', error_msg)
       from net._http_response where id = rid and auth.role() = 'authenticated'),
    '{}'::jsonb);
$$;

revoke execute on function create_sale(jsonb), void_sale(text, text, text), tg_status(), set_telegram(boolean, text, text), notify(text), tg_check(bigint) from public, anon;
grant execute on function create_sale(jsonb), void_sale(text, text, text), tg_status(), set_telegram(boolean, text, text), notify(text), tg_check(bigint) to authenticated;
