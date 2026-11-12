-- Replace the Staff application with the exact eight questions requested.
-- This updates the form definition only; existing applications and answers remain unchanged.

begin;

update public.valley_application_forms
set title='VALLEY Staff Application',
    description='Apply to join The Valley Roleplay staff team.',
    questions='[
      {"key":"discord_username","label":"Discord Username (Example: Name#0001)","type":"text","required":true},
      {"key":"steam_name","label":"What is your Steam name?","type":"text","required":true},
      {"key":"character_name","label":"What''s your in-game character name?","type":"text","required":true},
      {"key":"age","label":"How old are you?","type":"text","required":true},
      {"key":"staff_experience","label":"Do you have any prior Staff experience? If so please explain.","type":"textarea","required":true},
      {"key":"team_qualities","label":"What would make you a good addition to our team? And What qualities can you bring to our staff team?","type":"textarea","required":true},
      {"key":"weekly_hours","label":"How many hours can you put into discord/city per week?","type":"text","required":true},
      {"key":"about_yourself_ooc","label":"Tell us about yourself. (OOC)","type":"textarea","required":true}
    ]'::jsonb,
    updated_at=now()
where department='staff';

commit;
