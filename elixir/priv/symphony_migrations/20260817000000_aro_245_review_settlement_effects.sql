begin;

do $$
declare
  constraint_name text;
  function_definition text;
  updated_definition text;
begin
  select constraints.conname into constraint_name
  from pg_catalog.pg_constraint constraints
  where constraints.conrelid = 'symphony_staging.effect_operations'::regclass
    and constraints.contype = 'c'
    and pg_catalog.pg_get_constraintdef(constraints.oid) like '%effect_type%';

  if constraint_name is null then
    raise exception 'effect operation type constraint is unavailable';
  end if;

  execute format('alter table symphony_staging.effect_operations drop constraint %I', constraint_name);

  alter table symphony_staging.effect_operations
    add constraint effect_operations_effect_type_check check (effect_type in (
      'linear_comment', 'github_comment', 'git_commit', 'git_push',
      'github_pr_create', 'github_pr_update', 'linear_state',
      'linear_issue_create', 'github_review_thread_resolve'
    ));

  select pg_catalog.pg_get_functiondef(
    'symphony_staging.begin_effect(text,text,text,text,uuid,bigint,uuid,uuid,uuid,integer)'::regprocedure
  ) into function_definition;

  updated_definition := replace(
    function_definition,
    $needle$'github_pr_create', 'github_pr_update', 'linear_state'$needle$,
    $replacement$'github_pr_create', 'github_pr_update', 'linear_state',
    'linear_issue_create', 'github_review_thread_resolve'$replacement$
  );

  if updated_definition = function_definition then
    raise exception 'begin_effect allowlist shape is incompatible with ARO-245 migration';
  end if;

  execute updated_definition;
end
$$;

insert into symphony_staging.contract_versions (
  contract_name, contract_version, migration_name
) values (
  'effect-ledger', 2, '20260817000000_aro_245_review_settlement_effects'
)
on conflict (contract_name) do update set
  contract_version = excluded.contract_version,
  migration_name = excluded.migration_name,
  installed_at = clock_timestamp();

commit;
