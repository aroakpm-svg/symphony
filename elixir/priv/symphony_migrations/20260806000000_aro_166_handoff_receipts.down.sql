begin;

delete from symphony_staging.contract_versions
where contract_name = 'handoff-receipts';

drop trigger if exists grant_handoff_receipt_api_to_node_login
  on symphony_staging.node_login_principals;
drop function if exists symphony_staging.grant_handoff_receipt_api_to_node_login();
drop function if exists symphony_staging.latest_handoff_receipt(text, uuid, bigint, uuid, uuid);
drop function if exists symphony_staging.append_handoff_receipt(
  text, uuid, bigint, uuid, uuid, text, text, text, text, text, bigint, jsonb
);
drop index if exists symphony_staging.handoff_receipts_latest_lookup_idx;
drop table if exists symphony_staging.handoff_receipts;

commit;
