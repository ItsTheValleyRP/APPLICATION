-- THE VALLEY | DEPARTMENT MANAGEMENT + WEBSITE EDITOR
-- Additive migration for the central APPLICATION management panel.
-- Preserves existing applications, role assignments, audit records and RPC return types.

begin;

-- Expand the existing role-key constraint without removing any current roles.
alter table public.valley_application_roles
  drop constraint if exists valley_application_roles_role_key_check;
alter table public.valley_application_roles
  add constraint valley_application_roles_role_key_check
  check (
    (scope = 'staff' and role_key in (
      'staff_owner','director','assistant_director','management','senior_admin','admin',
      'department_chief','department_command'
    )) or
    (scope in ('lspd','ems','doj') and role_key in (
      'department_head','command_team','member','application_reviewer',
      'department_chief','department_command'
    ))
  );

-- Central permission check used by the existing review RPC and RLS policies.
create or replace function public.valley_can_review(p_department text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
    when auth.uid() is null then false
    when public.valley_is_super_owner() then true
    when p_department = 'staff' then (
      public.valley_has_role('staff','staff_owner')
      or public.valley_has_role('staff','director')
      or public.valley_has_role('staff','assistant_director')
      or public.valley_has_role('staff','management')
      or public.valley_has_role('staff','department_chief')
      or public.valley_has_role('staff','department_command')
    )
    when p_department in ('lspd','ems','doj') then (
      public.valley_has_role(p_department,'department_head')
      or public.valley_has_role(p_department,'command_team')
      or public.valley_has_role(p_department,'application_reviewer')
      or public.valley_has_role(p_department,'department_chief')
      or public.valley_has_role(p_department,'department_command')
    )
    else false
  end
$$;

-- Role assignment remains Super Owner-only. Both old and new role names remain valid.
create or replace function public.valley_portal_assign_application_role(
  p_user_id uuid, p_scope text, p_role_key text
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.valley_is_super_owner() then
    raise exception 'Only the Super Owner can assign portal roles.';
  end if;
  if p_scope not in ('staff','lspd','ems','doj') then
    raise exception 'Invalid role scope.';
  end if;
  if (p_scope='staff' and p_role_key not in (
      'staff_owner','director','assistant_director','management','senior_admin','admin',
      'department_chief','department_command'
    )) or
    (p_scope<>'staff' and p_role_key not in (
      'department_head','command_team','member','application_reviewer',
      'department_chief','department_command'
    )) then
    raise exception 'Invalid role for this department.';
  end if;
  insert into public.valley_application_roles(user_id,scope,role_key,granted_by)
  values(p_user_id,p_scope,p_role_key,auth.uid())
  on conflict(user_id,scope,role_key) do nothing;
  insert into public.valley_application_audit(actor_id,target_user_id,action,details)
  values(auth.uid(),p_user_id,'role_assigned',jsonb_build_object('scope',p_scope,'role',p_role_key));
end
$$;

create or replace function public.valley_portal_remove_application_role(
  p_user_id uuid, p_scope text, p_role_key text
)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if not public.valley_is_super_owner() then
    raise exception 'Only the Super Owner can remove portal roles.';
  end if;
  delete from public.valley_application_roles
  where user_id=p_user_id and scope=p_scope and role_key=p_role_key;
  insert into public.valley_application_audit(actor_id,target_user_id,action,details)
  values(auth.uid(),p_user_id,'role_removed',jsonb_build_object('scope',p_scope,'role',p_role_key));
end
$$;

create or replace function public.valley_portal_list_member_roles(p_user_id uuid)
returns table(scope text, role_key text, created_at timestamptz)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.valley_is_super_owner() then
    raise exception 'Only the Super Owner can view another member’s roles.';
  end if;
  return query
  select r.scope, r.role_key, r.created_at
  from public.valley_application_roles r
  where r.user_id=p_user_id
  order by r.scope,r.role_key;
end
$$;

create or replace function public.valley_portal_search_profiles(p_query text)
returns table(id uuid, display_name text, character_name text, roles text[])
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
begin
  if not public.valley_is_super_owner() then
    raise exception 'Only the Super Owner can search members for role assignment.';
  end if;
  return query
  select p.id,
    coalesce(p.display_name,'')::text,
    coalesce(p.character_name,'')::text,
    coalesce(array_agg(r.scope || ': ' || replace(r.role_key,'_',' ')) filter(where r.id is not null),array[]::text[])
  from public.profiles p
  left join public.valley_application_roles r on r.user_id=p.id
  where coalesce(p.display_name,'') ilike '%'||coalesce(p_query,'')||'%'
     or coalesce(p.character_name,'') ilike '%'||coalesce(p_query,'')||'%'
  group by p.id,p.display_name,p.character_name
  order by coalesce(p.display_name,p.character_name,'') asc
  limit 25;
end
$$;

-- Per-department website copy and accent settings.
create table if not exists public.valley_department_website_settings (
  department text primary key check (department in ('staff','lspd','ems','doj')),
  content jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

insert into public.valley_department_website_settings(department,content)
values
('staff','{"hero_eyebrow":"The Valley Roleplay · Recruitment Division","hero_title_line1":"Be part of what","hero_title_line2":"keeps us moving.","hero_description":"Help shape the community behind the city. Submit your Staff application, follow its progress, and take the next step with The Valley.","art_label":"STAFF RECRUITMENT","art_title":"Good communities are built by good people.","art_foot":"THE VALLEY ROLEPLAY · EST. COMMUNITY","accent_color":"#76a9ff"}'::jsonb),
('lspd','{"hero_eyebrow":"The Valley Roleplay · LSPD Recruitment","hero_title_line1":"Stand for the city.","hero_title_line2":"Lead with integrity.","hero_description":"Protect the community, uphold the law, and earn the public''s trust. Start your LSPD application and take your place on the streets of The Valley.","art_label":"LSPD RECRUITMENT","art_title":"Courage. Duty. Community.","art_foot":"THE VALLEY ROLEPLAY · EST. COMMUNITY","accent_color":"#76a9ff"}'::jsonb),
('ems','{"hero_eyebrow":"The Valley Roleplay · EMS Recruitment","hero_title_line1":"When the call comes,","hero_title_line2":"we answer.","hero_description":"Every response matters. Bring compassion, skill, and commitment to those who need help. Start your EMS application and make a difference in The Valley.","art_label":"EMS RECRUITMENT","art_title":"Care. Commitment. Compassion.","art_foot":"THE VALLEY ROLEPLAY · EST. COMMUNITY","accent_color":"#72aaff"}'::jsonb),
('doj','{"hero_eyebrow":"The Valley Roleplay · DOJ Recruitment","hero_title_line1":"Be part of the","hero_title_line2":"justice system.","hero_description":"Uphold fairness, accountability, and integrity. Submit your DOJ application, follow its progress, and take the next step with The Valley.","art_label":"DOJ RECRUITMENT","art_title":"Justice. Integrity. Accountability.","art_foot":"THE VALLEY ROLEPLAY · EST. COMMUNITY","accent_color":"#72aaff"}'::jsonb)
on conflict(department) do nothing;

alter table public.valley_department_website_settings enable row level security;
drop policy if exists valley_department_website_settings_public_read on public.valley_department_website_settings;
create policy valley_department_website_settings_public_read
on public.valley_department_website_settings for select to anon, authenticated using (true);
revoke all on public.valley_department_website_settings from public, anon, authenticated;
grant select on public.valley_department_website_settings to anon, authenticated;

create or replace function public.valley_public_department_website_settings(p_department text)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select content
  from public.valley_department_website_settings
  where department=p_department
    and p_department in ('staff','lspd','ems','doj')
$$;

create or replace function public.valley_portal_save_department_website(
  p_department text, p_content jsonb
)
returns boolean
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_allowed boolean := false;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_department not in ('staff','lspd','ems','doj') then raise exception 'Invalid department.'; end if;
  if p_content is null or jsonb_typeof(p_content)<>'object' then raise exception 'Website content must be a JSON object.'; end if;

  if public.valley_is_super_owner() then
    v_allowed := true;
  elsif p_department='staff' then
    v_allowed := public.valley_has_role('staff','department_chief')
      or public.valley_has_role('staff','department_command')
      or public.valley_has_role('staff','staff_owner')
      or public.valley_has_role('staff','director')
      or public.valley_has_role('staff','assistant_director')
      or public.valley_has_role('staff','management');
  else
    v_allowed := public.valley_has_role(p_department,'department_chief')
      or public.valley_has_role(p_department,'department_command')
      or public.valley_has_role(p_department,'department_head')
      or public.valley_has_role(p_department,'command_team');
  end if;

  if not v_allowed then raise exception 'You do not have permission to edit this department website.'; end if;

  -- Accept only known text fields and a validated hex accent color.
  if length(coalesce(p_content->>'hero_eyebrow',''))>120
    or length(coalesce(p_content->>'hero_title_line1',''))>100
    or length(coalesce(p_content->>'hero_title_line2',''))>100
    or length(coalesce(p_content->>'hero_description',''))>700
    or length(coalesce(p_content->>'art_label',''))>80
    or length(coalesce(p_content->>'art_title',''))>180
    or length(coalesce(p_content->>'art_foot',''))>100
    or coalesce(p_content->>'accent_color','#76a9ff') !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'One or more website fields are invalid or too long.';
  end if;

  insert into public.valley_department_website_settings(department,content,updated_by,updated_at)
  values(p_department,p_content,auth.uid(),now())
  on conflict(department) do update
    set content=excluded.content,updated_by=auth.uid(),updated_at=now();

  insert into public.valley_application_audit(actor_id,action,details)
  values(auth.uid(),'department_website_updated',jsonb_build_object('department',p_department));
  return true;
end
$$;

revoke all on function public.valley_portal_assign_application_role(uuid,text,text) from public, anon;
revoke all on function public.valley_portal_remove_application_role(uuid,text,text) from public, anon;
revoke all on function public.valley_portal_list_member_roles(uuid) from public, anon;
revoke all on function public.valley_portal_search_profiles(text) from public, anon;
revoke all on function public.valley_public_department_website_settings(text) from public;
revoke all on function public.valley_portal_save_department_website(text,jsonb) from public, anon;

grant execute on function public.valley_portal_assign_application_role(uuid,text,text) to authenticated;
grant execute on function public.valley_portal_remove_application_role(uuid,text,text) to authenticated;
grant execute on function public.valley_portal_list_member_roles(uuid) to authenticated;
grant execute on function public.valley_portal_search_profiles(text) to authenticated;
grant execute on function public.valley_public_department_website_settings(text) to anon, authenticated;
grant execute on function public.valley_portal_save_department_website(text,jsonb) to authenticated;

commit;

-- Run this migration once in the shared Supabase SQL Editor.
-- Afterward, assign department_chief / department_command roles from the central Role Access tab.
