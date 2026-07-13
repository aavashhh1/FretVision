# FretVision

FretVision is a browser-first guitar practice application designed to evaluate fretting-hand placement and practice-session quality using on-device computer vision.

The project is currently in its database-foundation phase. The local Supabase stack, PostgreSQL schema, row-level security, backend application role, migrations, and pgTAP verification harness are complete and passing.

## Current status

As of 2026-07-13:

- Local Supabase development environment is working.
- Database migrations `0001` through `0007` apply cleanly.
- The backend role `fretvision_app` is created outside migrations.
- Least-privilege grants are applied to `fretvision_app`.
- Row-level security and client privilege boundaries are verified.
- All Batch D database tests pass.
- Total passing assertions: **165**
  - Phase 1: **138**
  - Phase 2: **27**
- The repository is pushed to GitHub on branch `main`.
- Latest database-foundation commit at the time of writing: `a88474d`

## Project overview

FretVision is planned as a browser-first practice system with the following architecture:

- **Frontend:** Next.js with TypeScript
- **Backend:** FastAPI
- **Database and authentication:** Supabase PostgreSQL and Supabase Auth
- **Computer vision:** MediaPipe and OpenCV.js in the browser
- **Security:** PostgreSQL row-level security and a dedicated least-privilege backend role
- **Testing:** pgTAP through the Supabase CLI

Raw webcam frames are intended to remain on the user's device. The browser performs the computer-vision analysis and sends only structured practice-session data to the backend.

## Repository structure

```text
FretVision/
├── backend/
│   ├── .env.example
│   └── .env.hosted.example
├── frontend/
│   ├── .env.example
│   └── .env.hosted.example
├── scripts/
│   ├── bootstrap_role.sql
│   ├── grant_fretvision_app.sql
│   ├── reset_local.ps1
│   ├── reset_local.sh
│   ├── run_db_tests.ps1
│   ├── run_db_tests.sh
│   └── README.md
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   │   ├── 20260710000001_extensions_enums.sql
│   │   ├── 20260710000002_catalog.sql
│   │   ├── 20260710000003_user_owned.sql
│   │   ├── 20260710000004_triggers.sql
│   │   ├── 20260710000005_views.sql
│   │   ├── 20260710000006_client_grants_rls.sql
│   │   └── 20260710000007_seed_catalog.sql
│   └── tests/
│       └── database/
│           ├── 001_schema_invariants.test.sql
│           ├── 002_catalog_immutability.test.sql
│           ├── 003_lifecycle_and_metrics.test.sql
│           ├── 004_rls_isolation.test.sql
│           ├── 005_client_privileges.test.sql
│           └── 006_app_role_privileges.test.sql
├── .gitignore
├── package.json
├── package-lock.json
└── README.md
```

## Database design

The current schema separates immutable catalog data from user-owned practice data.

### Catalog data

The catalog defines exercises, revisions, target positions, and published content.

Important characteristics:

- Published revisions are immutable.
- Sessions reference immutable exercise and target-position revisions.
- The seeded catalog is readable by authenticated users.
- Anonymous access to the application schema is restricted.

### User-owned data

The user-owned portion includes:

- User profiles
- Practice sessions
- Session samples
- Session metrics
- Invalid-reason counts

Sessions follow a controlled lifecycle:

```text
created -> active -> completed
                 \-> abandoned
```

Lifecycle transitions, terminal-session locking, metrics requirements, reason-count totals, and cascade behavior are enforced in PostgreSQL.

## Database migrations

### `20260710000001_extensions_enums.sql`

Creates required extensions and enum types.

### `20260710000002_catalog.sql`

Creates the immutable exercise catalog and revision tables.

### `20260710000003_user_owned.sql`

Creates profiles, sessions, samples, metrics, and invalid-reason tables.

### `20260710000004_triggers.sql`

Adds lifecycle, immutability, terminal-session, metrics, and deferred integrity triggers.

### `20260710000005_views.sql`

Creates security-invoker views for published catalog and user practice summaries.

### `20260710000006_client_grants_rls.sql`

Defines client grants, revocations, and row-level security policies.

### `20260710000007_seed_catalog.sql`

Seeds the initial published exercise catalog.

## Security model

### Browser and authenticated client

