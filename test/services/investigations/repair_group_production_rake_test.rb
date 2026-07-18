require "test_helper"
require "stringio"
require "rake"
require "shellwords"

class Investigations::RepairGroupProductionRakeTest < ActiveSupport::TestCase
  SLUGS = %w[6499ca77e7 7138b9192d 49b57632a6 be37d8f156 c8c1b8e3bc].freeze
  WHITE_HOUSE_URL = "https://www.whitehouse.gov/election-integrity/"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("frank:repair_group")
    clear_enqueued_jobs
    @investigations = SLUGS.each_with_index.map { |slug, index| completed_investigation(slug, index, rejected: index == 1) }
    @white_house = Article.create!(url: WHITE_HOUSE_URL, normalized_url: WHITE_HOUSE_URL,
      host: "www.whitehouse.gov", fetch_status: :pending, authority_tier: :secondary,
      source_role: :official_position, source_kind: :government_record)
    clear_enqueued_jobs
  end

  teardown { clear_enqueued_jobs }

  test "five production slugs rake dry apply and no-op replay preserve roots and reuse White House evidence" do
    before = snapshot
    preserved_before = preserved_snapshot
    dry_output = invoke_repair
    assert_predicate dry_output, :present?, "rake dry output was empty"
    assert_match(/\{/, dry_output)
    dry = JSON.parse(dry_output[/\{.*\}/m])
    assert_equal before, snapshot
    assert_equal [], enqueued_jobs
    assert_equal SLUGS.sort, dry.fetch("members").map { |member| member.fetch("slug") }.sort
    assert_equal [ WHITE_HOUSE_URL ], dry.fetch("actions").fetch("fetch")
    refute dry.key?("committed_intents")
    instruction = dry_output.lines.find { |line| line.include?("Apply this exact projection:") }
    assert_equal "Dry run only; no records, jobs, or fetch resets were created. Apply this exact projection: MAIN_SLUG=#{SLUGS.first} NEWS_SLUGS=#{SLUGS.drop(1).join(",")} EVIDENCE_URLS=#{WHITE_HOUSE_URL} APPLY=1 DECISION_AT=#{dry.fetch("decision_at")} EXPECTED_DIGEST=#{dry.fetch("action_digest")} bin/rails frank:repair_group\n", instruction
    command = instruction.delete_prefix("Dry run only; no records, jobs, or fetch resets were created. Apply this exact projection: ").strip
    assert_equal [
      "MAIN_SLUG=#{SLUGS.first}", "NEWS_SLUGS=#{SLUGS.drop(1).join(",")}", "EVIDENCE_URLS=#{WHITE_HOUSE_URL}",
      "APPLY=1", "DECISION_AT=#{dry.fetch("decision_at")}", "EXPECTED_DIGEST=#{dry.fetch("action_digest")}",
      "bin/rails", "frank:repair_group"
    ], Shellwords.shellsplit(command)

    assert_raises(SystemExit) { invoke_repair("APPLY" => "1", "DECISION_AT" => dry.fetch("decision_at"), "EXPECTED_DIGEST" => "0" * 64) }
    assert_equal before, snapshot

    applied = JSON.parse(invoke_repair("APPLY" => "1", "DECISION_AT" => dry.fetch("decision_at"), "EXPECTED_DIGEST" => dry.fetch("action_digest"))[/\{.*\}/m])
    group = @investigations.first.reload.owned_group
    assert_equal @investigations.first.id, group.main_investigation_id
    assert_equal SLUGS.sort, group.investigations.pluck(:slug).sort
    assert_equal 1, group.evidence_sources.count
    assert_equal @white_house.id, group.evidence_sources.first.article_id
    assert_nil Investigation.find_by(normalized_url: WHITE_HOUSE_URL)
    assert_equal "secondary", @white_house.reload.authority_tier
    assert_equal "official_position", @white_house.source_role
    assert_equal dry.fetch("action_digest"), applied.fetch("action_digest")
    assert_equal preserved_before, preserved_snapshot

    after_apply = snapshot
    second_dry = JSON.parse(invoke_repair[/\{.*\}/m])
    assert_empty second_dry.fetch("actions").fetch("reset")
    assert_empty second_dry.fetch("actions").fetch("destroy")
    clear_enqueued_jobs
    replay = JSON.parse(invoke_repair("APPLY" => "1", "DECISION_AT" => second_dry.fetch("decision_at"), "EXPECTED_DIGEST" => second_dry.fetch("action_digest"))[/\{.*\}/m])
    assert_equal [], replay.fetch("committed_intents")
    assert_equal [], enqueued_jobs
    assert_equal after_apply, snapshot
    assert_equal 1, group.reload.evidence_sources.count
  end

  test "accepted-but-lost projected delivery leases recover once for fetch reconciliation and enrichment" do
    group = InvestigationGroup.create!(main_investigation: @investigations.first, evidence_revision: 1)
    @investigations.each do |investigation|
      investigation.update!(investigation_group: group, group_membership_kind: :manual, evidence_revision_assessed: 0)
    end
    source = group.evidence_sources.create!(article: @white_house, submitted_url: WHITE_HOUSE_URL, status: :pending)
    source.update_column(:fetch_retry_due_at, nil)
    clear_enqueued_jobs
    dry = JSON.parse(invoke_repair[/\{.*\}/m])
    applied = JSON.parse(invoke_repair("APPLY" => "1", "DECISION_AT" => dry.fetch("decision_at"), "EXPECTED_DIGEST" => dry.fetch("action_digest"))[/\{.*\}/m])
    expected_intents = canonical_intents(dry.fetch("actions"), group, source)
    assert_equal expected_intents, applied.fetch("committed_intents").map { |kind, id| [ kind, id ] }.sort

    # Simulate an adapter accepting then losing its handoff. The durable fences
    # remain and recovery only becomes eligible after their issued-time expiry.
    clear_enqueued_jobs
    travel_to 3.minutes.from_now do
      reconciliation_ids = expected_intents.select { |kind, _id| kind == "reconciliation" }.map(&:last)
      source.reload.update!(fetch_delivery_expires_at: 1.second.ago)
      @investigations.each do |investigation|
        next unless reconciliation_ids.include?(investigation.id)
        investigation.reload.update!(evidence_reconciliation_attempts_revision: group.evidence_revision,
          evidence_reconciliation_retry_due_at: 1.second.ago,
          evidence_reconciliation_retry_delivery_token: investigation.evidence_reconciliation_retry_delivery_token.presence || SecureRandom.uuid,
          evidence_reconciliation_retry_delivery_expires_at: 1.second.ago)
      end
      group.reload.update!(enrichment_delivery_expires_at: 1.second.ago)
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
      assert_equal [ source.id ], enqueued_jobs.select { |job| job[:job] == Investigations::FetchEvidenceJob }.map { |job| job[:args].first }.sort
      assert_equal reconciliation_ids.sort, enqueued_jobs.select { |job| job[:job] == Investigations::ReconcileGroupEvidenceJob }.map { |job| job[:args].first }.sort
      assert_equal [ group.main_investigation_id ], enqueued_jobs.select { |job| job[:job] == Investigations::RefreshParentEnrichmentJob }.map { |job| job[:args].first }.sort
      clear_enqueued_jobs
      Investigations::RecoverExpiredGroupLeasesJob.perform_now
      assert_equal [], enqueued_jobs
    end
  end

  private

  def completed_investigation(slug, index, rejected: false)
    url = "https://example#{index}.test/production-#{slug}"
    article = Article.create!(url:, normalized_url: url, host: URI(url).host,
      fetch_status: (rejected ? :rejected : :fetched), rejection_reason: ("too_short" if rejected),
      fetched_at: Time.utc(2025, 1, 1), title: "Production #{slug}", body_text: "body #{slug}")
    investigation = Investigation.create!(submitted_url: url, normalized_url: url, root_article: article, status: :completed)
    investigation.update_column(:slug, slug)
    investigation.pipeline_steps.create!(name: "generate_summary", status: :completed, started_at: Time.utc(2025, 1, 1), finished_at: Time.utc(2025, 1, 1))
    claim = Claim.create!(canonical_text: "Claim for #{slug}", canonical_fingerprint: "production-claim-#{slug}")
    assessment = ClaimAssessment.create!(investigation:, claim:, verdict: :supported, confidence_score: 0.8, assessed_at: Time.utc(2025, 1, 1))
    EvidenceItem.create!(claim_assessment: assessment, article:, source_url: article.normalized_url, stance: :supports, authority_score: 0.7)
    VerdictSnapshot.create!(claim_assessment: assessment, verdict: :supported, confidence_score: 0.8, reason_summary: "historical", trigger: "initial")
    investigation
  end

  def invoke_repair(overrides = {})
    values = { "MAIN_SLUG" => SLUGS.first, "NEWS_SLUGS" => SLUGS.drop(1).join(","), "EVIDENCE_URLS" => WHITE_HOUSE_URL }.merge(overrides)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    task = Rake::Task["frank:repair_group"]
    task.reenable
    result = nil
    begin
      result = capture_io { task.invoke }.first
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
    result
  end

  def snapshot
    { investigations: @investigations.map { |record| record.reload.attributes }, articles: @investigations.map { |record| record.root_article.reload.attributes }, white_house: @white_house.reload.attributes,
      groups: InvestigationGroup.order(:id).map(&:attributes), sources: InvestigationGroupEvidenceSource.order(:id).map(&:attributes),
      claims: Claim.order(:id).map(&:attributes), assessments: ClaimAssessment.order(:id).map(&:attributes), evidence_items: EvidenceItem.order(:id).map(&:attributes),
      verdict_snapshots: VerdictSnapshot.order(:id).map(&:attributes), pipeline_steps: PipelineStep.order(:id).map(&:attributes) }
  end

  # Group membership and delivery fences are the intentional repair writes.
  # This isolates every historical/root/report artifact which must survive.
  def preserved_snapshot
    { investigations: @investigations.map { |record|
        record.reload.attributes.except("investigation_group_id", "group_membership_kind", "updated_at",
          *Investigations::GroupSubmissionPreflight::MEMBER_GROUP_FIELDS)
      }, roots: @investigations.map { |record| record.root_article.reload.attributes },
      claims: Claim.order(:id).map(&:attributes), assessments: ClaimAssessment.order(:id).map(&:attributes),
      evidence_items: EvidenceItem.order(:id).map(&:attributes), verdict_snapshots: VerdictSnapshot.order(:id).map(&:attributes),
      pipeline_steps: PipelineStep.order(:id).map(&:attributes) }
  end

  def canonical_intents(actions, group, source)
    ([ [ "evidence", source.id ] ] if actions.fetch("fetch").include?(WHITE_HOUSE_URL)).then { |items|
      items ||= []
      items.concat(actions.fetch("reconcile").map { |slug| [ "reconciliation", Investigation.find_by!(slug: slug).id ] })
      items << [ "enrichment", group.main_investigation_id ] if actions.fetch("enrich").include?(group.main_investigation.slug)
      items.sort
    }
  end
end
