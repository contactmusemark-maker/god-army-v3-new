-- Run AFTER setup.sql. Adds invoices (draft -> issued -> void) with concurrency-safe numbering GAF-YYYY-0001.
create table invoice_counters(yr int primary key, n int not null);
create table invoices(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members on delete cascade,
  membership_id uuid not null references memberships,
  number text unique,
  status text not null default 'draft' check(status in('draft','issued','void')),
  items jsonb not null, total numeric(12,2) not null check(total>=0),
  issue_date date, created_at timestamptz not null default now());
create unique index one_live_invoice on invoices(membership_id) where status<>'void';
create index on invoices(member_id,issue_date desc);
alter table invoice_counters enable row level security;
alter table invoices enable row level security;
-- Members see only ISSUED invoices of their own; drafts/void stay owner-only.
create policy inv_member on invoices for select to authenticated using(member_id=my_member_id() and status='issued');
create policy inv_owner on invoices for select to authenticated using(is_owner());
revoke all on invoices,invoice_counters from anon;
revoke insert,update,delete on invoices from authenticated;
revoke all on invoice_counters from authenticated;

create function create_invoice(p_membership uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare ms memberships; it jsonb; iid uuid;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  select * into ms from memberships where id=p_membership; if not found then raise exception 'Membership not found'; end if;
  it:=jsonb_build_array(jsonb_build_object('label',initcap(ms.plan_code)||' membership ('||to_char(ms.start_date,'DD Mon YYYY')||' to '||to_char(ms.end_date,'DD Mon YYYY')||')','amount',ms.base_price));
  if ms.addon_price>0 then it:=it||jsonb_build_array(jsonb_build_object('label','Cardio add-on','amount',ms.addon_price)); end if;
  if ms.final_price<>ms.base_price+ms.addon_price then it:=it||jsonb_build_array(jsonb_build_object('label','Discount / adjustment','amount',ms.final_price-ms.base_price-ms.addon_price)); end if;
  insert into invoices(member_id,membership_id,items,total) values(ms.member_id,ms.id,it,ms.final_price) returning id into iid;
  insert into audit_logs(actor,action,target) values(auth.uid(),'create_invoice',iid);
  return iid;
exception when unique_violation then raise exception 'This membership already has a draft or issued invoice';
end $$;

create function issue_invoice(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
declare st text; y int:=extract(year from gym_today())::int; v_n int; num text;
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  select status into st from invoices where id=p_id for update;
  if st is distinct from 'draft' then raise exception 'Only draft invoices can be issued'; end if;
  insert into invoice_counters(yr,n) values(y,1) on conflict(yr) do update set n=invoice_counters.n+1 returning n into v_n;
  num:='GAF-'||y||'-'||lpad(v_n::text,4,'0');
  update invoices set number=num,status='issued',issue_date=gym_today() where id=p_id;
  insert into audit_logs(actor,action,target,detail) values(auth.uid(),'issue_invoice',p_id,jsonb_build_object('number',num));
  return num;
end $$;

create function void_invoice(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_owner() then raise exception 'Forbidden'; end if;
  update invoices set status='void' where id=p_id and status='issued';
  if not found then raise exception 'Only issued invoices can be voided'; end if;
  insert into audit_logs(actor,action,target) values(auth.uid(),'void_invoice',p_id);
end $$;

revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
