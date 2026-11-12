-- THE VALLEY | APPLICATION PORTAL
-- Run this file in Supabase SQL Editor.
-- Uses the existing auth.users table. No service-role key belongs in the browser.

create extension if not exists pgcrypto;

create table if not exists public.valley_application_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scope text not null check (scope in ('staff','lspd','ems','doj')),
  role_key text not null,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(user_id, scope, role_key),
  check (
    (scope = 'staff' and role_key in ('staff_owner','director','assistant_director','management','senior_admin','admin')) or
    (scope in ('lspd','ems','doj') and role_key in ('department_head','command_team','member','application_reviewer'))
  )
);

create table if not exists public.valley_application_forms (
  department text primary key check (department in ('staff','lspd','ems','doj')),
  title text not null,
  description text not null default '',
  questions jsonb not null default '[]'::jsonb,
  is_open boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.valley_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references auth.users(id) on delete cascade,
  department text not null check (department in ('staff','lspd','ems','doj')),
  answers jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','under_review','approved','denied','changes_requested')),
  reviewer_id uuid references auth.users(id),
  review_notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists valley_applications_applicant_idx on public.valley_applications(applicant_id, created_at desc);
create index if not exists valley_applications_department_idx on public.valley_applications(department, status, created_at desc);

create table if not exists public.valley_application_audit (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  target_user_id uuid references auth.users(id),
  application_id uuid references public.valley_applications(id) on delete set null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

insert into public.valley_application_forms(department,title,description,questions)
values
('staff','Staff Application','Apply to join The Valley staff team.','[{"key":"character_name","label":"In-city name","type":"text","required":true},{"key":"discord_name","label":"Discord username","type":"text","required":true},{"key":"experience","label":"Previous staff experience","type":"textarea","required":true},{"key":"why","label":"Why do you want to join the staff team?","type":"textarea","required":true},{"key":"availability","label":"Typical availability","type":"text","required":true}]'::jsonb),
('lspd','LSPD Application','Apply to join the Los Santos Police Department.','[{"key":"character_name","label":"In-city name","type":"text","required":true},{"key":"discord_name","label":"Discord username","type":"text","required":true},{"key":"experience","label":"Previous law enforcement experience","type":"textarea","required":true},{"key":"why","label":"Why do you want to join LSPD?","type":"textarea","required":true},{"key":"availability","label":"Typical availability","type":"text","required":true}]'::jsonb),
('ems','EMS Application','Apply to join Emergency Medical Services.','[{"key":"character_name","label":"In-city name","type":"text","required":true},{"key":"discord_name","label":"Discord username","type":"text","required":true},{"key":"experience","label":"Previous EMS experience","type":"textarea","required":true},{"key":"why","label":"Why do you want to join EMS?","type":"textarea","required":true},{"key":"availability","label":"Typical availability","type":"text","required":true}]'::jsonb),
('doj','DOJ Application','Apply to join the Department of Justice.','[{"key":"character_name","label":"In-city name","type":"text","required":true},{"key":"discord_name","label":"Discord username","type":"text","required":true},{"key":"experience","label":"Previous DOJ or legal experience","type":"textarea","required":true},{"key":"why","label":"Why do you want to join DOJ?","type":"textarea","required":true},{"key":"availability","label":"Typical availability","type":"text","required":true}]'::jsonb)
on conflict (department) do nothing;

create or replace function public.valley_is_super_owner()
returns boolean language sql stable security definer set search_path = public
as $$ select auth.uid() = '193a2e89-2bbb-496d-851d-1bb50aeb0b62'::uuid $$;

create or replace function public.valley_has_role(p_scope text, p_role text)
returns boolean language sql stable security definer set search_path = public
as $$
  select public.valley_is_super_owner() or exists (
    select 1 from public.valley_application_roles r
    where r.user_id = auth.uid() and r.scope = p_scope and r.role_key = p_role
  )
$$;

create or replace function public.valley_can_review(p_department text)
returns boolean language sql stable security definer set search_path = public
as $$
  select case
    when public.valley_is_super_owner() then true
    when p_department = 'staff' then (
      public.valley_has_role('staff','staff_owner') or
      public.valley_has_role('staff','director') or
      public.valley_has_role('staff','assistant_director') or
      public.valley_has_role('staff','management')
    )
    else (
      public.valley_has_role(p_department,'department_head') or
      public.valley_has_role(p_department,'command_team') or
      public.valley_has_role(p_department,'application_reviewer')
    )
  end
$$;

create or replace function public.valley_get_my_roles()
returns table(scope text, role_key text, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select 'system'::text, 'super_owner'::text, now() where public.valley_is_super_owner()
  union all
  select r.scope, r.role_key, r.created_at
  from public.valley_application_roles r
  where r.user_id = auth.uid()
$$;

create or replace function public.valley_submit_application(p_department text, p_answers jsonb)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_department not in ('staff','lspd','ems','doj') then raise exception 'Invalid application department.'; end if;
  if not exists (select 1 from public.valley_application_forms f where f.department=p_department and f.is_open) then
    raise exception 'Applications for this department are currently closed.';
  end if;
  if exists (select 1 from public.valley_applications a where a.applicant_id=auth.uid() and a.department=p_department and a.status in ('pending','under_review','changes_requested')) then
    raise exception 'You already have an active application for this department.';
  end if;
  insert into public.valley_applications(applicant_id,department,answers)
  values(auth.uid(),p_department,coalesce(p_answers,'{}'::jsonb)) returning id into v_id;
  insert into public.valley_application_audit(actor_id,target_user_id,application_id,action,details)
  values(auth.uid(),auth.uid(),v_id,'application_submitted',jsonb_build_object('department',p_department));
  return v_id;
end $$;

create or replace function public.valley_review_application(p_application_id uuid, p_status text, p_notes text default '')
returns void language plpgsql security definer set search_path = public
as $$
declare v_app public.valley_applications%rowtype;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_status not in ('under_review','approved','denied','changes_requested') then raise exception 'Invalid review status.'; end if;
  select * into v_app from public.valley_applications where id=p_application_id for update;
  if not found then raise exception 'Application not found.'; end if;
  if not public.valley_can_review(v_app.department) then raise exception 'You do not have permission to review this application.'; end if;
  update public.valley_applications set status=p_status, reviewer_id=auth.uid(), review_notes=coalesce(p_notes,''), updated_at=now() where id=p_application_id;
  insert into public.valley_application_audit(actor_id,target_user_id,application_id,action,details)
  values(auth.uid(),v_app.applicant_id,p_application_id,'application_reviewed',jsonb_build_object('department',v_app.department,'status',p_status,'notes',coalesce(p_notes,'')));
end $$;

create or replace function public.valley_assign_application_role(p_user_id uuid, p_scope text, p_role_key text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.valley_is_super_owner() then raise exception 'Only the Super Owner can assign portal roles.'; end if;
  if p_scope not in ('staff','lspd','ems','doj') then raise exception 'Invalid role scope.'; end if;
  if (p_scope='staff' and p_role_key not in ('staff_owner','director','assistant_director','management','senior_admin','admin'))
     or (p_scope<>'staff' and p_role_key not in ('department_head','command_team','member','application_reviewer')) then
    raise exception 'Invalid role for this scope.';
  end if;
  insert into public.valley_application_roles(user_id,scope,role_key,granted_by)
  values(p_user_id,p_scope,p_role_key,auth.uid())
  on conflict(user_id,scope,role_key) do nothing;
  insert into public.valley_application_audit(actor_id,target_user_id,action,details)
  values(auth.uid(),p_user_id,'role_assigned',jsonb_build_object('scope',p_scope,'role',p_role_key));
end $$;

create or replace function public.valley_remove_application_role(p_user_id uuid, p_scope text, p_role_key text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.valley_is_super_owner() then raise exception 'Only the Super Owner can remove portal roles.'; end if;
  delete from public.valley_application_roles where user_id=p_user_id and scope=p_scope and role_key=p_role_key;
  insert into public.valley_application_audit(actor_id,target_user_id,action,details)
  values(auth.uid(),p_user_id,'role_removed',jsonb_build_object('scope',p_scope,'role',p_role_key));
end $$;

create or replace function public.valley_save_application_form(p_department text,p_title text,p_description text,p_questions jsonb,p_is_open boolean)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not (public.valley_is_super_owner() or public.valley_has_role('staff','staff_owner') or public.valley_has_role('staff','director') or public.valley_has_role('staff','assistant_director') or public.valley_has_role('staff','management')) then
    raise exception 'Only Management and above can edit application forms.';
  end if;
  if p_department not in ('staff','lspd','ems','doj') then raise exception 'Invalid department.'; end if;
  insert into public.valley_application_forms(department,title,description,questions,is_open,updated_by,updated_at)
  values(p_department,p_title,p_description,coalesce(p_questions,'[]'::jsonb),p_is_open,auth.uid(),now())
  on conflict(department) do update set title=excluded.title,description=excluded.description,questions=excluded.questions,is_open=excluded.is_open,updated_by=auth.uid(),updated_at=now();
  insert into public.valley_application_audit(actor_id,action,details)
  values(auth.uid(),'application_form_updated',jsonb_build_object('department',p_department));
end $$;

alter table public.valley_application_roles enable row level security;
alter table public.valley_application_forms enable row level security;
alter table public.valley_applications enable row level security;
alter table public.valley_application_audit enable row level security;

drop policy if exists valley_roles_read_self on public.valley_application_roles;
create policy valley_roles_read_self on public.valley_application_roles for select to authenticated using (user_id=auth.uid() or public.valley_is_super_owner());

drop policy if exists valley_forms_read_signed_in on public.valley_application_forms;
create policy valley_forms_read_signed_in on public.valley_application_forms for select to authenticated using (true);

drop policy if exists valley_apps_read_own_or_reviewable on public.valley_applications;
create policy valley_apps_read_own_or_reviewable on public.valley_applications for select to authenticated using (applicant_id=auth.uid() or public.valley_can_review(department));

drop policy if exists valley_audit_read_super_owner on public.valley_application_audit;
create policy valley_audit_read_super_owner on public.valley_application_audit for select to authenticated using (public.valley_is_super_owner());

revoke all on public.valley_application_roles from anon, authenticated;
revoke all on public.valley_application_forms from anon, authenticated;
revoke all on public.valley_applications from anon, authenticated;
revoke all on public.valley_application_audit from anon, authenticated;
grant select on public.valley_application_roles, public.valley_application_forms, public.valley_applications, public.valley_application_audit to authenticated;
grant execute on function public.valley_get_my_roles() to authenticated;
grant execute on function public.valley_submit_application(text,jsonb) to authenticated;
grant execute on function public.valley_review_application(uuid,text,text) to authenticated;
grant execute on function public.valley_assign_application_role(uuid,text,text) to authenticated;
grant execute on function public.valley_remove_application_role(uuid,text,text) to authenticated;
grant execute on function public.valley_save_application_form(text,text,text,jsonb,boolean) to authenticated;
