begin;

delete from symphony_staging.contract_versions where contract_name = 'handoff-receipt';

drop trigger if exists grant_handoff_api_to_node_login on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_handoff_api_to_node_login();
drop function if exists symphony_staging.handoff_receipt_ready();
drop function if exists symphony_staging.handoff_effect_statuses(text, uuid, bigint, uuid, uuid, text[]);
drop function if exists symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.append_handoff_receipt(text, uuid, bigint, uuid, uuid, integer, text, text, text, text, integer, text, text[], text[], jsonb, text[]);
drop function if exists symphony_staging.validate_handoff_tests(jsonb);
drop function if exists symphony_staging.validate_handoff_steps(text[], text[]);
drop table if exists symphony_staging.handoff_receipts;

commit;
