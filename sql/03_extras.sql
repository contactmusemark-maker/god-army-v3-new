-- Run AFTER setup.sql and part2. Adds notifications, profile edit, attendance correction, outstanding dues.
create table notifications(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade, title text not null, body text, is_read boolean not null default false, created_at timestamptz not null default now());
create index on notifications(user_id,created_at desc);
alter table notifications enable row level security;
create policy n_read on notifications for select to authenticated using(user_id=auth.uid());
create policy n_upd on notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
revoke all on notifications from anon; revoke insert,delete,update on notifications from authenticated; grant update(is_read) on notifications to authenticated;

create function notify_event() returns trigger language plpgsql security definer set search_path=public as $$
declare uid uuid; fire boolean;
begin
  if TG_TABLE_NAME='members' then
    insert into notifications(user_id,title,body) select user_id,'Member awaiting approval',NEW.full_name from owners;
  elsif TG_TABLE_NAME='memberships' then
    select user_id into uid from members where id=NEW.member_id;
    insert into notifications(user_id,title,body) values(uid,'Membership approved',initcap(NEW.plan_code)||' plan active until '||to_char(NEW.end_date,'DD Mon YYYY'));
  elsif TG_TABLE_NAME='payments' then
    fire:=NEW.status='paid'; if fire and TG_OP='UPDATE' then fire:=OLD.status<>'paid'; end if;
    if fire then select user_id into uid from members where id=NEW.member_id;
      insert into notifications(user_id,title,body) values(uid,'Payment confirmed','Rs '||NEW.amount); end if;
  elsif TG_TABLE_NAME='invoices' then
    if NEW.status='issued' and OLD.status='draft' then select user_id into uid from members where id=NEW.member_id;
      insert into notifications(user_id,title,body) values(uid,'Invoice issued',NEW.number); end if;
  elsif TG_TABLE_NAME='attendance' then
    select user_id into uid from members where id=NEW.member_id;
    if TG_OP='INSERT' then insert into notifications(user_id,title,body) values(uid,'Checked in',null);
    elsif NEW.check_out is not null and OLD.check_out is null then insert into notifications(user_id,title,body) values(uid,'Checked out',null); end if;
  end if;
  return NEW;
end $$;
create trigger n_m after insert on members for each row execute function notify_event();
create trigger n_ms after insert on memberships for each row execute function notify_event();
create trigger n_p after insert or update on payments for each row execute function notify_event();
create trigger n_i after update on invoices for each row execute function notify_event();
create trigger n_a after insert or update on attendance for each row execute function notify_event();
revoke execute on function notify_event() from public,anon,authenticated;

-- Expiry reminders (7 days and 1 day before). Needs a schedule; client JS cannot do this when the app is closed:
--   create extension if not exists pg_cron;
--   select cron.schedule('gaf-expiry','30 3 * * *','select public.send_expiry_reminders()');  -- 09:00 IST
create function send_expiry_reminders() returns void language sql security definer set search_path=public as $$
  insert into notifications(user_id,title,body)
  select m.user_id,'Membership expiring',case when s.end_date=gym_today()+1 then 'Expires tomorrow' else 'Expires in 7 days' end
  from memberships s join members m on m.id=s.member_id
  where s.end_date in (gym_today()+1,gym_today()+7)
  and not exists(select 1 from memberships s2 where s2.member_id=s.member_id and s2.end_date>s.end_date) $$;
revoke execute on function send_expiry_reminders() from public,anon,authenticated;

create function update_profile(p_name text,p_phone text) returns void language plpgsql security definer set search_path=public as $$
begin
  update members set full_name=trim(p_name),phone=regexp_replace(p_phone,'\s','','g') where user_id=auth.uid();
exception when unique_violation then raise exception 'That phone number is already registered';
end $$;

create function correct_attendance(p_id uuid,p_out timestamptz,p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Reason required'; end if;
  update attendance set check_out=p_out where id=p_id and check_out is null;
  if not found then raise exception 'Session is not open'; end if;
  insert into audit_logs(actor,action,target,detail) values(auth.uid(),'correct_attendance',p_id,jsonb_build_object('out',p_out,'reason',p_reason));
end $$;
grant execute on function update_profile(text,text),correct_attendance(uuid,timestamptz,text) to authenticated;

-- Outstanding dues = per membership, billed minus confirmed payments (never negative)
create or replace function owner_stats() returns json language plpgsql stable security definer set search_path=public as $$
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
    'collected',(select coalesce(sum(amount),0) from payments where status='paid' and (confirmed_at at time zone 'Asia/Kolkata')::date=t),
    'dues',(select coalesce(sum(greatest(0,s.final_price-coalesce((select sum(p.amount) from payments p where p.membership_id=s.id and p.status='paid'),0))),0) from memberships s));
end $$;
