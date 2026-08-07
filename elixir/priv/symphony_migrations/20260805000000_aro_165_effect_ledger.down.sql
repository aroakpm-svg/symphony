begin;

delete from symphony_staging.contract_versions
where contract_name = 'effect-ledger';

drop trigger if exists grant_effect_api_to_node_login
  on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_effect_api_to_node_login();
drop function if exists symphony_staging.reconcile_effect(text, text, uuid, text, uuid, bigint, uuid, uuid, text, jsonb);
drop function if exists symphony_staging.relinquish_effect(text, text, uuid);
drop function if exists symphony_staging.effect_ledger_ready();
drop function if exists symphony_staging.finish_effect(text, text, uuid, text, jsonb, text);
drop function if exists symphony_staging.begin_effect(text, text, text, text, uuid, bigint, uuid, uuid, uuid, integer);
drop table if exists symphony_staging.effect_operations;

commit;
