# GitLab user merge tool

This experimental codebase facilitates transparent merging of users in a self-hosted GitLab installation.
I was not able to find existing code for this problem, so I wrote my own (learning more about Ruby and GitLab in the process...).

Tested with GitLab 18.8.

## Description

* The tool works by making changes to the GitLab database.
  The merge is transparent at this level: if successful, no reference to ids of merged users remain in the database.

* This means that all aspects of duplicated users are preserved:
  - account information and preferences (with a specified conflict resolution, see below),
  - SSH keys, authentication tokens, etc.,
  - project and group memberships,
  - notification subscriptions (in discussions, issues, merge requests, etc.),
  - statistics and audit reports,
  - etc.

* External references to merged users will break.
  In particular, users will no longer be able to log in using their duplicate account name.
  This is not a problem in setups when users log in using an external provider (the most common cause of account duplication).

* URLs to personal projects of merged users remain valid due to GitLab's route redirect mechanism.
  In particular, no remotes in git projects have to be updated.

The below guide explains the workflow of using the tool.

## Stop GitLab

The tool should only be used on an instance of GitLab that has been shut down properly.
You can do this using `gitlab-ctl stop`.

Only the PostgreSQL service should be running: `gitlab-ctl start postgresql`.

Confirm this as follows:

```bash
# gitlab-ctl status
down: gitaly: 21s, normally up; run: log: (pid 2554) 1180592s
down: gitlab-kas: 365s, normally up; run: log: (pid 2553) 1180592s
down: gitlab-workhorse: 365s, normally up; run: log: (pid 2551) 1180592s
down: logrotate: 364s, normally up; run: log: (pid 2557) 1180592s
down: nginx: 364s, normally up; run: log: (pid 2556) 1180592s
run: postgresql: (pid 305386) 8s; run: log: (pid 2550) 1180592s
down: puma: 359s, normally up; run: log: (pid 2543) 1180592s
down: redis: 358s, normally up; run: log: (pid 2542) 1180592s
down: registry: 358s, normally up; run: log: (pid 2562) 1180592s
down: sidekiq: 327s, normally up; run: log: (pid 2544) 1180592s
```

## Make a database backup

Back your database up before running destructive parts of this codebase:

```bash
gitlab-rake gitlab:backup:db:create
```

On my installation, this takes about 2.2 minutes and creates a database backup `/var/opt/gitlab/backups/db/database.sql.gz` (**warning**: this appears to override this file if it exists).

To restore, you can use the following command (taking about 6.5 minutes for me):

```bash
zcat /var/opt/gitlab/backups/db/database.sql.gz | gitlab-psql -q
```

You might have to run the drop statements repeatedly to make sure all inherited constraints are dropped.

You must not restore from this image after starting GitLab up again.
Database backups in isolation are only good for restoration at their point in time.
(For example, file storage and repositories might get out of sync.)

## Working with the codebase in the GitLab Rails console

### Load the codebase

You can start the [GitLab Rails console](https://docs.gitlab.com/administration/operations/rails_console/) by running `gitlab-rails console`.
This console is an interactive Ruby shell that gives direct access to the internals of GitLab.
It sits right at the application logic level, below the admin user interface and above the database layer.

Clone this repository onto the machine running your GitLab instance.
Make sure that the user running the GitLab Rails console (`gitlab-rails console`) has read access to this codebase.
You can confirm this user by running `Etc.getpwuid` in the GitLab Rails console.
In my case, this is user `git`.
In the GitLab Rails console, you can then load this codebase as follows:

```ruby
load '<path to codebase>/gitlab_user_merge.rb'
```

The entire codebase is namespaced to module `GitlabUserMerge`.
All the high-level functionality is exposed via the class `GitlabUserMerge::Tool`.
Create an instance of this class for further use below:

```ruby
tool = GitlabUserMerge::Tool.new
```

**Note:**
If you edit and reload the codebase, make sure to run this line again.
Otherwise, `tool` will still be outdated.

### Set up working directory

The tool reads and produces various intermediate files as well as report files and directories.
Create a working directory that the GitLab Rails console user can create files in.
When we refer to files and directories below, it is relative to this directory.

Before running any functions from the codebase, change to this directory in the GitLab Rails console:

```ruby
Dir.chdir('<path to working directory>')
```

**Note**:
It does not seem possible to directly start the GitLab Rails console in a given directory.
It always starts in `/opt/gitlab/embedded/service/gitlab-rails`.

### Files read and written

The codebase exposes both low-level and high-level functions for analyzing and handling user merges.
The high-level functions read and write caching data and reports into certain files and directories.
These default to sensible names in the current working directory.
You can overwrite these by passing environment variables.
These are documented at the beginning of `gitlab_user_merge.rb`.
Alternatively, you can call a lower level functions and pass the path directly.

## Input: user mapping

The starting point for this tool is a *user mapping* specifying the user merge.
This maps *source* user id (merge source) to *target* user id (merge target).
All of these ids are required to be pairwise distinct.
You can handle merging of larger sets of users by iterated merging.

Provide the user mapping as a JSON file `user-mapping.json`.
For example:

```json
{
    "10395": 8245,
    "10363": 5302,
    "10291": 3797,
}
```

If you have access to Chalmers GitLab, here is a [script](https://git.chalmers.se/sattler/chalmers-gitlab-fixing/-/blob/main/duplicated_users.py) that produces this file by searching for users with shared external user id (for different providers):

```shell
./duplicated_users.py --json >user-mapping.json
```

## Column classification

The first complication is figuring out which database table columns refer to duplicated user ids.
For this, we produce a *column classification*.
Note that a column classification is only valid for the user mapping it was produced from.

### Workflow

1)  Produce a column classification:

    ```ruby
    tool.create_column_classification
    ```

    This will produce a file `column-classification.json` and a report `column-classification.txt`.
    It might take a while to run (about half a minute for me).

2)  Manually handle any table columns marked *unrecognized* in of the following ways:
    * Edit `column-classification.json`, moving them from *unrecognized* to *positive* or *negative* as appropriate.
    * Add them to the hard-coded cases in [lib/column_classification.rb](lib/column_classification.rb).
      Then re-run the column classification.

