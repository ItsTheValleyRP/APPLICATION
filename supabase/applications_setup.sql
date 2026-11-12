-- THE VALLEY | Applications + multi-role foundation
-- Run this in the EXISTING VALLEY Supabase project's SQL Editor.
-- This is additive: it does not replace profiles, auth, announcements, or website settings.

begin;

create table if not exists public.valley_role_catalog (
  role_code text primary key,
  label text not null,
  department text not null,
  sort_order integer not null default 100,
  active boolean not null default true
);

insert into public.valley_role_catalog(role_code,label,department,sort_order) values
 ('staff:owner','Staff Owner','Staff',10),
 ('staff:director','Director','Staff',20),
 ('staff:assistant_director','Assistant Director','Staff',30),
 ('staff:management','Management','Staff',40),
 ('staff:senior_admin','Senior Admin','Staff',50),
 ('staff:admin','Admin','Staff',60),
 ('lspd:department_head','LSPD Department Head','LSPD',10),
 ('lspd:command','LSPD Command Team','LSPD',20),
 ('lspd:member','LSPD Member','LSPD',30),
 ('ems:department_head','EMS Department Head','EMS',10),
 ('ems:command','EMS Command Team','EMS',20),
 ('ems:member','EMS Member','EMS',30),
 ('doj:department_head','DOJ Department Head','DOJ',10),
 ('doj:command','DOJ Command Team','DOJ',20),
 ('doj:member','DOJ Member','DOJ',30),
 ('applications:reviewer','Application Reviewer','Applications',90)
on conflict(role_code) do update set label=excluded.label,department=excluded.department,sort_order=excluded.sort_order,active=true;

create table if not exists public.valley_member_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role_code text not null references public.valley_role_catalog(role_code),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(user_id,role_code)
);
create index if not exists valley_member_roles_user_idx on public.valley_member_roles(user_id);

-- Copy existing single staff ranks into the new multi-role system without deleting the old records.
insert into public.valley_member_roles(user_id,role_code,assigned_by)
select user_id,
  case rank
    when 'Staff Owner' then 'staff:owner'
    when 'Director' then 'staff:director'
    when 'Assistant Director' then 'staff:assistant_director'
    when 'Management' then 'staff:management'
    when 'Senior Admin' then 'staff:senior_admin'
    when 'Admin' then 'staff:admin'
    else null
  end,
  assigned_by
from public.valley_staff_roles
where rank in ('Staff Owner','Director','Assistant Director','Management','Senior Admin','Admin')
on conflict(user_id,role_code) do nothing;

create table if not exists public.valley_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id) on delete cascade,
  application_type text not null check (application_type in ('staff','lspd','ems','doj')),
  character_name text not null,
  answers jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected','changes_requested')),
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text
);
create index if not exists valley_applications_applicant_idx on public.valley_applications(applicant_id,submitted_at desc);
create index if not exists valley_applications_queue_idx on public.valley_applications(application_type,status,submitted_at);