The browser uses the Supabase publishable key and the authenticated user's JWT.

The authenticated role is allowed to:

- Read published catalog data
- Read and manage only the current user's permitted rows
- Query approved security-invoker views

The anonymous role does not receive general `USAGE` on the application schema.

### FastAPI backend

FastAPI is intended to connect using the dedicated PostgreSQL role:

```text
fretvision_app
```

This role is created outside the migration chain because migrations should remain portable and should not contain environment-specific login credentials.

The role is provisioned by:

```text
scripts/bootstrap_role.sql
```

Its least-privilege grants are applied by:

```text
scripts/grant_fretvision_app.sql
```

The role is created with the privileges needed by the backend, including the approved RLS-bypass behavior, without giving it full PostgreSQL superuser privileges.

## Prerequisites

### Required

- Git
- Node.js
- npm
- Docker Desktop using Linux containers
- PowerShell 5.1 or newer on Windows

A separate PostgreSQL installation is not required for the validated Windows workflow. The scripts use `psql` inside the local Supabase PostgreSQL container when host `psql.exe` is unavailable.

## Clone and install

```powershell
git clone https://github.com/aavashhh1/FretVision.git
Set-Location FretVision
npm install
```

The Supabase CLI is installed as a local development dependency and should be invoked through the repository-local executable or `npx`.

Verify:

```powershell
Test-Path .\node_modules\.bin\supabase.cmd
npx supabase --version
docker --version
```

## Start the local Supabase stack

```powershell
npx supabase start
```

Typical local endpoints:

```text
Project API: http://127.0.0.1:54321
PostgreSQL:  127.0.0.1:54322
Studio:      http://127.0.0.1:54323
Mailpit:     http://127.0.0.1:54324
```

The exact values can be checked with:

```powershell
npx supabase status
```

Some optional services, such as `imgproxy` or the local connection pooler, may be stopped. They are not required for the current database test suite.

## Run the complete database verification

### Windows PowerShell

From the repository root:

```powershell
$env:SUPABASE_DB_CONTAINER = 'supabase_db_FretVision'
$env:FRETVISION_APP_PASSWORD = 'replace-with-a-local-password-of-at-least-24-characters'

.\scripts\run_db_tests.ps1
```

Do not commit the application-role password.

The test runner performs the following steps:

1. Starts the local Supabase stack.
2. Resets the local database.
3. Applies migrations `0001` through `0007`.
4. Detects an accessible PostgreSQL administrator inside the local container.
5. Creates or updates `fretvision_app`.
6. Applies backend grants.
7. Runs eight preflight checks.
8. Runs Phase 1 tests `001` through `005`.
9. Verifies that `fretvision_app` exists.
10. Runs Phase 2 test `006`.

A successful run ends with:

```text
PHASE 1: PASS.
PHASE 2: PASS.
ALL BATCH D TESTS PASSED.
```

## Reset the local database without running the full suite

### Windows

```powershell
$env:SUPABASE_DB_CONTAINER = 'supabase_db_FretVision'
$env:FRETVISION_APP_PASSWORD = 'replace-with-a-local-password-of-at-least-24-characters'

.\scripts\reset_local.ps1
```

### Linux, macOS, or WSL

```bash
export SUPABASE_DB_CONTAINER='supabase_db_FretVision'
export FRETVISION_APP_PASSWORD='replace-with-a-local-password-of-at-least-24-characters'

./scripts/reset_local.sh
```

The reset scripts use a PostgreSQL superuser-equivalent role only for local role provisioning. In the local Supabase Docker stack, this is normally `supabase_admin`.

## Test suite

### Phase 1

#### `001_schema_invariants.test.sql`

Verifies schema objects, columns, constraints, and structural invariants.

#### `002_catalog_immutability.test.sql`

Verifies that published catalog revisions cannot be modified improperly.

#### `003_lifecycle_and_metrics.test.sql`

Verifies:

- Session birth rules
- Legal and illegal lifecycle transitions
- Sample identity immutability
- Terminal-session sample locking
- Completed-session metrics requirements
- Invalid-reason total consistency
- Abandonment behavior
- Parent-user cascade behavior
- Deferred constraint execution

