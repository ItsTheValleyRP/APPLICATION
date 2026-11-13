# THE VALLEY — APPLICATION PORTAL

A standalone Discord-authenticated application portal for The Valley Roleplay, powered by Supabase.

## Included
- Discord sign-in through Supabase Auth
- Staff, LSPD, EMS, and DOJ applications
- Applicant-only application history
- Department-scoped review queues
- Multiple roles per person across staff and departments
- Super Owner role assignment and role removal RPCs
- Application form editing for Management and above
- Audit records for submissions, reviews, form edits, and role changes
- No FiveM server resources, scripts, or tracking bots

## Setup

1. In the existing Supabase project, open **SQL Editor**.
2. Run `supabase/application_portal_setup.sql`.
3. Run `supabase/application_member_search.sql`.
4. In Supabase Authentication → URL Configuration, add the GitHub Pages URL for this repository to the allowed Redirect URLs. The site URL will be:
   `https://itsthevalleyrp.github.io/APPLICATION/`
5. In Authentication → Providers, enable Discord and keep the existing Discord OAuth provider configuration.
6. Enable GitHub Pages for this repository using the `main` branch and `/(root)`.
7. Open the published site and sign in with Discord.

The frontend uses the Supabase publishable key. Never put a Supabase service-role key in this repository.

## Role model

A person can hold multiple independent roles. Staff roles use the `staff` scope; department roles use `lspd`, `ems`, or `doj`.

Staff application reviewers: Staff Owner, Director, Assistant Director, Management, and Super Owner.

Department application reviewers: that department's Department Head, Command Team, or Application Reviewer.

The Super Owner is a fixed account identity and is not assignable through the normal role assignment screen. Only the configured Super Owner can see the Super Owner label and manage portal roles.

## Important first-run note

The portal is a separate site and does not change the existing VALLEY-WEB project. Run both SQL setup files before using the site. Application forms are initially editable by Management and above; department command roles can review their department's submissions.


## Department leadership and website editor

After the original portal setup and the member-search SQL have been run, also run:

`supabase/department_management_and_website_editor.sql`

This additive migration:
- Adds **Department Chief** and **Department Command** roles for Staff, LSPD, EMS, and DOJ.
- Gives those department roles access to review applications for their own department.
- Gives each department's Chief and Command access to edit that department's public website copy and accent color.
- Adds a central **Website editor** tab to this portal, with a separate editor for Staff, LSPD, EMS, and DOJ.
- Keeps role assignment restricted to the Super Owner and records role and website changes in the existing audit table.
- Preserves legacy role names and existing applications, role assignments, and audit history.

The four department websites read their public website copy from the same Supabase project and refresh it periodically. The editor changes hero text, artwork text, and accent color; it does not provide arbitrary HTML or JavaScript editing.

**Central management panel:** https://itsthevalleyrp.github.io/APPLICATION/

After running the migration, sign in as the Super Owner, open **Role access**, search for each person, and assign the matching department scope with **Department Chief** or **Department Command**. Those users can then sign in to the central panel and see the Website editor for their own department.
