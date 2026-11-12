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
