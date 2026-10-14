-- God's Army Fitness Centre — Supabase setup. Run once in SQL Editor.
-- DATE RULE: end_date = (start_date + N months) - 1 day, using PostgreSQL month arithmetic,
-- which clamps to month end (31 Jan + 1 month = 28/29 Feb). So 31 Jan monthly -> ends 27 Feb (28 Feb in leap year: 28 Feb).
create extension if not exists pgcrypto;

create table owners(user_id uuid primary key references auth.users on delete cascade);
create table gym_settings(
  id int primary key default 1 check(id=1),
  lat double precision, lng double precision,
  radius_m int not null default 100 check(radius_m between 20 and 1000),
  max_accuracy_m int not null default 50 check(max_accuracy_m between 10 and 500),
  addon_price numeric(12,2) not null default 200, updated_at timestamptz default now());
insert into gym_settings(id) values(1);
create table plans(code text primary key, months int not null check(months>0), price numeric(12,2) not null check(price>=0));
-- Quarterly/yearly prices are PLACEHOLDERS (3x / 12x monthly). Edit in Table Editor.
insert into plans values('monthly',1,800),('quarterly',3,2400),('yearly',12,9600);

create sequence member_seq;
create table members(
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique not null references auth.users on delete cascade,
  member_code text unique not null default 'GAF-M'||lpad(nextval('member_seq')::text,4,'0'),
  full_name text not null check(length(full_name) between 2 and 100),
  phone text not null unique check(phone ~ '^\+[0-9]{10,14}$'),
  dob date, status text not null default 'pending' check(status in('pending','active','rejected')),
  notes text, created_at timestamptz not null default now());
create table memberships(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members on delete cascade,
  plan_code text not null references plans,
  start_date date not null, end_date date not null check(end_date>=start_date),
  base_price numeric(12,2) not null, addon_price numeric(12,2) not null default 0,
  final_price numeric(12,2) not null check(final_price>=0), override_reason text,
  created_at timestamptz not null default now());
create index on memberships(member_id,end_date desc);
create index on memberships(end_date);
create table attendance(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members on delete cascade,
  check_in timestamptz not null default now(), check_out timestamptz,
  in_dist_m numeric(8,1), in_acc_m numeric(8,1), out_dist_m numeric(8,1),
  check(check_out is null or check_out>check_in));
create unique index one_open_session on attendance(member_id) where check_out is null;
create index on attendance(member_id,check_in desc);
create table payments(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members on delete cascade,
  membership_id uuid references memberships,
  amount numeric(12,2) not null check(amount>0),
  method text not null check(method in('cash','upi','other')), reference text,
  status text not null default 'pending' check(status in('pending','paid')),
  recorded_by uuid not null references auth.users,
  created_at timestamptz not null default now(), confirmed_at timestamptz);
create index on payments(member_id,created_at desc);
create table audit_logs(id bigserial primary key, actor uuid, action text not null, target uuid, detail jsonb, at timestamptz not null default now());

-- helpers
create function is_owner() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from owners where user_id=auth.uid()) $$;
create function my_member_id() returns uuid language sql stable security definer set search_path=public as $$ select id from members where user_id=auth.uid() $$;
create function gym_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;
create function haversine_m(a double precision,b double precision,c double precision,d double precision) returns double precision language sql immutable as $$
  select 2*6371000*asin(least(1,sqrt(sin(radians(c-a)/2)^2+cos(radians(a))*cos(radians(c))*sin(radians(d-b)/2)^2))) $$;

-- RLS: clients can only READ (own rows / owner all). All writes go through functions below.
alter table owners enable row level security; alter table gym_settings enable row level security;
alter table plans enable row level security; alter table members enable row level security;
alter table memberships enable row level security; alter table attendance enable row level security;
alter table payments enable row level security; alter table audit_logs enable row level security;
create policy owners_self on owners for select to authenticated using(user_id=auth.uid());
create policy settings_owner on gym_settings for all to authenticated using(is_owner()) with check(is_owner());
create policy plans_read on plans for select to authenticated using(true);
create policy plans_owner on plans for all to authenticated using(is_owner()) with check(is_owner());
create policy members_read on members for select to authenticated using(user_id=auth.uid() or is_owner());
create policy members_owner_upd on members for update to authenticated using(is_owner()) with check(is_owner());
create policy ms_read on memberships for select to authenticated using(member_id=my_member_id() or is_owner());
create policy att_read on attendance for select to authenticated using(member_id=my_member_id() or is_owner());
create policy pay_read on payments for select to authenticated using(member_id=my_member_id() or is_owner());
create policy audit_owner on audit_logs for select to authenticated using(is_owner());
revoke all on all tables in schema public from anon;
revoke insert,update,delete on memberships,attendance,payments,audit_logs,owners from authenticated;

-- functions
create function onboard_self(p_name text,p_phone text,p_dob date) returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into members(user_id,full_name,phone,dob) values(auth.uid(),trim(p_name),regexp_replace(p_phone,'\s','','g'),p_dob);
exception when unique_violation then raise exception 'This account or phone number is already registered';
end $$;

