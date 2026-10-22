# GitHub setup audit — 2026-10-22

Repository: [tmaeder/queer-guide-hub](https://github.com/tmaeder/queer-guide-hub).
Scope: this repository, its GitHub settings, workflow configuration, and dependency coverage. Account-wide settings and other repositories were not audited.

## Settings applied on GitHub

The owner approved this targeted pass in chat. `main` now requires branches to be up to date and review conversations to be resolved. The settings were read back after the update: all 12 required status checks and their GitHub App bindings, admin enforcement, review requirements, force-push/deletion restrictions, and other branch-protection fields were preserved.

To reverse these two changes, disable **Require branches to be up to date before merging** and **Require conversation resolution before merging** in the existing `main` protection rule. Keep its other settings intact.

Existing strengths: automatic deletion of merged branches, default read-only workflow token permissions, Dependabot security updates, secret scanning and push protection. The initial API audit returned no open CodeQL or secret-scanning alerts. These are point-in-time results, not a claim that the application has no vulnerabilities.

## Changes proposed in this PR

- Pin all 168 external Action references across 47 workflows and the Playwright composite action to full commit SHAs resolved and checked through the upstream repositories' Git APIs. Keep the existing version/branch as a comment. This fixes the selected Action code; it does not freeze runner images, packages downloaded at runtime, or every transitive dependency.
- Schedule grouped weekly Actions updates. Extend npm Dependabot coverage from 10 to all 18 tracked package directories, adding infrastructure, the redirect SDK, person-db, and five worker packages. Preserve existing major-version exclusions.
- Set explicit timeouts on 33 previously unbounded jobs; all 70 runner jobs now have a timeout. Retain existing measured budgets.
- Cancel superseded runs of CodeQL, ESLint reporting, bundle checks, and extension CI. Serialize worker deployments and stop cancelling active mirror deployments when another run starts.
- Use `.nvmrc` for the ESLint scanning job, replacing its Node 20 setting with the project's Node 22 version.
- Fix `Critical paths` change detection on `merge_group`: fetch and compare against the event's base SHA instead of querying a nonexistent PR number. Preserve full-app, migration-only, and irrelevant-diff scope decisions. Invalid base SHAs, failed fetches, and failed PR API calls fail the job.
- Update person-db's transitive Nano ID lockfile entry from 3.3.16 to 3.3.20 after npm audit reported [GHSA-2v37-7h3g-55p8](https://github.com/advisories/GHSA-2v37-7h3g-55p8).

The initial GitHub alert query reported three DOMPurify advisories against 3.4.16. Current `main` already contains DOMPurify 3.4.17 from [PR #4560](https://github.com/tmaeder/queer-guide-hub/pull/4560); all three advisories name 3.4.17 as their first fixed version. This pass verifies that fix rather than duplicating it. GitHub's alert listing had not yet reflected the patched lockfile when queried.

## Validation

- Actionlint 1.7.12: all 47 workflows pass. Optional ShellCheck/Pyflakes integrations were disabled; this is workflow validation, not a full shell/Python audit.
- Configuration assertions: all 18 npm package directories covered exactly once, all 168 external Actions pinned, all 70 runner jobs bounded.
- Semantic comparison against the base: workflow triggers, job names, permissions, existing timeout values, and unrelated configuration preserved.
- Nine change-detection regression scenarios: app/migration/docs diffs on both PR and merge-group events; missing and unavailable merge-group bases; failed PR API call. Merge-group tests use real shallow Git clones and fetches against disposable local repositories.
- person-db: clean lockfile installation, TypeScript and Vite production build; npm audit checked after the Nano ID update. The build retains its existing large-chunk warning.
- Staged secret guard and `git diff --check` run before commit.

The complete application suite and GitHub-hosted event execution remain subject to PR CI. Changes to scheduled and deployment workflows become active when merged; this pass does not merge or deploy the PR.

## Follow-up decisions

A broader CI redesign should measure runner time and distinguish production health checks from change-specific tests before changing gates. Existing incidents document why path filters, deployment cancellation, and remote schema checks need care. The current pass preserves those gates and the root toolchain's compatibility exclusions.

GitHub references: [secure use of Actions](https://docs.github.com/en/actions/reference/security/secure-use), [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
