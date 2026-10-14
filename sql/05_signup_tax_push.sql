-- Run AFTER 01-04. Adds: emergency contact + add-on interest at sign-up, gym rules text, tax + gym contact on invoices, push subscriptions.
alter table gym_settings add column emergency_required boolean not null default false, add column rules_text text,
  add column gym_phone text, add column gym_email text, add column gym_address text, add column gstin text,
  add column tax_label text not null default 'GST', add column tax_rate numeric(5,2) not null default 0 check(tax_rate between 0 and 100);
alter table members add column emergency_name text, add column emergency_phone text, add column interest_plan text references plans(code), add column wants_cardio boolean not null default false;
alter table invoices add column tax_rate numeric(5,2) not null default 0, add column tax_amount numeric(12,2) not null default 0, add column tax_label text, add column gym_info jsonb;

create function signup_config() returns json language plpgsql stable security definer set search_path=public as $$
declare g gym_settings;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into g from gym_settings where id=1;
  return json_build_object('emergency_required',g.emergency_required,'addon_price',g.addon_price,'rules',g.rules_text);
end $$;

drop function onboard_self(text,text,date);
create function onboard_self(p_name text,p_phone text,p_dob date,p_ename text,p_ephone text,p_plan text,p_cardio boolean) returns void
language plpgsql security definer set search_path=public as $$
declare req boolean; ep text:=nullif(regexp_replace(coalesce(p_ephone,''),'\s','','g'),'');
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select emergency_required into req from gym_settings where id=1;
  if req and (coalesce(trim(p_ename),'')='' or coalesce(ep,'') !~ '^\+[0-9]{10,14}$') then raise exception 'Emergency contact name and mobile (with country code) are required'; end if;
  if ep is not null and ep !~ '^\+[0-9]{10,14}$' then raise exception 'Emergency mobile must include the country code'; end if;
  if not exists(select 1 from plans where code=p_plan) then raise exception 'Unknown plan'; end if;
  insert into members(user_id,full_name,phone,dob,emergency_name,emergency_phone,interest_plan,wants_cardio)
  values(auth.uid(),trim(p_name),regexp_replace(p_phone,'\s','','g'),p_dob,nullif(trim(coalesce(p_ename,'')),''),ep,p_plan,coalesce(p_cardio,false));
exception when unique_violation then raise exception 'This account or phone number is already registered';
end $$;

-- Prices are tax-INCLUSIVE: tax shown on the invoice is the portion contained in the total, so totals/dues stay consistent.
create or replace function create_invoice(p_membership uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare ms memberships; gs gym_settings; it jsonb; iid uuid; tx numeric;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  select * into ms from memberships where id=p_membership; if not found then raise exception 'Membership not found'; end if;
  select * into gs from gym_settings where id=1;
  it:=jsonb_build_array(jsonb_build_object('label',initcap(ms.plan_code)||' membership ('||to_char(ms.start_date,'DD Mon YYYY')||' to '||to_char(ms.end_date,'DD Mon YYYY')||')','amount',ms.base_price));
  if ms.addon_price>0 then it:=it||jsonb_build_array(jsonb_build_object('label','Cardio add-on','amount',ms.addon_price)); end if;
  if ms.final_price<>ms.base_price+ms.addon_price then
    it:=it||jsonb_build_array(jsonb_build_object('label',case when ms.final_price<ms.base_price+ms.addon_price then 'Discount' else 'Adjustment' end||coalesce(' — '||ms.override_reason,''),'amount',ms.final_price-ms.base_price-ms.addon_price)); end if;
  tx:=case when gs.tax_rate>0 then round(ms.final_price-ms.final_price/(1+gs.tax_rate/100),2) else 0 end;
  insert into invoices(member_id,membership_id,items,total,tax_rate,tax_amount,tax_label,gym_info)
  values(ms.member_id,ms.id,it,ms.final_price,gs.tax_rate,tx,gs.tax_label,jsonb_build_object('address',gs.gym_address,'phone',gs.gym_phone,'email',gs.gym_email,'gstin',gs.gstin)) returning id into iid;
  insert into audit_logs(actor,action,target) values(auth.uid(),'create_invoice',iid);
  return iid;
exception when unique_violation then raise exception 'This membership already has a draft or issued invoice';
end $$;

-- Web Push subscriptions (read by the send-push Edge Function with the service role; users cannot read others')
create table push_subscriptions(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade, endpoint text unique not null, p256dh text not null, auth text not null, created_at timestamptz not null default now());
alter table push_subscriptions enable row level security;
create policy ps_own on push_subscriptions for select to authenticated using(user_id=auth.uid());
revoke all on push_subscriptions from anon; revoke insert,update,delete on push_subscriptions from authenticated;
create function save_push_sub(p_endpoint text,p_p256dh text,p_auth text) returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into push_subscriptions(user_id,endpoint,p256dh,auth) values(auth.uid(),p_endpoint,p_p256dh,p_auth)
  on conflict(endpoint) do update set user_id=auth.uid(),p256dh=excluded.p256dh,auth=excluded.auth;
end $$;

revoke all on function signup_config(),onboard_self(text,text,date,text,text,text,boolean),save_push_sub(text,text,text) from public,anon;
grant execute on function signup_config(),onboard_self(text,text,date,text,text,text,boolean),save_push_sub(text,text,text) to authenticated;