create function approve_member(p_member uuid,p_plan text,p_start date,p_addon numeric,p_final numeric,p_reason text) returns uuid
language plpgsql security definer set search_path=public as $$
declare pl plans; fin numeric; e date; mid uuid; auto numeric;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  select * into pl from plans where code=p_plan; if not found then raise exception 'Unknown plan'; end if;
  auto:=pl.price+coalesce(p_addon,0); fin:=coalesce(p_final,auto);
  if fin<>auto and coalesce(trim(p_reason),'')='' then raise exception 'Reason required for a price override'; end if;
  e:=((p_start+make_interval(months=>pl.months))::date)-1;
  if exists(select 1 from memberships where member_id=p_member and start_date<=e and end_date>=p_start) then
    raise exception 'Overlaps an existing membership'; end if;
  insert into memberships(member_id,plan_code,start_date,end_date,base_price,addon_price,final_price,override_reason)
    values(p_member,p_plan,p_start,e,pl.price,coalesce(p_addon,0),fin,nullif(trim(p_reason),'')) returning id into mid;
  update members set status='active' where id=p_member;
  insert into audit_logs(actor,action,target,detail) values(auth.uid(),'approve_member',p_member,jsonb_build_object('plan',p_plan,'start',p_start,'end',e,'price',fin));
  return mid;
end $$;

create function check_in(p_lat double precision,p_lng double precision,p_acc double precision) returns json
language plpgsql security definer set search_path=public as $$
declare m uuid:=my_member_id(); g gym_settings; d double precision;
begin
  if m is null then raise exception 'No member profile'; end if;
  select * into g from gym_settings where id=1;
  if g.lat is null then raise exception 'Gym location is not configured yet. Ask the owner.'; end if;
  if p_acc is null or p_acc>g.max_accuracy_m then raise exception 'Location accuracy too low. Move to open sky and retry.'; end if;
  if not exists(select 1 from memberships where member_id=m and gym_today() between start_date and end_date) then
    raise exception 'No active membership. Please renew.'; end if;
  d:=haversine_m(g.lat,g.lng,p_lat,p_lng);
  if d>g.radius_m then raise exception 'You''re outside the gym. Move closer to the gym to mark attendance.'; end if;
  insert into attendance(member_id,in_dist_m,in_acc_m) values(m,round(d::numeric,1),round(p_acc::numeric,1));
  return json_build_object('ok',true);
exception when unique_violation then raise exception 'You are already checked in';
end $$;

create function check_out(p_lat double precision,p_lng double precision,p_acc double precision) returns json
language plpgsql security definer set search_path=public as $$
declare m uuid:=my_member_id(); g gym_settings; d double precision;
begin
  if m is null then raise exception 'No member profile'; end if;
  select * into g from gym_settings where id=1;
  if g.lat is null then raise exception 'Gym location is not configured yet.'; end if;
  if p_acc is null or p_acc>g.max_accuracy_m then raise exception 'Location accuracy too low. Move to open sky and retry.'; end if;
  d:=haversine_m(g.lat,g.lng,p_lat,p_lng);
  if d>g.radius_m then raise exception 'You''re outside the gym. Move closer to check out.'; end if;
  update attendance set check_out=now(),out_dist_m=round(d::numeric,1) where member_id=m and check_out is null;
  if not found then raise exception 'No open session to check out of'; end if;
  return json_build_object('ok',true);
end $$;

create function record_payment(p_member uuid,p_amount numeric,p_method text,p_ref text,p_confirmed boolean) returns uuid
language plpgsql security definer set search_path=public as $$
declare pid uuid;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  insert into payments(member_id,membership_id,amount,method,reference,status,recorded_by,confirmed_at)
  values(p_member,(select id from memberships where member_id=p_member order by end_date desc limit 1),p_amount,p_method,nullif(trim(p_ref),''),
    case when p_confirmed then 'paid' else 'pending' end,auth.uid(),case when p_confirmed then now() end) returning id into pid;
  insert into audit_logs(actor,action,target,detail) values(auth.uid(),'record_payment',pid,jsonb_build_object('amount',p_amount,'confirmed',p_confirmed));
  return pid;
end $$;

create function confirm_payment(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  update payments set status='paid',confirmed_at=now() where id=p_id and status='pending';
  insert into audit_logs(actor,action,target) values(auth.uid(),'confirm_payment',p_id);
end $$;

create function owner_stats() returns json language plpgsql stable security definer set search_path=public as $$
declare t date:=gym_today();
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  return json_build_object(
    'members',(select count(*) from members where status<>'rejected'),
    'active',(select count(distinct member_id) from memberships where t between start_date and end_date),
    'expiring',(select count(distinct member_id) from memberships where end_date between t and t+7),
    'expired',(select count(*) from members m where status='active' and not exists(select 1 from memberships s where s.member_id=m.id and s.end_date>=t)),
    'pending',(select count(*) from members where status='pending'),
    'inside',(select count(*) from attendance where check_out is null),
    'today_in',(select count(*) from attendance where (check_in at time zone 'Asia/Kolkata')::date=t),
    'collected',(select coalesce(sum(amount),0) from payments where status='paid' and (confirmed_at at time zone 'Asia/Kolkata')::date=t));
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
alter publication supabase_realtime add table attendance;

-- PROVISION THE FIRST OWNER (after that person has signed up once in the app):
-- insert into owners(user_id) select id from auth.users where email='owner@example.com';
