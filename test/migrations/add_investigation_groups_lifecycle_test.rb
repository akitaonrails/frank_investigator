require "test_helper"
require "tmpdir"
require "fileutils"
require Rails.root.join("db/migrate/20260717000000_add_investigation_groups")

class AddInvestigationGroupsLifecycleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @original_config = ActiveRecord::Base.connection_db_config.configuration_hash
    @database_path = File.join(Dir.mktmpdir("frank-group-migration-"), "lifecycle.sqlite3")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @database_path)
    ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = ON")
    create_pre_feature_schema
    create_pre_feature_history
  end

  teardown do
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    ActiveRecord::Base.establish_connection(@original_config)
    ActiveRecord::Base.connection.schema_cache.clear!
    FileUtils.rm_rf(File.dirname(@database_path)) if @database_path
  end

  test "up rollback and re-up preserve historical evidence and a deterministic valid schema" do
    migration.migrate(:up)
    assert_feature_schema
    assert_preserved_history
    first_schema = feature_schema_signature

    migration.migrate(:down)
    refute @connection.data_source_exists?("investigation_groups")
    refute @connection.data_source_exists?("investigation_group_evidence_sources")
    refute @connection.data_source_exists?("investigation_submission_locks")
    refute_includes @connection.columns("investigations").map(&:name), "investigation_group_id"
    refute_includes @connection.columns("investigations").map(&:name), "kickoff_due_at"
    refute_includes @connection.columns("articles").map(&:name), "content_generation"
    assert_preserved_history

    migration.migrate(:up)
    assert_feature_schema
    assert_preserved_history
    assert_equal first_schema, feature_schema_signature
    assert_empty @connection.execute("PRAGMA foreign_key_check")
  end

  private

  def migration = AddInvestigationGroups.new
  def connection = ActiveRecord::Base.connection

  def create_pre_feature_schema
    @connection = connection
    @connection.create_table(:articles) { |t| t.string :url; t.string :normalized_url; t.string :host }
    @connection.add_index(:articles, :normalized_url, unique: true)
    @connection.create_table(:investigations) { |t| t.string :submitted_url; t.string :normalized_url; t.references :root_article, foreign_key: { to_table: :articles } }
    @connection.add_index(:investigations, :normalized_url, unique: true)
    @connection.create_table(:claim_assessments) { |t| t.references :investigation, null: false, foreign_key: true; t.string :verdict }
    @connection.create_table(:evidence_items) { |t| t.references :claim_assessment, null: false, foreign_key: true; t.string :source_url; t.string :stance; t.float :confidence_score }
  end

  def create_pre_feature_history
    @connection.execute("INSERT INTO articles (id, url, normalized_url, host) VALUES (1, 'https://example.test/a', 'https://example.test/a', 'example.test')")
    @connection.execute("INSERT INTO investigations (id, submitted_url, normalized_url, root_article_id) VALUES (1, 'https://example.test/a', 'https://example.test/a', 1)")
    @connection.execute("INSERT INTO claim_assessments (id, investigation_id, verdict) VALUES (1, 1, 'supported')")
    @connection.execute("INSERT INTO evidence_items (id, claim_assessment_id, source_url, stance, confidence_score) VALUES (1, 1, 'https://archive.test/first', 'supports', 0.8)")
    @connection.execute("INSERT INTO evidence_items (id, claim_assessment_id, source_url, stance, confidence_score) VALUES (2, 1, 'https://archive.test/second', 'disputes', 0.4)")
  end

  def assert_feature_schema
    assert @connection.data_source_exists?("investigation_groups")
    assert @connection.data_source_exists?("investigation_group_evidence_sources")
    assert @connection.data_source_exists?("investigation_submission_locks")
    assert_includes @connection.columns("articles").map(&:name), "content_generation"
    %w[investigation_group_id evidence_revision_assessed reconciliation_token evidence_reconciliation_retry_due_at reconciliation_enrichment_pending_revision legacy_enrichment_token legacy_enrichment_retry_due_at kickoff_due_at kickoff_delivery_token kickoff_delivery_expires_at kickoff_delivered_at].each do |column|
      assert_includes @connection.columns("investigations").map(&:name), column
    end
    %w[fetch_token fetch_lease_expires_at fetch_retry_due_at fetch_delivery_token fetch_attempts_generation terminal_at].each do |column|
      assert_includes @connection.columns("investigation_group_evidence_sources").map(&:name), column
    end
    main_indexes = @connection.indexes("investigation_groups").select { |index| index.columns == [ "main_investigation_id" ] }
    assert_equal 1, main_indexes.size
    assert_equal "idx_investigation_groups_main_unique", main_indexes.first.name
    assert main_indexes.first.unique
    assert @connection.indexes("investigation_group_evidence_sources").any? { |index| index.name == "idx_group_evidence_source_unique" && index.unique }
    lock_columns = @connection.columns("investigation_submission_locks")
    key_column = lock_columns.find { |column| column.name == "key" }
    version_column = lock_columns.find { |column| column.name == "version" }
    refute key_column.null
    refute version_column.null
    assert_equal 0, version_column.default.to_i
    assert @connection.indexes("investigation_submission_locks").any? { |index| index.columns == [ "key" ] && index.unique }
    assert @connection.indexes("investigations").any? { |index| index.columns == [ "kickoff_due_at" ] }
    assert @connection.foreign_keys("investigation_groups").any? { |key| key.to_table == "investigations" }
    assert @connection.foreign_keys("investigation_group_evidence_sources").any? { |key| key.to_table == "articles" }
  end

  def assert_preserved_history
    assert_equal [ [ 1, "https://archive.test/first", "supports" ], [ 2, "https://archive.test/second", "disputes" ] ],
      @connection.select_rows("SELECT id, source_url, stance FROM evidence_items ORDER BY id")
  end

  def feature_schema_signature
    %w[articles investigations investigation_groups investigation_group_evidence_sources investigation_submission_locks].to_h do |table|
      [ table, [ @connection.columns(table).map { |column| [ column.name, column.sql_type, column.default, column.null ] }, @connection.indexes(table).map { |index| [ index.name, index.columns, index.unique ] }.sort ] ]
    end
  end
end
