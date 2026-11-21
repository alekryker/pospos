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

-- =====================================================================
-- บัญชีพนักงาน: เข้าด้วย "ยูส + PIN 6 หลัก" ได้เลย (ไม่ต้องใช้อีเมลร้าน)
-- ภายในสร้างเป็นผู้ใช้ Supabase อีเมล <ยูส>@slay-pos.local รหัสผ่าน = PIN
-- =====================================================================
alter table pos.staff add column if not exists username text;
alter table pos.staff add column if not exists user_id uuid references auth.users (id) on delete set null;
create unique index if not exists pos_staff_username on pos.staff (lower(username)) where username is not null;
alter table pos.members add column if not exists is_admin boolean default false;
-- ตั้งเจ้าของร้านเป็นแอดมิน (แก้อีเมลก่อนรัน):
-- update pos.members set is_admin = true where user_id in (select id from auth.users where lower(email) = 'อีเมลเจ้าของร้าน');

create or replace function pos.is_admin() returns boolean
language sql stable security definer set search_path = pos as $$
  select exists (select 1 from pos.members where user_id = auth.uid() and is_admin)
      or exists (select 1 from pos.staff where user_id = auth.uid() and role = 'ADMIN' and active);
$$;

create or replace function pos._create_login(p_username text, p_name text, p_role text, p_pin text) returns jsonb
language plpgsql security definer set search_path = pos, extensions as $$
declare
  uid uuid := gen_random_uuid();
  em text := lower(p_username) || '@slay-pos.local';
  sid text := 'u' || substr(replace(uid::text, '-', ''), 1, 12);
begin
  if p_username !~ '^[a-zA-Z0-9._-]{3,30}$' then raise exception 'ยูสใช้ได้เฉพาะ a-z 0-9 . _ - ความยาว 3-30 ตัว'; end if;
  if p_pin !~ '^[0-9]{6}$' then raise exception 'PIN ต้องเป็นตัวเลข 6 หลัก'; end if;
  if exists (select 1 from auth.users where email = em) or exists (select 1 from pos.staff where lower(username) = lower(p_username)) then
    raise exception 'ยูส % มีอยู่แล้ว', p_username;
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
    extensions.crypt(p_pin, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', '{"pos_staff":true}', now(), now(),
    '', '', '', '', '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true), 'email', now(), now(), now());
  insert into pos.members (user_id) values (uid);
  insert into pos.staff (id, name, role, pin_hash, active, username, user_id)
  values (sid, p_name, coalesce(nullif(p_role, ''), 'CASHIER'), '', true, lower(p_username), uid);
  return jsonb_build_object('ok', true, 'id', sid);
end $$;

create or replace function pos.create_staff_login(p_username text, p_name text, p_role text, p_pin text) returns jsonb
language plpgsql security definer set search_path = pos as $$
begin
  if not pos.is_admin() then raise exception 'เฉพาะแอดมินเท่านั้น'; end if;
  return pos._create_login(p_username, p_name, p_role, p_pin);
end $$;

create or replace function pos.set_staff_pin(p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = pos, extensions as $$
begin
  if not pos.is_admin() then raise exception 'เฉพาะแอดมินเท่านั้น'; end if;
  if p_pin !~ '^[0-9]{6}$' then raise exception 'PIN ต้องเป็นตัวเลข 6 หลัก'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_pin, extensions.gen_salt('bf')), updated_at = now()
   where id = (select user_id from pos.staff where id = p_staff);
  return jsonb_build_object('ok', true);
end $$;

create or replace function pos.set_staff_active(p_staff text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = pos as $$
begin
  if not pos.is_admin() then raise exception 'เฉพาะแอดมินเท่านั้น'; end if;
  update pos.staff set active = p_active, updated_at = now() where id = p_staff;
  update auth.users set banned_until = case when p_active then null else now() + interval '100 years' end
   where id = (select user_id from pos.staff where id = p_staff);
  return jsonb_build_object('ok', true);
end $$;

revoke execute on all functions in schema pos from public, anon;
grant execute on all functions in schema pos to authenticated;
revoke execute on function pos._create_login(text, text, text, text) from authenticated;

-- สร้างพนักงานจาก SQL Editor (ตั้ง PIN เองก่อนรัน อย่าใส่ PIN จริงไว้ในไฟล์นี้):
-- select pos._create_login('ยูส', 'ชื่อ', 'CASHIER', 'PIN 6 หลัก');
-- ===== Telegram 2 กลุ่ม: แอดมิน + พนักงาน (ใช้บอทตัวเดียวกัน) =====
alter table pos.secrets add column if not exists tg_staff_chat text;
alter table pos.secrets add column if not exists tg_staff_on boolean default false;

create or replace function pos.tg_status() returns jsonb
language sql security definer set search_path = pos as $$
  select jsonb_build_object('on', tg_on, 'chat', tg_chat, 'hasToken', coalesce(tg_token, '') <> '',
                            'staffOn', coalesce(tg_staff_on, false), 'staffChat', tg_staff_chat)
  from pos.secrets where id = 1 and pos.is_member();
$$;

drop function if exists pos.set_telegram(boolean, text, text);
create or replace function pos.set_telegram(p_on boolean, p_chat text, p_token text default null,
                                            p_staff_on boolean default null, p_staff_chat text default null) returns jsonb
language plpgsql security definer set search_path = pos as $$
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  update pos.secrets set
    tg_on = p_on,
    tg_chat = coalesce(nullif(p_chat, ''), tg_chat),
    tg_token = case when coalesce(p_token, '') = '' then tg_token else p_token end,
    tg_staff_on = coalesce(p_staff_on, tg_staff_on),
    tg_staff_chat = case when p_staff_chat is null then tg_staff_chat else nullif(p_staff_chat, '') end
  where id = 1;
  return pos.tg_status();
end $$;

drop function if exists pos.notify(text);
create or replace function pos.notify(msg text, ch text default 'admin') returns jsonb
language plpgsql security definer set search_path = pos, extensions as $$
declare s pos.secrets; rid bigint; target text; enabled boolean;
begin
  if not pos.is_member() then raise exception 'not allowed'; end if;
  select * into s from pos.secrets where id = 1;
  if ch = 'staff' then target := s.tg_staff_chat; enabled := coalesce(s.tg_staff_on, false);
  else target := s.tg_chat; enabled := coalesce(s.tg_on, false); end if;
  if not enabled or coalesce(s.tg_token, '') = '' or coalesce(target, '') = '' then
    return jsonb_build_object('ok', false, 'reason', 'off');
  end if;
  select net.http_post(
    url := 'https://api.telegram.org/bot' || s.tg_token || '/sendMessage',
    body := jsonb_build_object('chat_id', target, 'text', msg, 'parse_mode', 'HTML', 'disable_web_page_preview', true)
  ) into rid;
  return jsonb_build_object('ok', true, 'request_id', rid);
end $$;

revoke execute on all functions in schema pos from public, anon;
grant execute on all functions in schema pos to authenticated;
revoke execute on function pos._create_login(text, text, text, text) from authenticated;
