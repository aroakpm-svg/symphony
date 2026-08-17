begin;
delete from symphony_staging.effect_operations where effect_type = 'review_settlement_receipt';
-- Rollback is intentionally fail-closed; reinstall the preceding ARO-245 migrations.
delete from symphony_staging.contract_versions
where migration_name = '20260817000002_aro_245_settlement_receipt';
commit;
