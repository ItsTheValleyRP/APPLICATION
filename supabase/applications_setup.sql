-- THE VALLEY | Applications portal + multi-role permissions
-- Additive migration for the existing VALLEY Supabase project.
-- Matches the current APPLICATION/index.html frontend.
-- Run once in Supabase SQL Editor. Does not replace website/auth tables.

begin;

create table if not exists public.valley_application_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null check (scope in ('system','staff','lspd','ems','doj')),
  role_key text not null,
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(user_id,scope,role_key),
  check (
    (scope='system' and role_key='super_owner') or
    (scope='staff' and role_key in ('staff_owner','director','assistant_director','management','senior_admin','admin')) or
    (scope in ('lspd','ems','doj') and role_key in ('department_head','command_team','application_reviewer','member'))
  )
);
create index if not exists valley_application_roles_user_idx on public.valley_application_roles(user_id);

-- Carry forward the existing single staff rank into the new multi-role model.
insert into public.valley_application_roles(user_id,scope,role_key,assigned_by)
select user_id,'staff',
  case rank
    when 'Staff Owner' then 'staff_owner'
    when 'Director' then 'director'
    when 'Assistant Director' then 'assistant_director'
    when 'Management' then 'management'
    when 'Senior Admin' then 'senior_admin'
    when 'Admin' then 'admin'
  end,
  assigned_by
from public.valley_staff_roles
where rank in ('Staff Owner','Director','Assistant Director','Management','Senior Admin','Admin')
on conflict(user_id,scope,role_key) do nothing;

create table if not exists public.valley_application_forms (
  department text primary key check(department in ('staff','lspd','ems','doj')),
  title text not null,
  description text not null default '',
  questions jsonb not null default '[]'::jsonb,
  is_open boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.valley_application_forms(department,title,description,questions,is_open) values
('staff','VALLEY Staff Application','Apply to help lead and support The Valley Roleplay community.', '[{"key":"motivation","label":"Why do you want to join the VALLEY Staff Team?","type":"textarea","required":true},{"key":"experience","label":"Describe any previous staff or leadership experience.","type":"textarea","required":true},{"key":"availability","label":"What is your usual availability?","type":"text","required":true},{"key":"scenario","label":"A member reports another player for breaking server rules. How would you handle the situation fairly?","type":"textarea","required":true}]'::jsonb,true),
('lspd','LSPD Application','Apply to serve the city through law enforcement roleplay.', '[{"key":"motivation","label":"Why do you want to join LSPD?","type":"textarea","required":true},{"key":"experience","label":"Describe your previous law-enforcement or leadership roleplay experience.","type":"textarea","required":true},{"key":"availability","label":"What is your usual availability?","type":"text","required":true},{"key":"scenario","label":"How would you handle a situation where another officer is escalating an interaction unnecessarily?","type":"textarea","required":true}]'::jsonb,true),
('ems','EMS Application','Apply to support the city through emergency medical roleplay.', '[{"key":"motivation","label":"Why do you want to join EMS?","type":"textarea","required":true},{"key":"experience","label":"Describe any previous EMS or medical roleplay experience.","type":"textarea","required":true},{"key":"availability","label":"What is your usual availability?","type":"text","required":true},{"key":"scenario","label":"How would you respond to a busy scene where several people need assistance?","type":"textarea","required":true}]'::jsonb,true),
('doj','DOJ Application','Apply to support legal roleplay and the justice system.', '[{"key":"motivation","label":"Why do you want to join the Department of Justice?","type":"textarea","required":true},{"key":"experience","label":"Describe any previous legal or courtroom roleplay experience.","type":"textarea","required":true},{"key":"availability","label":"What is your usual availability?","type":"text","required":true},{"key":"scenario","label":"How would you approach a case where the evidence presented is incomplete or conflicting?","type":"textarea","required":true}]'::jsonb,true)
on conflict(department) do nothing;

create table if not exists public.valley_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id) on delete cascade,
  department text not null check(department in ('staff','lspd','ems','doj')),
  answers jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check(status in ('pending','under_review','changes_requested','approved','denied')),
  review_notes text,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists valley_applications_applicant_idx on public.valley_applications(applicant_id,created_at desc);
create index if not exists valley_applications_department_idx on public.valley_applications(department,status,created_at desc);

