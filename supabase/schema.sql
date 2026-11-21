-- =====================================================================
-- POS247 · ฐานข้อมูลบน Supabase
-- ทุกอย่างอยู่ใน schema "pos" แยกจากตารางเดิมของโปรเจกต์ (public ไม่ถูกแตะ)
-- วิธีใช้: SQL Editor → วางไฟล์นี้ทั้งหมด → Run (รันซ้ำได้ ข้อมูลไม่หาย)
-- หลังรัน: Project Settings → Data API → Exposed schemas → เพิ่ม "pos"
-- เพิ่มบัญชีร้านเป็นสมาชิก:  insert into pos.members(user_id) select id from auth.users where email = 'อีเมลร้าน';
-- =====================================================================

create schema if not exists pos;
grant usage on schema pos to anon, authenticated, service_role;
create extension if not exists pg_net;

-- ---------- สมาชิก: เฉพาะบัญชีที่อยู่ในตารางนี้เข้าถึงข้อมูล POS ได้ ----------
create table if not exists pos.members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz default now()
);
create or replace function pos.is_member() returns boolean
language sql stable security definer set search_path = pos as $$
  select exists (select 1 from pos.members where user_id = auth.uid());
$$;

-- ---------- ตาราง ----------
create table if not exists pos.products (
  id text primary key, name text not null, category text default '',
  price numeric default 0, cost numeric default 0, stock numeric default 0, low numeric default 0,
  image text default '', active boolean default true, sort int default 0, updated_at timestamptz default now()
);
create table if not exists pos.staff (
  id text primary key, name text not null, role text default 'CASHIER', pin_hash text not null,
  active boolean default true, updated_at timestamptz default now()
);
create table if not exists pos.settings (
  id int primary key default 1, data jsonb default '{}'::jsonb, updated_at timestamptz default now(),
  constraint pos_settings_one_row check (id = 1)
);
insert into pos.settings (id) values (1) on conflict do nothing;
create table if not exists pos.shifts (
  id text primary key, opened_at timestamptz not null default now(), opened_by text, opening_cash numeric default 0,
  closed_at timestamptz, closed_by text, expected numeric, actual numeric, diff numeric, note text, summary jsonb
);
create unique index if not exists pos_shifts_one_open on pos.shifts ((closed_at is null)) where closed_at is null;
create table if not exists pos.sales (
  bill_no text primary key, ts timestamptz not null, day date not null, staff text, staff_id text, shift_id text, device text,
  items jsonb not null, subtotal numeric default 0, discount numeric default 0, net numeric default 0, payment text,
  paid numeric default 0, change numeric default 0, note text, status text default 'ok',
  void_reason text, void_by text, void_at timestamptz, created_at timestamptz default now()
);
create index if not exists pos_sales_day_idx on pos.sales (day);
create table if not exists pos.secrets (
  id int primary key default 1, tg_token text, tg_chat text, tg_on boolean default false,
  constraint pos_secrets_one_row check (id = 1)
);
insert into pos.secrets (id) values (1) on conflict do nothing;

-- ---------- สิทธิ์ ----------
grant select, insert, update, delete on pos.products, pos.staff, pos.settings, pos.shifts, pos.sales to authenticated;
grant select on pos.members to authenticated;
revoke all on pos.secrets from anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['products','staff','settings','shifts','sales'] loop
    execute format('alter table pos.%I enable row level security', t);
    execute format('drop policy if exists pos_members_all on pos.%I', t);
    execute format('create policy pos_members_all on pos.%I for all to authenticated using (pos.is_member()) with check (pos.is_member())', t);
  end loop;
end $$;
alter table pos.members enable row level security;
drop policy if exists pos_members_self on pos.members;
create policy pos_members_self on pos.members for select to authenticated using (user_id = auth.uid());
alter table pos.secrets enable row level security;

