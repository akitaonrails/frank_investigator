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

ActiveRecord::Schema[8.1].define(version: 2026_03_11_191000) do
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
    t.text "body_text"
    t.string "content_fingerprint"
    t.datetime "created_at", null: false
    t.text "excerpt"
    t.string "fetch_status", default: "pending", null: false
    t.datetime "fetched_at"
    t.string "host", null: false
    t.string "independence_group"
    t.string "main_content_path"
    t.json "metadata_json", default: {}, null: false
    t.string "normalized_url", null: false
    t.datetime "published_at"
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
    t.decimal "authority_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "checkability_status", default: "pending", null: false
    t.integer "claim_id", null: false
    t.decimal "confidence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.decimal "conflict_score", precision: 5, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.decimal "independence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.integer "investigation_id", null: false
    t.text "missing_evidence_summary"
    t.text "reason_summary"
    t.decimal "timeliness_score", precision: 5, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.string "verdict", default: "pending", null: false
    t.index ["checkability_status"], name: "index_claim_assessments_on_checkability_status"
    t.index ["claim_id"], name: "index_claim_assessments_on_claim_id"
    t.index ["investigation_id", "claim_id"], name: "index_claim_assessments_on_investigation_id_and_claim_id", unique: true
    t.index ["investigation_id"], name: "index_claim_assessments_on_investigation_id"
    t.index ["verdict"], name: "index_claim_assessments_on_verdict"
  end

  create_table "claims", force: :cascade do |t|
    t.string "canonical_fingerprint", null: false
    t.text "canonical_text", null: false
    t.string "checkability_status", default: "pending", null: false
    t.string "claim_kind", default: "statement", null: false
    t.datetime "created_at", null: false
    t.json "entities_json", default: {}, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.string "time_scope"
    t.string "topic"
    t.datetime "updated_at", null: false
    t.index ["canonical_fingerprint"], name: "index_claims_on_canonical_fingerprint", unique: true
    t.index ["checkability_status"], name: "index_claims_on_checkability_status"
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

  create_table "investigations", force: :cascade do |t|
    t.datetime "analysis_completed_at"
    t.string "checkability_status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.decimal "headline_bait_score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "normalized_url", null: false
    t.decimal "overall_confidence_score", precision: 5, scale: 2, default: "0.0", null: false
    t.integer "root_article_id"
    t.string "status", default: "queued", null: false
    t.string "submitted_url", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.index ["checkability_status"], name: "index_investigations_on_checkability_status"
    t.index ["normalized_url"], name: "index_investigations_on_normalized_url", unique: true
    t.index ["root_article_id"], name: "index_investigations_on_root_article_id"
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

  add_foreign_key "article_claims", "articles"
  add_foreign_key "article_claims", "claims"
  add_foreign_key "article_links", "articles", column: "source_article_id"
  add_foreign_key "article_links", "articles", column: "target_article_id"
  add_foreign_key "claim_assessments", "claims"
  add_foreign_key "claim_assessments", "investigations"
  add_foreign_key "evidence_items", "articles"
  add_foreign_key "evidence_items", "claim_assessments"
  add_foreign_key "html_snapshots", "articles"
  add_foreign_key "investigations", "articles", column: "root_article_id"
  add_foreign_key "llm_interactions", "claim_assessments"
  add_foreign_key "llm_interactions", "investigations"
  add_foreign_key "pipeline_steps", "investigations"
end
