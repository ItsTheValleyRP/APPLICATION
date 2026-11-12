create or replace function public.valley_list_member_roles(p_user_id uuid)
returns table(scope text, role_key text, created_at timestamptz)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.valley_is_super_owner() then raise exception 'Only the Super Owner can view member role assignments.'; end if;
  return query
    select r.scope,r.role_key,r.created_at
    from public.valley_application_roles r
    where r.user_id=p_user_id
    order by r.scope,r.role_key;
end $$;
revoke all on function public.valley_list_member_roles(uuid) from public, anon;
grant execute on function public.valley_list_member_roles(uuid) to authenticated;