### Background (skippable)

Column classification is implemented in [`lib/column_classification.rb`](lib/column_classification.rb).

#### Positive criteria

* Foreign key relationship with parent `user.id`.
* Existence of a Rails model with `BelongsToReflection` with parent `user.id`.

#### Negative criteria

* The column is not an integer (or integer array) type.
* Foreign key relationship with a parent different from `user.id`.
* Rails models with `BelongsToReflection` exist and all have parent different from `user.id`.
* The column values do not fall into the range of user ids.
* (Stronger) the column values do not include any of the relevant user ids.

#### Complications

* Some columns are _polymorphic_. We detect this using two criteria:
  - polymorphic `BelongsToReflection` reflections,
  - matching _type_ column (for example, `members.source_id` has `members.source_type`).

  In that case, we scan rows for any entries with _type_ column set to `User`.
* Some columns types are arrays of integers (example: `issue_user_mentions.mentioned_user_ids`).
  For these, we look inside the array.
* Some columns lack explicit foreign key relationships because GitLab supports separate *Main* and *CI* databasses.

#### Hard-coded cases

Even taking all the above criteria into account, you will have to make a couple of manual decisions.
The following ones are currently hard-coded:

* positive array table columns (`TABLE_COLUMN_ARRAY_INCLUDE`):
  * `issue_user_mentions.mentioned_users_ids`
  * `merge_request_user_mentions mentioned_users_ids`
* positive ordinary table columns (`TABLE_COLUMN_INCLUDE`):
  * `group_type_ci_runners.creator_id`
  * `groups_visits.user_id`
  * `oauth_access_grants.resource_owner_id`
  * `project_authorizations_for_migration.user_id`
  * `projects_visits.user_id`
  * `user_audit_events.user_id`

## Checking JSON and text columns for references to duplicated users

This is an optional step that goes beyond the database schema.
The tool supports checking for:
* duplicated usernames and user ids as values and keys in JSON data (either a JSON column or a text column parsable as JSON),
* duplicated usernames contained in text column values.

### Workflow

1)  Run:

    ```ruby
    tool.check_text_and_json_columns
    ```

    This will take a while to run (about a minute for me).
    It will create the following reports with all the unique matches:
    * `columns-json-report.txt` (matches are given together with their key/index path in the JSON),
    * `columns-text-report.txt` (ignoring some excluded table columns, see background),
    * `columns-text-array-report.txt`.

    It will also create the following directories with the full entries (and the matching user ids and usernames as part of the filename):
    * `columns-json`,
    * `columns-text`.

2)  Decide if any found matches warrent manual attention and handle them accordingly.

### Background (skippable)

This is implemented in [`lib/text.rb`](lib/text.rb).

The set `TEXT_COLUMNS_EXCLUDE` contains text columns that I analysed and concluded need not to be touched.
We intentionally leave contents of notes and descriptions of merge requests, issues, etc., intact.
The parsing for usernames by Gitlab in order to create notification settings happens only when such a text is initially created.
These are already migrated properly by the tool as part of the usual workflow.
Namespace path or route references are also unproblematic.

## Handling conflicts

A *conflict* in a table with a unique index (or primary key) is a pair of a *source* row and a *target* row that differ in terms of the index columns only because of a user id column is a source user id in the source row and the corresponding target user id in the target row.
These conflicts need to be resolved in a systematic way before merging of users can proceed.

Typical conflicts involve tables concerned with user information: `users`, `user_details`, `user_preferences`.
For example, a duplicated user may have set a password in one of their accounts, but have an autogenerated password in their other account.
We want to handle these conflicts in a way that defaults to the most useful version.

