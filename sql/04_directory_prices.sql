-- Run AFTER parts 1-3. Adds: member directory filters (incl. unpaid), new-joiner price setting, realtime notifications.
alter table gym_settings add column new_joiner_price numeric(12,2) not null default 1000 check(new_joiner_price>=0);

create function member_directory(p_filter text,p_q text,p_off int,p_lim int)
returns table(id uuid,member_code text,full_name text,phone text,status text,plan_code text,end_date date,due numeric)
language plpgsql stable security definer set search_path=public as $$
declare t date:=gym_today();
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  return query
  with b as (
    select m.id mid,m.member_code mc,m.full_name fn,m.phone ph,m.status st,m.created_at ca,
      (select s.plan_code from memberships s where s.member_id=m.id order by s.end_date desc limit 1) pc,
      (select max(s.end_date) from memberships s where s.member_id=m.id) ed,
      coalesce((select sum(greatest(0,s.final_price-coalesce((select sum(p.amount) from payments p where p.membership_id=s.id and p.status='paid'),0))) from memberships s where s.member_id=m.id),0) du
    from members m)
  select b.mid,b.mc,b.fn,b.ph,b.st,b.pc,b.ed,b.du from b
  where (p_filter='all' or (p_filter='pending' and b.st='pending') or (p_filter='active' and b.ed>=t)
     or (p_filter='expired' and b.st='active' and (b.ed is null or b.ed<t)) or (p_filter='expiring' and b.ed between t and t+7)
     or (p_filter='unpaid' and b.du>0) or (p_filter='inside' and exists(select 1 from attendance a where a.member_id=b.mid and a.check_out is null)))
    and (coalesce(p_q,'')='' or b.fn ilike '%'||p_q||'%' or b.ph ilike '%'||p_q||'%' or b.mc ilike '%'||p_q||'%')
  order by b.ca desc offset greatest(p_off,0) limit least(p_lim,50);
end $$;
revoke all on function member_directory(text,text,int,int) from public,anon;
grant execute on function member_directory(text,text,int,int) to authenticated;

-- Invoice adjustment line now says Discount vs Adjustment and carries the override reason (e.g. new-joiner price).
create or replace function create_invoice(p_membership uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare ms memberships; it jsonb; iid uuid;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  select * into ms from memberships where id=p_membership; if not found then raise exception 'Membership not found'; end if;
  it:=jsonb_build_array(jsonb_build_object('label',initcap(ms.plan_code)||' membership ('||to_char(ms.start_date,'DD Mon YYYY')||' to '||to_char(ms.end_date,'DD Mon YYYY')||')','amount',ms.base_price));
  if ms.addon_price>0 then it:=it||jsonb_build_array(jsonb_build_object('label','Cardio add-on','amount',ms.addon_price)); end if;
  if ms.final_price<>ms.base_price+ms.addon_price then
    it:=it||jsonb_build_array(jsonb_build_object('label',case when ms.final_price<ms.base_price+ms.addon_price then 'Discount' else 'Adjustment' end||coalesce(' — '||ms.override_reason,''),'amount',ms.final_price-ms.base_price-ms.addon_price)); end if;
  insert into invoices(member_id,membership_id,items,total) values(ms.member_id,ms.id,it,ms.final_price) returning id into iid;
  insert into audit_logs(actor,action,target) values(auth.uid(),'create_invoice',iid);
  return iid;
exception when unique_violation then raise exception 'This membership already has a draft or issued invoice';
end $$;

alter publication supabase_realtime add table notifications;