-- ---------- เรียลไทม์ ----------
do $$
declare t text;
begin
  foreach t in array array['products','staff','settings','shifts','sales'] loop
    begin
      execute format('alter publication supabase_realtime add table pos.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- ---------- ขาย: บันทึกบิล + ตัดสต๊อก ในครั้งเดียว (ส่งซ้ำได้ ไม่ตัดซ้ำ) ----------
create or replace function pos.create_sale(s jsonb) returns jsonb
language plpgsql set search_path = pos as $$
declare it jsonb;
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  insert into pos.sales (bill_no, ts, day, staff, staff_id, shift_id, device, items, subtotal, discount, net, payment, paid, change, note, status)
  values (
    s->>'billNo', to_timestamp((s->>'ts')::numeric / 1000), (s->>'day')::date,
    s->>'staff', s->>'staffId', s->>'shiftId', s->>'device', s->'items',
    (s->>'subtotal')::numeric, (s->>'discount')::numeric, (s->>'net')::numeric,
    s->>'payment', (s->>'paid')::numeric, (s->>'change')::numeric, s->>'note', 'ok')
  on conflict (bill_no) do nothing;
  if not found then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  for it in select value from jsonb_array_elements(s->'items') loop
    update pos.products set stock = stock - (it->>'qty')::numeric, updated_at = now() where id = it->>'id';
  end loop;
  return jsonb_build_object('ok', true);
end $$;

create or replace function pos.void_sale(p_bill text, p_reason text, p_by text) returns jsonb
language plpgsql set search_path = pos as $$
declare s pos.sales; it jsonb;
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  update pos.sales set status = 'void', void_reason = p_reason, void_by = p_by, void_at = now()
    where bill_no = p_bill and status <> 'void' returning * into s;
  if s.bill_no is null then return jsonb_build_object('ok', false, 'error', 'ไม่พบบิล หรือยกเลิกไปแล้ว'); end if;
  for it in select value from jsonb_array_elements(s.items) loop
    update pos.products set stock = stock + (it->>'qty')::numeric, updated_at = now() where id = it->>'id';
  end loop;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Telegram: ส่งจากฐานข้อมูล Token ไม่ออกไปหน้าเว็บ ----------
create or replace function pos.tg_status() returns jsonb
language sql security definer set search_path = pos as $$
  select jsonb_build_object('on', tg_on, 'chat', tg_chat, 'hasToken', coalesce(tg_token, '') <> '')
  from pos.secrets where id = 1 and pos.is_member();
$$;

create or replace function pos.set_telegram(p_on boolean, p_chat text, p_token text default null) returns jsonb
language plpgsql security definer set search_path = pos as $$
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  update pos.secrets set
    tg_on = p_on,
    tg_chat = coalesce(nullif(p_chat, ''), tg_chat),
    tg_token = case when coalesce(p_token, '') = '' then tg_token else p_token end
  where id = 1;
  return pos.tg_status();
end $$;

create or replace function pos.notify(msg text) returns jsonb
language plpgsql security definer set search_path = pos, extensions as $$
declare s pos.secrets; rid bigint;
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  select * into s from pos.secrets where id = 1;
  if not coalesce(s.tg_on, false) or coalesce(s.tg_token, '') = '' or coalesce(s.tg_chat, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'off');
  end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || s.tg_token || '/sendMessage',
    body := jsonb_build_object('chat_id', s.tg_chat, 'text', msg, 'parse_mode', 'HTML', 'disable_web_page_preview', true)
  ) into rid;
  return jsonb_build_object('ok', true, 'request_id', rid);
end $$;

create or replace function pos.tg_check(rid bigint) returns jsonb
language sql security definer set search_path = pos as $$
  select coalesce(
    (select jsonb_build_object('status', status_code, 'body', left(content, 300), 'error', error_msg)
       from net._http_response where id = rid and pos.is_member()),
    '{}'::jsonb);
$$;

revoke execute on all functions in schema pos from public, anon;
grant execute on all functions in schema pos to authenticated;