The test uses PL/pgSQL subtransactions for isolated deferred-trigger scenarios so pgTAP bookkeeping is not rolled back.

#### `004_rls_isolation.test.sql`

Verifies row-level security isolation between users.

#### `005_client_privileges.test.sql`

Verifies the grants and revocations visible to browser-facing database roles.

### Phase 2

#### `006_app_role_privileges.test.sql`

Verifies the exact privilege surface granted to `fretvision_app`.

## Current verified totals

```text
Phase 1
Files: 5
Assertions: 138
Result: PASS

Phase 2
Files: 1
Assertions: 27
Result: PASS

Overall
Assertions: 165
Result: PASS
```

## Environment files

Real environment files are intentionally ignored by Git.

Examples committed to the repository:

```text
backend/.env.example
backend/.env.hosted.example
frontend/.env.example
frontend/.env.hosted.example
```

Local files that must not be committed include:

```text
backend/.env
frontend/.env.local
```

Before committing, verify ignored files:

```powershell
git status --short
git check-ignore backend/.env frontend/.env.local
```

## Git workflow

Create a commit:

```powershell
git add .
git commit -m "Describe the change"
```

Push `main`:

```powershell
git push -u origin main
```

The command below is invalid:

```powershell
git commit -u origin main
```

`-u origin main` belongs to `git push`, not `git commit`.

After the first successful upstream push, future pushes can normally use:

```powershell
git push
```

## Troubleshooting

### `supabase not found on PATH`

The project uses a local npm installation of the Supabase CLI.

Use:

```powershell
npx supabase status
```

or:

```powershell
.\node_modules\.bin\supabase.cmd status
```

Do not depend on a global Supabase installation.

### `psql is not recognized`

The validated PowerShell scripts automatically use `psql` inside the local Supabase PostgreSQL container when host `psql.exe` is not installed.

Verify the container client:

```powershell
docker exec -i supabase_db_FretVision `
  psql -U postgres -d postgres --version
```

### Permission denied while setting PostgreSQL logging parameters

The application-role bootstrap requires a PostgreSQL superuser-equivalent account because it creates a role and temporarily disables statement logging before transmitting the application-role password.

The local scripts automatically detect and use `supabase_admin`.

### `Stopped services: supabase_imgproxy...` or pooler stopped

These services are optional for the current schema and pgTAP tests.

The test harness verifies the PostgreSQL service directly rather than requiring every optional Supabase service.

### `pg_catalog.coalesce(...) does not exist`

`COALESCE` is SQL syntax and must not be schema-qualified.

Correct:

```sql
coalesce(sum(value), 0)
```

Incorrect:

```sql
pg_catalog.coalesce(sum(value), 0)
```

### pgTAP says fewer tests ran than planned

Do not place pgTAP assertions inside a savepoint that is later rolled back.

Rolling back the savepoint also rolls back pgTAP's internal counter. The lifecycle test uses isolated PL/pgSQL exception blocks instead.

## Current milestone

The database foundation is complete and verified.

Completed:

- Local Supabase setup
- PostgreSQL schema
- Catalog model
- User-owned practice model
- Lifecycle and integrity triggers
- Security-invoker views
- RLS policies
- Client grants
- Backend role bootstrap
- Least-privilege backend grants
- Seed data
- Windows reset workflow
- Database verification harness
- 165 passing pgTAP assertions
- Initial GitHub push

## Next development steps

The next milestone is application scaffolding:

1. Initialize the FastAPI backend.
2. Add backend database configuration using `fretvision_app`.
3. Initialize the Next.js TypeScript frontend.
4. Configure Supabase Auth in the frontend.
5. Add generated database types.
6. Implement session creation and lifecycle APIs.
7. Build the browser-side MediaPipe/OpenCV.js pipeline.
8. Add CI for migrations and database tests.
9. Connect the local workflow to the hosted Supabase development project after local validation remains green.

## Important development rules

- Do not commit real passwords, keys, or `.env` files.
- Do not place the `fretvision_app` password in migrations.
- Do not push migrations to the hosted Supabase project until they pass locally.
- Keep published catalog revisions immutable.
- Keep raw webcam frames on the client.
- Let FastAPI own multi-step business transactions.
- Preserve the exact RLS and least-privilege boundaries verified by the test suite.