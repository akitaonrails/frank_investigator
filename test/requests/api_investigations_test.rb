require "test_helper"

class Api::InvestigationsTest < ActionDispatch::IntegrationTest
  setup do
    @original_secret = ENV["FRANK_AUTH_SECRET"]
    ENV["FRANK_AUTH_SECRET"] = "test-secret-token"
  end

  teardown do
    ENV["FRANK_AUTH_SECRET"] = @original_secret
  end

  test "rejects requests without auth token" do
    post api_investigations_path, params: { url: "https://example.com/article" }, as: :json
    assert_response :unauthorized
  end

  test "rejects requests with wrong token" do
    post api_investigations_path,
      params: { url: "https://example.com/article" },
      headers: { "Authorization" => "Bearer wrong-token" },
      as: :json
    assert_response :unauthorized
  end

  test "rejects blank url" do
    post api_investigations_path,
      params: { url: "" },
      headers: { "Authorization" => "Bearer test-secret-token" },
      as: :json
    assert_response :unprocessable_entity
    assert_equal "url is required", response.parsed_body["error"]
  end

  test "creates investigation with valid token and url" do
    post api_investigations_path,
      params: { url: "https://example.com/api-test-article" },
      headers: { "Authorization" => "Bearer test-secret-token" },
      as: :json
    assert_response :created
    body = response.parsed_body
    assert body["slug"].present?
    assert_equal "https://example.com/api-test-article", body["url"]
    assert body["report_url"].present?
  end

  test "returns existing investigation for duplicate url" do
    2.times do
      post api_investigations_path,
        params: { url: "https://example.com/api-dup-test" },
        headers: { "Authorization" => "Bearer test-secret-token" },
        as: :json
    end
    # Both should return the same slug
    slugs = Investigation.where(normalized_url: "https://example.com/api-dup-test").pluck(:slug).uniq
    assert_equal 1, slugs.size
  end

  # ── index ──

  test "index rejects requests without auth token" do
    get api_investigations_path
    assert_response :unauthorized
  end

  test "index returns the 10 most recent investigations newest first" do
    created = 12.times.map do |i|
      build_investigation(
        slug_seed: "recent-#{i}",
        title: "Article number #{i}",
        host: "outlet#{i}.example",
        created_at: (20 - i).minutes.ago,
        status: :completed
      )
    end

    get api_investigations_path, headers: auth_header, as: :json
    assert_response :success
    body = response.parsed_body

    assert_equal 10, body["count"]
    assert_nil body["query"]
    returned = body["investigations"]
    assert_equal 10, returned.size
    # Newest first: the most recently created (recent-11) leads.
    assert_equal created.last.slug, returned.first["slug"]
    # Oldest two (recent-0, recent-1) fall outside the limit.
    assert_not_includes returned.map { |i| i["slug"] }, created.first.slug
  end

  test "index item exposes all requested fields" do
    inv = build_investigation(
      slug_seed: "fields",
      title: "Governo anuncia corte de impostos",
      host: "folha.example",
      url: "https://folha.example/corte-impostos",
      created_at: 1.minute.ago,
      status: :completed,
      honest_headline: "Corte de impostos reverte aumento aplicado no ano anterior",
      llm_summary: { "conclusion" => "A matéria omite o aumento anterior." }
    )
    inv.update!(analysis_completed_at: 30.seconds.ago)

    get api_investigations_path, headers: auth_header, as: :json
    item = response.parsed_body["investigations"].find { |i| i["slug"] == inv.slug }

    assert_equal "completed", item["status"]
    assert_equal "folha.example", item["outlet"]
    assert_equal "Governo anuncia corte de impostos", item["original_title"]
    assert_equal "Corte de impostos reverte aumento aplicado no ano anterior", item["honest_title"]
    assert_equal "A matéria omite o aumento anterior.", item["summary"]
    assert_equal "https://folha.example/corte-impostos", item["original_url"]
    assert item["datetime"].present?
    assert item["completed_at"].present?
    assert_includes item["investigation_url"], inv.slug
  end

  test "index includes still-processing investigations with their status" do
    build_investigation(slug_seed: "proc", title: "Em andamento", host: "g1.example",
                        created_at: 1.minute.ago, status: :processing)

    get api_investigations_path, headers: auth_header, as: :json
    item = response.parsed_body["investigations"].find { |i| i["original_title"] == "Em andamento" }

    assert_equal "processing", item["status"]
    assert_nil item["completed_at"]
  end

  test "index q searches both original and honest titles" do
    by_original = build_investigation(slug_seed: "orig", title: "Reforma tributária aprovada", host: "a.example",
                                      created_at: 3.minutes.ago, status: :completed)
    by_honest = build_investigation(slug_seed: "hon", title: "Mudança nas regras fiscais", host: "b.example",
                                    created_at: 2.minutes.ago, status: :completed,
                                    honest_headline: "Detalhes da reforma tributária que o texto omite")
    _unrelated = build_investigation(slug_seed: "unrel", title: "Clima e meio ambiente", host: "c.example",
                                     created_at: 1.minute.ago, status: :completed)

    get api_investigations_path(q: "tributária"), headers: auth_header, as: :json
    assert_response :success
    body = response.parsed_body
    slugs = body["investigations"].map { |i| i["slug"] }

    assert_equal "tributária", body["query"]
    assert_includes slugs, by_original.slug
    assert_includes slugs, by_honest.slug
    assert_not_includes slugs, _unrelated.slug
  end

  test "index q is case-insensitive and limited to 10" do
    11.times do |i|
      build_investigation(slug_seed: "match-#{i}", title: "Economia em foco #{i}", host: "e#{i}.example",
                          created_at: (15 - i).minutes.ago, status: :completed)
    end

    get api_investigations_path(q: "ECONOMIA"), headers: auth_header, as: :json
    body = response.parsed_body
    assert_equal 10, body["count"]
  end

  test "index q treats wildcard characters literally" do
    plain = build_investigation(slug_seed: "plain", title: "Resultado final", host: "x.example",
                                created_at: 2.minutes.ago, status: :completed)
    wildcard = build_investigation(slug_seed: "wild", title: "100% de aprovação", host: "y.example",
                                   created_at: 1.minute.ago, status: :completed)

    get api_investigations_path(q: "100%"), headers: auth_header, as: :json
    slugs = response.parsed_body["investigations"].map { |i| i["slug"] }

    assert_includes slugs, wildcard.slug
    assert_not_includes slugs, plain.slug
  end

  private

  def auth_header
    { "Authorization" => "Bearer test-secret-token" }
  end

  def build_investigation(slug_seed:, title:, host:, created_at:, status:, url: nil, honest_headline: nil, llm_summary: nil)
    url ||= "https://#{host}/#{slug_seed}"
    article = Article.create!(
      url: url,
      normalized_url: url,
      host: host,
      title: title,
      body_text: "Body text for #{title}.",
      fetch_status: :fetched,
      fetched_at: created_at
    )
    Investigation.create!(
      submitted_url: url,
      normalized_url: url,
      root_article: article,
      status: status,
      honest_headline: honest_headline,
      llm_summary: llm_summary,
      created_at: created_at
    )
  end
end
