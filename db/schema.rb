# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_12_190000) do
  create_table "article_claims", force: :cascade do |t|
    t.integer "article_id", null: false
    t.integer "claim_id", null: false
    t.datetime "created_at", null: false
    t.decimal "importance_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "role", default: "body", null: false
    t.string "stance", default: "repeats", null: false
    t.text "surface_text", null: false
    t.boolean "title_related", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["article_id", "claim_id", "role"], name: "index_article_claims_on_article_id_and_claim_id_and_role", unique: true
    t.index ["article_id"], name: "index_article_claims_on_article_id"
    t.index ["claim_id"], name: "index_article_claims_on_claim_id"
  end

  create_table "article_links", force: :cascade do |t|
    t.string "anchor_text"
    t.text "context_excerpt"
    t.datetime "created_at", null: false
    t.integer "depth", default: 0, null: false
    t.string "follow_status", default: "pending", null: false
    t.string "href", null: false
    t.integer "position", default: 0, null: false
    t.integer "source_article_id", null: false
    t.integer "target_article_id", null: false
    t.datetime "updated_at", null: false
    t.index ["follow_status"], name: "index_article_links_on_follow_status"
    t.index ["source_article_id", "href"], name: "index_article_links_on_source_article_id_and_href", unique: true
    t.index ["source_article_id"], name: "index_article_links_on_source_article_id"
    t.index ["target_article_id"], name: "index_article_links_on_target_article_id"
  end

  create_table "articles", force: :cascade do |t|
    t.decimal "authority_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "authority_tier", default: "unknown", null: false
    t.boolean "body_changed_since_assessment", default: false, null: false
    t.string "body_fingerprint"
    t.text "body_text"
    t.string "content_fingerprint"
    t.datetime "created_at", null: false
    t.text "excerpt"
    t.string "fetch_status", default: "pending", null: false
    t.datetime "fetched_at"
    t.decimal "headline_divergence_score", precision: 5, scale: 2
    t.string "host", null: false
    t.string "independence_group"
    t.string "main_content_path"
    t.json "metadata_json", default: {}, null: false
    t.string "normalized_url", null: false
    t.datetime "published_at"
    t.string "rejection_reason"
    t.string "source_kind", default: "unknown", null: false
    t.string "source_role", default: "unknown", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["authority_tier"], name: "index_articles_on_authority_tier"
    t.index ["fetch_status"], name: "index_articles_on_fetch_status"
    t.index ["host"], name: "index_articles_on_host"
    t.index ["independence_group"], name: "index_articles_on_independence_group"
    t.index ["normalized_url"], name: "index_articles_on_normalized_url", unique: true
    t.index ["source_kind"], name: "index_articles_on_source_kind"
    t.index ["source_role"], name: "index_articles_on_source_role"
  end

  create_table "claim_assessments", force: :cascade do |t|
    t.datetime "assessed_at"
    t.decimal "authority_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "checkability_status", default: "pending", null: false
    t.decimal "citation_depth_score", precision: 5, scale: 2, default: "1.0", null: false
    t.integer "claim_id", null: false
    t.decimal "confidence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.decimal "conflict_score", precision: 5, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.text "disagreement_details"
    t.decimal "independence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.integer "investigation_id", null: false
    t.text "missing_evidence_summary"
    t.boolean "primary_vetoed", default: false, null: false
    t.text "reason_summary"
    t.integer "reassessment_count", default: 0, null: false
    t.datetime "stale_at"
    t.string "staleness_reason"
    t.decimal "timeliness_score", precision: 5, scale: 2, default: "0.0", null: false
    t.boolean "unanimous", default: false, null: false
    t.boolean "unsubstantiated_viral", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "verdict", default: "pending", null: false
    t.index ["assessed_at"], name: "index_claim_assessments_on_assessed_at"
    t.index ["checkability_status"], name: "index_claim_assessments_on_checkability_status"
    t.index ["claim_id"], name: "index_claim_assessments_on_claim_id"
    t.index ["investigation_id", "claim_id"], name: "index_claim_assessments_on_investigation_id_and_claim_id", unique: true
    t.index ["investigation_id"], name: "index_claim_assessments_on_investigation_id"
    t.index ["stale_at"], name: "index_claim_assessments_on_stale_at"
    t.index ["verdict"], name: "index_claim_assessments_on_verdict"
  end

  create_table "claims", force: :cascade do |t|
    t.string "canonical_fingerprint", null: false
    t.text "canonical_form"
    t.integer "canonical_parent_id"
    t.text "canonical_text", null: false
    t.integer "canonicalization_version", default: 0, null: false
    t.string "checkability_status", default: "pending", null: false
    t.string "claim_kind", default: "statement", null: false
    t.date "claim_timestamp_end"
    t.date "claim_timestamp_start"
    t.datetime "created_at", null: false
    t.json "entities_json", default: {}, null: false
    t.integer "evidence_article_count", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.string "semantic_key"
    t.string "time_scope"
    t.string "topic"
    t.datetime "updated_at", null: false
    t.string "variant_of_fingerprint"
    t.index ["canonical_fingerprint"], name: "index_claims_on_canonical_fingerprint", unique: true
    t.index ["canonical_parent_id"], name: "index_claims_on_canonical_parent_id"
    t.index ["checkability_status"], name: "index_claims_on_checkability_status"
    t.index ["semantic_key"], name: "index_claims_on_semantic_key"
    t.index ["variant_of_fingerprint"], name: "index_claims_on_variant_of_fingerprint"
  end

  create_table "error_reports", force: :cascade do |t|
    t.text "backtrace"
    t.json "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "error_class", null: false
    t.string "fingerprint", null: false
    t.datetime "first_occurred_at", null: false
    t.datetime "last_occurred_at", null: false
    t.text "message", null: false
    t.integer "occurrences_count", default: 1, null: false
    t.string "severity", default: "error", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["fingerprint"], name: "index_error_reports_on_fingerprint", unique: true
    t.index ["last_occurred_at"], name: "index_error_reports_on_last_occurred_at"
    t.index ["severity"], name: "index_error_reports_on_severity"
  end

  create_table "evidence_items", force: :cascade do |t|
    t.integer "article_id"
    t.decimal "authority_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "citation_locator"
    t.integer "claim_assessment_id", null: false
    t.string "content_fingerprint"
    t.datetime "created_at", null: false
    t.text "excerpt"
    t.string "independence_group"
    t.datetime "published_at"
    t.decimal "relevance_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "source_kind"
    t.string "source_type", default: "article", null: false
    t.string "source_url", null: false
    t.string "stance", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_evidence_items_on_article_id"
    t.index ["claim_assessment_id"], name: "index_evidence_items_on_claim_assessment_id"
    t.index ["content_fingerprint"], name: "index_evidence_items_on_content_fingerprint"
    t.index ["source_kind"], name: "index_evidence_items_on_source_kind"
    t.index ["source_type"], name: "index_evidence_items_on_source_type"
  end

  create_table "html_snapshots", force: :cascade do |t|
    t.integer "article_id", null: false
    t.datetime "captured_at", null: false
    t.binary "compressed_html", null: false
    t.string "content_fingerprint", null: false
    t.datetime "created_at", null: false
    t.string "fetch_url", null: false
    t.integer "original_size", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_html_snapshots_on_article_id"
    t.index ["content_fingerprint"], name: "index_html_snapshots_on_content_fingerprint", unique: true
  end

  create_table "investigation_embeddings", force: :cascade do |t|
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.integer "dimensions", null: false
    t.text "embedding_json"
    t.string "error_class"
    t.text "error_message"
    t.datetime "indexed_at"
    t.integer "investigation_id", null: false
    t.string "model_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["content_digest"], name: "index_investigation_embeddings_on_content_digest"
    t.index ["investigation_id"], name: "index_investigation_embeddings_on_investigation_id", unique: true
    t.index ["status"], name: "index_investigation_embeddings_on_status"
  end

  create_table "investigations", force: :cascade do |t|
    t.datetime "analysis_completed_at"
    t.json "authority_laundering"
    t.string "checkability_status", default: "pending", null: false
    t.json "contextual_gaps"
    t.json "coordinated_narrative"
    t.datetime "created_at", null: false
    t.json "emotional_manipulation"
    t.json "event_context"
    t.decimal "headline_bait_score", precision: 5, scale: 2, default: "0.0", null: false
    t.text "honest_headline"
    t.json "llm_summary"
    t.string "normalized_url", null: false
    t.decimal "overall_confidence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.json "rhetorical_analysis"
    t.integer "root_article_id"
    t.json "selective_quotation"
    t.string "slug"
    t.json "source_misrepresentation"
    t.json "statistical_deception"
    t.string "status", default: "queued", null: false
    t.string "submitted_url", null: false
    t.text "summary"
    t.json "temporal_manipulation"
    t.datetime "updated_at", null: false
    t.index ["checkability_status"], name: "index_investigations_on_checkability_status"
    t.index ["normalized_url"], name: "index_investigations_on_normalized_url", unique: true
    t.index ["root_article_id"], name: "index_investigations_on_root_article_id"
    t.index ["slug"], name: "index_investigations_on_slug", unique: true
    t.index ["status"], name: "index_investigations_on_status"
  end

  create_table "llm_interactions", force: :cascade do |t|
    t.integer "claim_assessment_id"
    t.integer "completion_tokens"
    t.decimal "cost_usd", precision: 8, scale: 6
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_message"
    t.string "evidence_packet_fingerprint"
    t.string "interaction_type", default: "assessment", null: false
    t.integer "investigation_id", null: false
    t.integer "latency_ms"
    t.string "model_id", null: false
    t.text "prompt_text", null: false
    t.integer "prompt_tokens"
    t.json "response_json", default: {}
    t.text "response_text"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["claim_assessment_id"], name: "index_llm_interactions_on_claim_assessment_id"
    t.index ["evidence_packet_fingerprint", "model_id"], name: "idx_llm_interactions_cache_key"
    t.index ["interaction_type"], name: "index_llm_interactions_on_interaction_type"
    t.index ["investigation_id"], name: "index_llm_interactions_on_investigation_id"
    t.index ["model_id"], name: "index_llm_interactions_on_model_id"
  end

  create_table "media_ownership_groups", force: :cascade do |t|
    t.string "country"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.json "owned_hosts", default: [], null: false
    t.json "owned_independence_groups", default: [], null: false
    t.string "parent_company"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_media_ownership_groups_on_name", unique: true
  end

  create_table "pipeline_steps", force: :cascade do |t|
    t.integer "attempts_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_message"
    t.datetime "finished_at"
    t.integer "investigation_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.json "result_json", default: {}, null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["investigation_id", "name"], name: "index_pipeline_steps_on_investigation_id_and_name", unique: true
    t.index ["investigation_id"], name: "index_pipeline_steps_on_investigation_id"
    t.index ["status"], name: "index_pipeline_steps_on_status"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "verdict_snapshots", force: :cascade do |t|
    t.integer "claim_assessment_id", null: false
    t.decimal "confidence_score", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.json "evidence_content_hashes", default: {}, null: false
    t.integer "evidence_count", default: 0, null: false
    t.json "evidence_snapshot", default: [], null: false
    t.decimal "previous_confidence_score", precision: 5, scale: 2
    t.string "previous_verdict"
    t.text "reason_summary"
    t.string "trigger", null: false
    t.string "triggered_by"
    t.string "verdict", null: false
    t.index ["claim_assessment_id", "created_at"], name: "index_verdict_snapshots_on_claim_assessment_id_and_created_at"
    t.index ["claim_assessment_id"], name: "index_verdict_snapshots_on_claim_assessment_id"
  end

  add_foreign_key "article_claims", "articles"
  add_foreign_key "article_claims", "claims"
  add_foreign_key "article_links", "articles", column: "source_article_id"
  add_foreign_key "article_links", "articles", column: "target_article_id"
  add_foreign_key "claim_assessments", "claims"
  add_foreign_key "claim_assessments", "investigations"
  add_foreign_key "claims", "claims", column: "canonical_parent_id"
  add_foreign_key "evidence_items", "articles"
  add_foreign_key "evidence_items", "claim_assessments"
  add_foreign_key "html_snapshots", "articles"
  add_foreign_key "investigation_embeddings", "investigations"
  add_foreign_key "investigations", "articles", column: "root_article_id"
  add_foreign_key "llm_interactions", "claim_assessments"
  add_foreign_key "llm_interactions", "investigations"
  add_foreign_key "pipeline_steps", "investigations"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "verdict_snapshots", "claim_assessments"
end
