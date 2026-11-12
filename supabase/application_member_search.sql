-- Adds the Super Owner-only member lookup used by the Role Access screen.
create or replace function public.valley_search_profiles(p_query text)
returns table(id uuid, display_name text, character_name text, roles text[])
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.valley_is_super_owner() then
    raise exception 'Only the Super Owner can search members for role assignment.';
  end if;
  return query
  select p.id,
         coalesce(p.display_name,'')::text,
         coalesce(p.character_name,'')::text,
         coalesce(array_agg(r.scope || ': ' || replace(r.role_key,'_',' ')) filter (where r.id is not null), array[]::text[])
  from public.profiles p
  left join public.valley_application_roles r on r.user_id=p.id
  where coalesce(p.display_name,'') ilike '%' || coalesce(p_query,'') || '%'
     or coalesce(p.character_name,'') ilike '%' || coalesce(p_query,'') || '%'
  group by p.id,p.display_name,p.character_name
  order by coalesce(p.display_name,p.character_name,'') asc
  limit 25;
end $$;

revoke all on function public.valley_search_profiles(text) from public, anon;
grant execute on function public.valley_search_profiles(text) to authenticated;