create table if not exists public.valley_application_audit (
  id bigint generated always as identity primary key,
  application_id uuid references public.valley_applications(id) on delete set null,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.valley_role_audit (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  target_user_id uuid references auth.users(id) on delete set null,
  role_code text not null,
  action text not null check(action in ('assigned','removed')),
  created_at timestamptz not null default now()
);

create or replace function public.valley_is_super_owner()
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select auth.uid() = '193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid;
$$;

create or replace function public.valley_user_has_role(p_role text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.valley_is_super_owner() or exists(
    select 1 from public.valley_member_roles r where r.user_id=auth.uid() and r.role_code=p_role
  );
$$;

create or replace function public.valley_can_review_application(p_type text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when public.valley_is_super_owner() then true
    when p_type='staff' then (
      public.valley_user_has_role('staff:owner') or
      public.valley_user_has_role('staff:director') or
      public.valley_user_has_role('staff:assistant_director') or
      public.valley_user_has_role('staff:management')
    )
    when p_type='lspd' then public.valley_user_has_role('lspd:department_head') or public.valley_user_has_role('lspd:command')
    when p_type='ems' then public.valley_user_has_role('ems:department_head') or public.valley_user_has_role('ems:command')
    when p_type='doj' then public.valley_user_has_role('doj:department_head') or public.valley_user_has_role('doj:command')
    else false end;
$$;

create or replace function public.valley_application_submit(p_type text,p_character_name text,p_answers jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_name text := trim(coalesce(p_character_name,''));
begin
  if auth.uid() is null then raise exception 'Please sign in with Discord first'; end if;
  if p_type not in ('staff','lspd','ems','doj') then raise exception 'Invalid application type'; end if;
  if char_length(v_name) not between 2 and 80 then raise exception 'Enter a valid in-city character name'; end if;
  if p_answers is null or jsonb_typeof(p_answers)<>'object' or length(p_answers::text)>20000 then raise exception 'Invalid application answers'; end if;
  if exists(select 1 from public.valley_applications where applicant_id=auth.uid() and application_type=p_type and status in ('pending','changes_requested')) then
    raise exception 'You already have an application of this type awaiting review';
  end if;
  insert into public.valley_applications(applicant_id,application_type,character_name,answers)
  values(auth.uid(),p_type,v_name,p_answers) returning id into v_id;
  insert into public.valley_application_audit(application_id,actor_user_id,action,details)
  values(v_id,auth.uid(),'submitted',jsonb_build_object('application_type',p_type));
  return v_id;
end;
$$;

create or replace function public.valley_application_my_submissions()
returns table(id uuid,application_type text,character_name text,answers jsonb,status text,submitted_at timestamptz,updated_at timestamptz,review_note text)
language sql stable security definer set search_path=public,pg_temp as $$
  select a.id,a.application_type,a.character_name,a.answers,a.status,a.submitted_at,a.updated_at,
    case when a.status in ('rejected','changes_requested','approved') then a.review_note else null end
  from public.valley_applications a where a.applicant_id=auth.uid()
  order by a.submitted_at desc;
$$;

create or replace function public.valley_application_review_queue(p_type text default null)
returns table(id uuid,applicant_id uuid,discord_name text,character_name text,application_type text,answers jsonb,status text,submitted_at timestamptz,review_note text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_type is not null and p_type not in ('staff','lspd','ems','doj') then raise exception 'Invalid application type'; end if;
  return query
  select a.id,a.applicant_id,coalesce(p.display_name,'Discord member'),a.character_name,a.application_type,a.answers,a.status,a.submitted_at,a.review_note
  from public.valley_applications a
  left join public.profiles p on p.id=a.applicant_id
  where (p_type is null or a.application_type=p_type)
    and public.valley_can_review_application(a.application_type)
  order by case when a.status='pending' then 0 when a.status='changes_requested' then 1 else 2 end,a.submitted_at asc;
end;
$$;

create or replace function public.valley_application_review(p_application_id uuid,p_decision text,p_note text default '')
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_type text; v_old text; v_note text:=left(trim(coalesce(p_note,'')),2000);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_decision not in ('approved','rejected','changes_requested') then raise exception 'Invalid review decision'; end if;
  select application_type,status into v_type,v_old from public.valley_applications where id=p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if not public.valley_can_review_application(v_type) then raise exception 'You cannot review this department application'; end if;
  if v_old not in ('pending','changes_requested') then raise exception 'This application has already been finalized'; end if;
  update public.valley_applications set status=p_decision,reviewed_at=now(),reviewed_by=auth.uid(),review_note=nullif(v_note,''),updated_at=now()
    where id=p_application_id;
  insert into public.valley_application_audit(application_id,actor_user_id,action,details)
    values(p_application_id,auth.uid(),'reviewed',jsonb_build_object('decision',p_decision,'note',v_note));
  return true;
end;
$$;

-- Super Owner-only role assignment; supports any number of roles per member.
create or replace function public.valley_roles_manage(p_target_user_id uuid,p_role_code text,p_action text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.valley_is_super_owner() then raise exception 'Only the Super Owner can assign or remove roles'; end if;
  if p_target_user_id is null or p_target_user_id='193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid then
    raise exception 'That account is protected';
  end if;
  if not exists(select 1 from public.valley_role_catalog where role_code=p_role_code and active) then raise exception 'Unknown role'; end if;
  if p_action='assign' then
    insert into public.valley_member_roles(user_id,role_code,assigned_by) values(p_target_user_id,p_role_code,auth.uid())
    on conflict(user_id,role_code) do nothing;
  elsif p_action='remove' then
    delete from public.valley_member_roles where user_id=p_target_user_id and role_code=p_role_code;
  else raise exception 'Invalid role action'; end if;
  insert into public.valley_role_audit(actor_user_id,target_user_id,role_code,action)
  values(auth.uid(),p_target_user_id,p_role_code,case when p_action='assign' then 'assigned' else 'removed' end);
  return true;
end;
$$;

create or replace function public.valley_roles_list_for_super_owner(p_query text default '')
returns table(user_id uuid,display_name text,character_name text,role_code text,role_label text,department text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.valley_is_super_owner() then raise exception 'Super Owner access required'; end if;
  return query
  select p.id,coalesce(p.display_name,'Discord member'),coalesce(p.character_name,''),r.role_code,c.label,c.department
  from public.profiles p
  left join public.valley_member_roles r on r.user_id=p.id
  left join public.valley_role_catalog c on c.role_code=r.role_code
  where coalesce(p.display_name,'') ilike '%'||trim(coalesce(p_query,''))||'%'
     or coalesce(p.character_name,'') ilike '%'||trim(coalesce(p_query,''))||'%'
  order by p.display_name,c.sort_order limit 100;
end;
$$;

alter table public.valley_role_catalog enable row level security;
alter table public.valley_member_roles enable row level security;
alter table public.valley_applications enable row level security;
alter table public.valley_application_audit enable row level security;
alter table public.valley_role_audit enable row level security;

revoke all on public.valley_role_catalog,public.valley_member_roles,public.valley_applications,public.valley_application_audit,public.valley_role_audit from anon,authenticated;
revoke all on function public.valley_is_super_owner() from public,anon;
revoke all on function public.valley_user_has_role(text) from public,anon;
revoke all on function public.valley_can_review_application(text) from public,anon;
revoke all on function public.valley_application_submit(text,text,jsonb) from public,anon;
revoke all on function public.valley_application_my_submissions() from public,anon;
revoke all on function public.valley_application_review_queue(text) from public,anon;
revoke all on function public.valley_application_review(uuid,text,text) from public,anon;
revoke all on function public.valley_roles_manage(uuid,text,text) from public,anon;
revoke all on function public.valley_roles_list_for_super_owner(text) from public,anon;

grant execute on function public.valley_application_submit(text,text,jsonb) to authenticated;
grant execute on function public.valley_application_my_submissions() to authenticated;
grant execute on function public.valley_application_review_queue(text) to authenticated;
grant execute on function public.valley_application_review(uuid,text,text) to authenticated;
grant execute on function public.valley_roles_manage(uuid,text,text) to authenticated;
grant execute on function public.valley_roles_list_for_super_owner(text) to authenticated;

commit;