create table if not exists public.valley_application_audit (
  id bigint generated always as identity primary key,
  application_id uuid references public.valley_applications(id) on delete set null,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.valley_application_role_audit (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  target_user_id uuid references auth.users(id) on delete set null,
  scope text not null,
  role_key text not null,
  action text not null check(action in ('assigned','removed')),
  created_at timestamptz not null default now()
);

create or replace function public.valley_is_application_super_owner()
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select auth.uid()='193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid;
$$;

create or replace function public.valley_has_application_role(p_scope text,p_role_key text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select public.valley_is_application_super_owner() or exists(
    select 1 from public.valley_application_roles r
    where r.user_id=auth.uid() and r.scope=p_scope and r.role_key=p_role_key
  );
$$;

create or replace function public.valley_can_review_department(p_department text)
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select case
    when public.valley_is_application_super_owner() then true
    when p_department='staff' then
      public.valley_has_application_role('staff','staff_owner') or
      public.valley_has_application_role('staff','director') or
      public.valley_has_application_role('staff','assistant_director') or
      public.valley_has_application_role('staff','management')
    when p_department in ('lspd','ems','doj') then
      public.valley_has_application_role(p_department,'department_head') or
      public.valley_has_application_role(p_department,'command_team')
    else false end;
$$;

create or replace function public.valley_get_my_roles()
returns table(scope text,role_key text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if public.valley_is_application_super_owner() then
    return query select 'system'::text,'super_owner'::text;
  end if;
  return query select r.scope,r.role_key from public.valley_application_roles r where r.user_id=auth.uid();
end;
$$;

create or replace function public.valley_submit_application(p_department text,p_answers jsonb)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in with Discord first'; end if;
  if p_department not in ('staff','lspd','ems','doj') then raise exception 'Invalid department'; end if;
  if p_answers is null or jsonb_typeof(p_answers)<>'object' or length(p_answers::text)>20000 then raise exception 'Invalid application answers'; end if;
  if not exists(select 1 from public.valley_application_forms f where f.department=p_department and f.is_open) then raise exception 'Applications for this department are currently closed'; end if;
  if exists(select 1 from public.valley_applications a where a.applicant_id=auth.uid() and a.department=p_department and a.status in ('pending','under_review','changes_requested')) then
    raise exception 'You already have an active application for this department';
  end if;
  insert into public.valley_applications(applicant_id,department,answers) values(auth.uid(),p_department,p_answers) returning id into v_id;
  insert into public.valley_application_audit(application_id,actor_user_id,action,details)
    values(v_id,auth.uid(),'submitted',jsonb_build_object('department',p_department));
  return v_id;
end;
$$;

create or replace function public.valley_review_application(p_application_id uuid,p_status text,p_notes text default '')
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare v_department text; v_old_status text; v_notes text:=left(trim(coalesce(p_notes,'')),2000);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_status not in ('under_review','changes_requested','approved','denied') then raise exception 'Invalid review status'; end if;
  select a.department,a.status into v_department,v_old_status from public.valley_applications a where a.id=p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if not public.valley_can_review_department(v_department) then raise exception 'You are not authorized to review this department'; end if;
  if v_old_status in ('approved','denied') then raise exception 'This application has already been finalized'; end if;
  update public.valley_applications set status=p_status,review_notes=nullif(v_notes,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_application_id;
  insert into public.valley_application_audit(application_id,actor_user_id,action,details)
    values(p_application_id,auth.uid(),'review_updated',jsonb_build_object('status',p_status,'notes',v_notes));
  return true;
end;
$$;

create or replace function public.valley_save_application_form(
  p_department text,p_title text,p_description text,p_questions jsonb,p_is_open boolean
)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not (public.valley_is_application_super_owner() or
    public.valley_has_application_role('staff','staff_owner') or
    public.valley_has_application_role('staff','director') or
    public.valley_has_application_role('staff','assistant_director') or
    public.valley_has_application_role('staff','management')) then
    raise exception 'Only Management and higher can edit application forms';
  end if;
  if p_department not in ('staff','lspd','ems','doj') then raise exception 'Invalid department'; end if;
  if char_length(trim(coalesce(p_title,''))) not between 3 and 120 then raise exception 'Form title must be 3 to 120 characters'; end if;
  if jsonb_typeof(p_questions)<>'array' or jsonb_array_length(p_questions)>30 then raise exception 'Invalid form questions'; end if;
  update public.valley_application_forms set title=trim(p_title),description=left(trim(coalesce(p_description,'')),2000),questions=p_questions,is_open=coalesce(p_is_open,false),updated_by=auth.uid(),updated_at=now()
  where department=p_department;
  if not found then raise exception 'Application form not found'; end if;
  return true;
end;
$$;

create or replace function public.valley_search_profiles(p_query text)
returns table(id uuid,display_name text,character_name text,roles text[])
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_query text:=trim(coalesce(p_query,''));
begin
  if not public.valley_is_application_super_owner() then raise exception 'Only the Super Owner can search members for role management'; end if;
  return query
  select p.id,coalesce(p.display_name,'Discord member'),coalesce(p.character_name,''),
    coalesce(array_agg(r.scope||':'||r.role_key) filter(where r.role_key is not null),'{}'::text[])
  from public.profiles p left join public.valley_application_roles r on r.user_id=p.id
  where p.id<>'193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid
    and (v_query='' or coalesce(p.display_name,'') ilike '%'||v_query||'%' or coalesce(p.character_name,'') ilike '%'||v_query||'%')
  group by p.id,p.display_name,p.character_name order by p.display_name limit 50;
end;
$$;

create or replace function public.valley_list_member_roles(p_user_id uuid)
returns table(scope text,role_key text)
language plpgsql stable security definer set search_path=public,pg_temp as $$
begin
  if not public.valley_is_application_super_owner() then raise exception 'Only the Super Owner can view member roles'; end if;
  return query select r.scope,r.role_key from public.valley_application_roles r where r.user_id=p_user_id order by r.scope,r.role_key;
end;
$$;

create or replace function public.valley_assign_application_role(p_user_id uuid,p_scope text,p_role_key text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.valley_is_application_super_owner() then raise exception 'Only the Super Owner can assign roles'; end if;
  if p_user_id is null or p_user_id='193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid then raise exception 'That account is protected'; end if;
  if not (
    (p_scope='staff' and p_role_key in ('staff_owner','director','assistant_director','management','senior_admin','admin')) or
    (p_scope in ('lspd','ems','doj') and p_role_key in ('department_head','command_team','application_reviewer','member'))
  ) then raise exception 'Invalid role'; end if;
  insert into public.valley_application_roles(user_id,scope,role_key,assigned_by) values(p_user_id,p_scope,p_role_key,auth.uid()) on conflict do nothing;
  insert into public.valley_application_role_audit(actor_user_id,target_user_id,scope,role_key,action) values(auth.uid(),p_user_id,p_scope,p_role_key,'assigned');
  return true;
end;
$$;

create or replace function public.valley_remove_application_role(p_user_id uuid,p_scope text,p_role_key text)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.valley_is_application_super_owner() then raise exception 'Only the Super Owner can remove roles'; end if;
  if p_user_id is null or p_user_id='193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid then raise exception 'That account is protected'; end if;
  delete from public.valley_application_roles where user_id=p_user_id and scope=p_scope and role_key=p_role_key;
  insert into public.valley_application_role_audit(actor_user_id,target_user_id,scope,role_key,action) values(auth.uid(),p_user_id,p_scope,p_role_key,'removed');
  return true;
end;
$$;

alter table public.valley_application_roles enable row level security;
alter table public.valley_application_forms enable row level security;
alter table public.valley_applications enable row level security;
alter table public.valley_application_audit enable row level security;
alter table public.valley_application_role_audit enable row level security;

drop policy if exists valley_forms_read_authenticated on public.valley_application_forms;
create policy valley_forms_read_authenticated on public.valley_application_forms for select to authenticated using (true);
drop policy if exists valley_apps_read_own_or_reviewer on public.valley_applications;
create policy valley_apps_read_own_or_reviewer on public.valley_applications for select to authenticated
using (applicant_id=auth.uid() or public.valley_can_review_department(department));

revoke all on public.valley_application_roles,public.valley_application_audit,public.valley_application_role_audit from anon,authenticated;
revoke insert,update,delete on public.valley_application_forms from anon,authenticated;
revoke insert,update,delete on public.valley_applications from anon,authenticated;
grant select on public.valley_application_forms,public.valley_applications to authenticated;

revoke all on function public.valley_is_application_super_owner() from public,anon;
revoke all on function public.valley_has_application_role(text,text) from public,anon;
revoke all on function public.valley_can_review_department(text) from public,anon;
revoke all on function public.valley_get_my_roles() from public,anon;
revoke all on function public.valley_submit_application(text,jsonb) from public,anon;
revoke all on function public.valley_review_application(uuid,text,text) from public,anon;
revoke all on function public.valley_save_application_form(text,text,text,jsonb,boolean) from public,anon;
revoke all on function public.valley_search_profiles(text) from public,anon;
revoke all on function public.valley_list_member_roles(uuid) from public,anon;
revoke all on function public.valley_assign_application_role(uuid,text,text) from public,anon;
revoke all on function public.valley_remove_application_role(uuid,text,text) from public,anon;

grant execute on function public.valley_can_review_department(text) to authenticated;\ngrant execute on function public.valley_get_my_roles() to authenticated;
grant execute on function public.valley_submit_application(text,jsonb) to authenticated;
grant execute on function public.valley_review_application(uuid,text,text) to authenticated;
grant execute on function public.valley_save_application_form(text,text,text,jsonb,boolean) to authenticated;
grant execute on function public.valley_search_profiles(text) to authenticated;
grant execute on function public.valley_list_member_roles(uuid) to authenticated;
grant execute on function public.valley_assign_application_role(uuid,text,text) to authenticated;
grant execute on function public.valley_remove_application_role(uuid,text,text) to authenticated;

commit;
