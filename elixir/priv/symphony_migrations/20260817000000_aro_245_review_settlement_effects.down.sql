begin;

do $$
declare
  function_definition text;
begin
  if exists (
    select 1 from symphony_staging.effect_operations
    where effect_type in ('linear_issue_create', 'github_review_thread_resolve')
  ) then
    raise exception 'cannot remove ARO-245 effect types while settlement operations exist';
  end if;

  alter table symphony_staging.effect_operations
    drop constraint effect_operations_effect_type_check;

  alter table symphony_staging.effect_operations
    add constraint effect_operations_effect_type_check check (effect_type in (
      'linear_comment', 'github_comment', 'git_commit', 'git_push',
      'github_pr_create', 'github_pr_update', 'linear_state'
    ));

  select pg_catalog.pg_get_functiondef(
    'symphony_staging.begin_effect(text,text,text,text,uuid,bigint,uuid,uuid,uuid,integer)'::regprocedure
  ) into function_definition;

  function_definition := replace(
    function_definition,
    $needle$'github_pr_create', 'github_pr_update', 'linear_state',
    'linear_issue_create', 'github_review_thread_resolve'$needle$,
    $replacement$'github_pr_create', 'github_pr_update', 'linear_state'$replacement$
  );

  execute function_definition;
end
$$;

update symphony_staging.contract_versions
set contract_version = 1,
    migration_name = '20260805000000_aro_165_effect_ledger',
    installed_at = clock_timestamp()
where contract_name = 'effect-ledger';

commit;