### Workflow

1)  Run:

    ```ruby
    tool.report_column_conflicts
    ```

    This will take a while to run.
    It will create the following reports:
    * `column-conflicts-by-user-mapping.txt`
    * `column-conflicts-by-table-and-column.txt`

    Any entry with `resolution MISSING` denotes an unresolved conflict.
    Resolve these conflicts at table column level by choosing a resolution and adding it to the hash `RESOLUTIONS` in [`lib/resolution.rb`](lib/resolution.rb).
    Some example resolutions have already been made (with resulting actions highlighted the reports), but you should double-check the entire hash.

    Restart the GitLab Rails console and reload the codebase.
    You may go back to the beginning of this step to see how your conflicts resolve with your resolution decisions.

2)  Run:

    ```ruby
    tool.check_for_unresolved_conflicts
    ```

    to confirm that all conflicts have been resolved.

### Background (skippable)

Conflict detection is implemented in [`lib/uniqueness_check.rb`](lib/uniqueness_check.rb).
The resolution logic is implemented in [`lib/resolution.rb`](lib/resolution.rb).
Several strategies already implemented (taking a specified version, summing, maximum, preferring non-defaults defaults, chaining of strategies, custom strategy for passwords, etc.).

We can ignore conflicts in the tables `project_authorizations` and `user_highest_roles`.
These are caches and will be recalculated for the involved users later on.

## Transferring personal projects

Every user has a personal user namespace for projects.
We need to move personal projects of each source user over to personal projects of the corresponding target user.
This entails a URL change for these projects, but the old URLs remain valid because of GitLab's redirect route mechanism.
Users may see a warning when they pull or push using git, advising them to update their remote URL.

### Workflow

1)  Run:

    ```ruby
    tool.report_personal_projects
    ```

    This produces a report `personal-projects.txt` of all personal projects of source and target users.

2)  Run:

    ```ruby
    tool.check_personal_projects_for_conflict
    ```

    This will detect if any pairing of source and target user has a personal project with the same path.
    Usually, this happens when a duplicated user reuploads a repository.
    Deal with those cases manually (determining which repository supercedes and deleting the other one).

3)  **Only for this step**: have Redis running:

    ```bash
    gitlab-ctl start redis
    ```

    Run

    ```ruby
    tool.transfer_personal_projects
    ```

    to transfer the personal projects.

    Now stop Redis again:

    ```bash
    gitlab-ctl stop redis
    ```

4)  Run

    ```ruby
    tool.check_personal_projects_clear
    ```

    to confirm that no source users with personal projects remain.

### Background

This is implemented in [`lib/personal_projects.rb`](lib/personal_projects.rb).

## Perform the user merge

### Workflow

1)  Perform a dry-run user merge:

    ```ruby
    tool.perform_user_merge(perform: false)
    ```

    Double-check the destructive queries generated in `database-queries.txt`.

2)  If you wish, you can test these queries by performing an abortive transaction:

    ```ruby
    tool.perform_user_merge(perform: true, abort: true)
    ```

    This will run these queries in a transaction block before rolling it back.

3)  Perform the user merge merge:

    ```ruby
    tool.perform_user_merge(perform: true, abort: false)
    ```

4)  Perform a dry-run of deleting the source users:

    ```ruby
    tool.delete_source_users(perform: false)
    ```

    This checks that no traces of source users remain in the database.

5)  Perform the actual deletion of source users:

    ```ruby
    tool.delete_source_users(perform: true)
    ```

### Background

User merging involves two kinds of database updates:

* Merge conflict rows according to the configured resolutions (and deleting the source rows afterwards).
  - For columns involved in unique indexes (or primary keys), we cannot simply copy the column value from source to target.
    Currently, we hard-code the string table columns for which that is the case (`unique_table_columns` in `perform_conflict_resolution_for_conflict` in `lib/resolution.rb`).
    We workaround the problem by prefixing the source value with a unique string to free it up for the target value.

* Replace user ids in the database according to the user mapping.
  - We of course ignore the column `users.id`.
  - We also ignore in the column and the column `owner_id` in table `namespaces` whenever column `type` has value `User`.
    These are personal namespaces, in one-to-one correspondence with users.
    Because the table `namespaces` is polymorphic, this one-to-one relationship is not made explicit in the database schema (though it is in the application logic).
    Replacing owners of personal namespaces would produce duplicate personal namespaces.

    TODO:
    Implement database-level merging of personal namespaces.
    Might not be worthwhile: most fields of personal namespaces appear unused.
    The only interesting fields appear to be:
    + `name` (taken from table `users`?)
    + `created_at`
    * `updated_at`
    + `request_access_enabled`
    + perhaps `organization_id`

## Start GitLab

Finally, start GitLab up again:

```bash
gitlab-ctl start
```
